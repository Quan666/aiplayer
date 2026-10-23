import 'dart:math' as math;
import 'dart:convert';
import 'dart:typed_data';
import '../core/network.dart';

// Port of openlist-enhancer's indexed Matroska reader. Only SeekHead metadata,
// subtitle Cues and their Blocks are read. No fallback scans movie payloads.
typedef SubtitleRangeRead = Future<Uint8List> Function(int offset, int length);

class MkvSubtitle {
  final String text, format, title;
  const MkvSubtitle(this.text, this.format, this.title);
}

class _Element {
  final int id, offset, data;
  final int? end;
  const _Element(this.id, this.offset, this.data, this.end);
  int? get size => end == null ? null : end! - data;
}

Never _fail(String text) => throw AppFailure(text);
(int?, int) _vint(
  Uint8List bytes,
  int offset, {
  bool id = false,
  bool unknown = true,
}) {
  if (offset >= bytes.length || bytes[offset] == 0) _fail('MKV 元素头损坏或被截断。');
  final first = bytes[offset];
  var marker = 128, length = 1;
  while ((first & marker) == 0) {
    marker >>= 1;
    length++;
  }
  if (length > (id ? 4 : 8) || offset + length > bytes.length) {
    _fail('MKV 元素头长度无效。');
  }
  var value = id ? first : first & (marker - 1);
  var allOnes = !id && unknown && value == marker - 1;
  for (var i = 1; i < length; i++) {
    value = value * 256 + bytes[offset + i];
    allOnes = allOnes && bytes[offset + i] == 255;
  }
  if (value < 0) _fail('MKV 文件位置超出安全范围。');
  return (allOnes ? null : value, length);
}

_Element _header(Uint8List data, [int offset = 0, int absolute = 0]) {
  final id = _vint(data, offset, id: true), size = _vint(data, offset + id.$2);
  final start = absolute + offset + id.$2 + size.$2;
  return _Element(
    id.$1!,
    absolute + offset,
    start,
    size.$1 == null ? null : start + size.$1!,
  );
}

Iterable<(int, Uint8List)> _children(Uint8List bytes) sync* {
  for (var pos = 0; pos < bytes.length;) {
    final e = _header(bytes, pos);
    if (e.end == null || e.end! > bytes.length || e.end! <= pos) {
      _fail('MKV 子元素长度越界。');
    }
    yield (e.id, Uint8List.sublistView(bytes, e.data, e.end));
    pos = e.end!;
  }
}

Uint8List? _field(List<(int, Uint8List)> fields, int id) =>
    fields.where((f) => f.$1 == id).firstOrNull?.$2;
int _uint(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > 8) _fail('MKV 整数长度无效。');
  var value = 0;
  for (final b in bytes) {
    value = value * 256 + b;
  }
  if (value < 0) _fail('MKV 数值超出安全范围。');
  return value;
}

int? _number(List<(int, Uint8List)> fields, int id, [int? fallback]) {
  final b = _field(fields, id);
  return b == null ? fallback : _uint(b);
}

String _str(Uint8List bytes) {
  try {
    return utf8.decode(bytes).replaceFirst(RegExp(r'\x00+$'), '');
  } on FormatException {
    _fail('MKV 字幕含无效的 UTF-8 文字。');
  }
}

String _text(List<(int, Uint8List)> fields, int id, [String fallback = '']) {
  final b = _field(fields, id);
  return b == null ? fallback : _str(b);
}

double _float(Uint8List b) {
  final view = ByteData.sublistView(b);
  final value = b.length == 4
      ? view.getFloat32(0)
      : b.length == 8
      ? view.getFloat64(0)
      : double.nan;
  if (!value.isFinite || value <= 0) _fail('MKV 时间比例无效。');
  return value;
}

class _Reader {
  final SubtitleRangeRead read;
  final int length;
  final CancelToken cancel;
  final cache = <int, Uint8List>{};
  var received = 0, requests = 0;
  _Reader(this.read, this.length, this.cancel);
  Future<Uint8List> bytes(int start, int amount, {bool window = false}) async {
    cancel.check();
    if (start < 0 || amount < 0 || start + amount > length) {
      _fail('MKV 读取位置超出文件。');
    }
    if (amount > 16 * 1024 * 1024) _fail('MKV 字幕索引或文本超过 16 MiB，请使用外挂字幕。');
    for (final entry in cache.entries) {
      if (entry.key <= start &&
          entry.key + entry.value.length >= start + amount) {
        return Uint8List.sublistView(
          entry.value,
          start - entry.key,
          start - entry.key + amount,
        );
      }
    }
    final size = window
        ? math.min(math.max(256, amount), length - start)
        : amount;
    final out = BytesBuilder(copy: false);
    for (var offset = 0; offset < size; offset += 1024 * 1024) {
      cancel.check();
      final count = math.min(1024 * 1024, size - offset);
      received += count;
      requests++;
      if (received > 64 * 1024 * 1024 || requests > 50000) {
        _fail('字幕索引读取量过大，已停止读取。请使用外挂字幕或重新封装 MKV。');
      }
      final data = await read(start + offset, count);
      cancel.check();
      if (data.length != count) _fail('来源没有返回完整的 Range 数据，无法提取 MKV 字幕。');
      out.add(data);
    }
    final data = out.takeBytes();
    if (data.length <= 16384) {
      cache[start] = data;
      if (cache.length > 128) cache.remove(cache.keys.first);
    }
    return Uint8List.sublistView(data, 0, amount);
  }

  Future<_Element> head(int offset, [int? parentEnd]) async {
    final end = parentEnd ?? length;
    if (offset < 0 || offset >= end) _fail('MKV 元素头超出父元素。');
    final element = _header(
      await bytes(offset, math.min(12, end - offset), window: true),
      0,
      offset,
    );
    if (element.data > end || (element.end != null && element.end! > end)) {
      _fail('MKV 元素长度超出父元素。');
    }
    return element;
  }

  Future<Uint8List> payload(_Element e) {
    if (e.size == null) _fail('MKV 元素长度未知，无法提取字幕。');
    return bytes(e.data, e.size!);
  }
}

class _Track {
  final int number, type, codecDelay;
  final int? defaultDuration;
  final String codec, private, title;
  final double scale;
  final bool encoded;
  _Track(List<(int, Uint8List)> f)
    : number = _number(f, 0xd7) ?? 0,
      type = _number(f, 0x83) ?? 0,
      codec = _text(f, 0x86),
      private = _text(f, 0x63a2),
      title = _text(f, 0x536e),
      codecDelay = _number(f, 0x56aa, 0)!,
      defaultDuration = _number(f, 0x23e383),
      scale = _field(f, 0x23314f) == null ? 1 : _float(_field(f, 0x23314f)!),
      encoded = _field(f, 0x6d80) != null;
}

class _Cue {
  final int cluster, relative;
  final int? duration;
  const _Cue(this.cluster, this.relative, this.duration);
}

class _Event {
  final double start, end;
  final String text;
  const _Event(this.start, this.end, this.text);
}

String _time(double seconds, {bool ass = false}) {
  final base = ass ? 100 : 1000;
  final units = math.max(0, (seconds * base).round());
  final h = units ~/ (base * 3600),
      m = units ~/ (base * 60) % 60,
      s = units ~/ base % 60;
  return '${ass ? h : '$h'.padLeft(2, '0')}:${'$m'.padLeft(2, '0')}:${'$s'.padLeft(2, '0')}.${'${units % base}'.padLeft(ass ? 2 : 3, '0')}';
}

String _renderAss(_Track track, List<_Event> events) {
  final ssa = track.codec == 'S_TEXT/SSA';
  final preamble = track.private
      .replaceFirst('\uFEFF', '')
      .split(RegExp(r'\[Events\]', caseSensitive: false))
      .first
      .trimRight();
  if (!RegExp(r'\[Script Info\]', caseSensitive: false).hasMatch(preamble)) {
    _fail('内嵌 ASS 缺少样式头，无法保留样式转换。');
  }
  final lines = <(int, int, String)>[];
  for (var i = 0; i < events.length; i++) {
    final event = events[i], fields = <String>[];
    final text = event.text.replaceAll(RegExp(r'\r?\n'), r'\N');
    var start = 0;
    for (var j = 0; j < 8; j++) {
      final comma = text.indexOf(',', start);
      if (comma < 0) _fail('MKV ASS 对白字段不完整。');
      fields.add(text.substring(start, comma));
      start = comma + 1;
    }
    fields.add(text.substring(start));
    final order = int.tryParse(fields[0]);
    if (order == null || order < 0) _fail('MKV ASS ReadOrder 无效。');
    final layer = ssa
        ? 'Marked=0'
        : fields[1].isEmpty
        ? '0'
        : fields[1];
    if (!ssa && int.tryParse(layer) == null) _fail('MKV ASS Layer 无效。');
    lines.add((
      order,
      i,
      'Dialogue: $layer,${_time(event.start, ass: true)},${_time(event.end, ass: true)},${fields.skip(2).join(',')}',
    ));
  }
  lines.sort((a, b) {
    final order = a.$1.compareTo(b.$1);
    return order != 0 ? order : a.$2.compareTo(b.$2);
  });
  return '$preamble\n\n[Events]\nFormat: ${ssa ? 'Marked' : 'Layer'}, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n${lines.map((v) => v.$3).join('\n')}\n';
}

Future<MkvSubtitle> extractMkvSubtitle({
  required SubtitleRangeRead read,
  required int fileSize,
  required int subtitleIndex,
  required CancelToken cancel,
  void Function(int completed, int total)? onProgress,
}) async {
  final r = _Reader(read, fileSize, cancel);
  final ebml = await r.head(0);
  if (ebml.id != 0x1a45dfa3 || ebml.end == null) {
    _fail('此文件不是 MKV / WebM，暂不支持提取其内嵌字幕。可加载外挂字幕后转换。');
  }
  final docType = _text(_children(await r.payload(ebml)).toList(), 0x4282);
  if (!['matroska', 'webm', ''].contains(docType)) _fail('不支持此 EBML 文件类型。');
  var segment = await r.head(ebml.end!);
  while (segment.id == 0xec && segment.end != null) {
    segment = await r.head(segment.end!);
  }
  if (segment.id != 0x18538067) _fail('找不到 MKV Segment。');
  final segmentEnd = segment.end ?? fileSize;
  final positions = <int, int>{}, seekQueue = <int>[], visited = <int>{};
  for (var pos = segment.data; pos < segmentEnd;) {
    final e = await r.head(pos, segmentEnd);
    if (e.id == 0x1f43b675) break;
    positions.putIfAbsent(e.id, () => e.offset);
    if (e.id == 0x114d9b74) seekQueue.add(e.offset);
    if (e.end == null) _fail('MKV 顶层元素长度未知。');
    pos = e.end!;
  }
  for (var i = 0; i < seekQueue.length; i++) {
    final offset = seekQueue[i];
    if (!visited.add(offset)) continue;
    if (visited.length > 128) _fail('MKV SeekHead 数量异常。');
    final head = await r.head(offset, segmentEnd);
    if (head.id != 0x114d9b74) _fail('MKV SeekHead 位置无效。');
    for (final entry in _children(
      await r.payload(head),
    ).where((e) => e.$1 == 0x4dbb)) {
      final fields = _children(entry.$2).toList(),
          idBytes = _field(_children(entry.$2).toList(), 0x53ab);
      final position = _number(fields, 0x53ac);
      if (idBytes == null || position == null) _fail('MKV SeekHead 缺少位置。');
      final id = _uint(idBytes), absolute = segment.data + position;
      if (absolute >= segmentEnd) _fail('MKV SeekHead 指向文件之外。');
      positions.putIfAbsent(id, () => absolute);
      if (id == 0x114d9b74) seekQueue.add(absolute);
    }
  }
  Future<Uint8List?> locate(int id) async {
    if (!positions.containsKey(id)) return null;
    final e = await r.head(positions[id]!, segmentEnd);
    if (e.id != id) _fail('MKV SeekHead 与目标不匹配。');
    return r.payload(e);
  }

  final info = await locate(0x1549a966);
  final scale = info == null
      ? 1000000
      : _number(_children(info).toList(), 0x2ad7b1, 1000000)!;
  if (scale <= 0) _fail('MKV 时间单位无效。');
  final tracksData = await locate(0x1654ae6b);
  if (tracksData == null) _fail('MKV 缺少轨道信息。');
  final tracks = _children(tracksData)
      .where((e) => e.$1 == 0xae)
      .map((e) => _children(e.$2).toList())
      .where((fields) => _number(fields, 0x83) == 17)
      .map(_Track.new)
      .toList();
  if (subtitleIndex < 0 || subtitleIndex >= tracks.length) {
    _fail('所选内嵌字幕轨道与 MKV 信息不匹配，请重新选择字幕。');
  }
  final track = tracks[subtitleIndex];
  if (track.encoded) _fail('此字幕轨道经过压缩或加密。原字幕可播放，请使用外挂文字字幕进行转换。');
  if (!['S_TEXT/ASS', 'S_TEXT/SSA', 'S_TEXT/UTF8'].contains(track.codec)) {
    _fail('此轨道是图片字幕或不支持的格式，无法直接繁简转换或 AI 翻译。请加载 ASS / SRT 外挂字幕。');
  }
  final cueData = await locate(0x1c53bb6b);
  final cues = <_Cue>[];
  if (cueData != null) {
    for (final point in _children(cueData).where((e) => e.$1 == 0xbb)) {
      for (final pos in _children(point.$2).where((e) => e.$1 == 0xb7)) {
        final fields = _children(pos.$2).toList();
        if (_number(fields, 0xf7) != track.number) continue;
        final cluster = _number(fields, 0xf1), relative = _number(fields, 0xf0);
        if (cluster == null) _fail('MKV 字幕索引缺少 Cluster 位置。');
        if (relative == null) {
          _fail('MKV 字幕索引缺少 CueRelativePosition，无法有界提取。请使用外挂字幕或重新封装 MKV。');
        }
        cues.add(_Cue(segment.data + cluster, relative, _number(fields, 0xb2)));
      }
    }
  }
  if (cues.isEmpty) _fail('此轨道没有字幕索引。为避免下载整片，请使用外挂字幕，或为 MKV 重新生成字幕索引。原字幕仍可播放。');
  final clusters = <int, (_Element, int)>{},
      seen = <int>{},
      events = <_Event>[];
  var textBytes = 0;
  for (var index = 0; index < cues.length; index++) {
    cancel.check();
    final cue = cues[index];
    if (!clusters.containsKey(cue.cluster)) {
      final cluster = await r.head(cue.cluster, segmentEnd);
      if (cluster.id != 0x1f43b675) _fail('字幕索引未指向 Cluster。');
      for (var pos = cluster.data; pos < (cluster.end ?? segmentEnd);) {
        final element = await r.head(pos, cluster.end ?? segmentEnd);
        if (element.id == 0xe7) {
          clusters[cue.cluster] = (cluster, _uint(await r.payload(element)));
          break;
        }
        if (element.end == null || element.id == 0x1f43b675) break;
        pos = element.end!;
      }
      if (!clusters.containsKey(cue.cluster)) _fail('Cluster 缺少 Timestamp。');
    }
    final (cluster, timestamp) = clusters[cue.cluster]!;
    final offset = cluster.data + cue.relative;
    if (!seen.add(offset)) continue;
    final e = await r.head(offset, cluster.end ?? segmentEnd);
    Uint8List? raw;
    double? duration;
    if (e.id == 0xa0) {
      final f = _children(await r.payload(e)).toList();
      raw = _field(f, 0xa1);
      final d = _number(f, 0x9b);
      if (d != null) duration = d * track.scale * scale / 1e9;
    } else if (e.id == 0xa3) {
      raw = await r.payload(e);
    } else {
      _fail('字幕索引的块位置无效。');
    }
    if (raw == null) _fail('字幕块缺少 Block。');
    final number = _vint(raw, 0, unknown: false), prefix = number.$2;
    if (number.$1 != track.number || raw.length < prefix + 3) {
      _fail('字幕索引指向其他轨道或数据被截断。');
    }
    if (raw[prefix + 2] & 6 != 0) _fail('暂不支持 lacing 文字字幕，请使用外挂字幕。');
    final delta = ByteData.sublistView(raw).getInt16(prefix);
    final start =
        ((timestamp + delta * track.scale) * scale - track.codecDelay) / 1e9;
    duration ??= cue.duration == null ? null : cue.duration! * scale / 1e9;
    duration ??= track.defaultDuration == null
        ? null
        : track.defaultDuration! / 1e9;
    if (duration == null ||
        duration < 0 ||
        !duration.isFinite ||
        !start.isFinite) {
      _fail('字幕块缺少有效持续时间。');
    }
    final text = _str(Uint8List.sublistView(raw, prefix + 3));
    textBytes += text.length;
    if (textBytes > 16 * 1024 * 1024) _fail('字幕文本超过 16 MiB，暂不支持转换。');
    if (duration > 0 && start + duration > 0) {
      events.add(_Event(math.max(0, start), start + duration, text));
    }
    onProgress?.call(index + 1, cues.length);
  }
  events.sort((a, b) => a.start.compareTo(b.start));
  if (track.codec == 'S_TEXT/UTF8') {
    return MkvSubtitle(
      'WEBVTT\n\n${events.indexed.map((e) => '${e.$1 + 1}\n${_time(e.$2.start)} --> ${_time(e.$2.end)}\n${e.$2.text.replaceAll('\r\n', '\n').replaceAll(RegExp(r'\n{2,}'), '\n')}\n').join('\n')}',
      'vtt',
      track.title,
    );
  }
  return MkvSubtitle(
    _renderAss(track, events),
    track.codec == 'S_TEXT/SSA' ? 'ssa' : 'ass',
    track.title,
  );
}
