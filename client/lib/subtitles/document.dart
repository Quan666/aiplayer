import 'dart:convert';
import 'dart:typed_data';
import '../core/network.dart';

class SubtitleCue {
  final int id, start, end;
  final String text, timing;
  final List<String> tokens;
  const SubtitleCue(
    this.id,
    this.start,
    this.end,
    this.text,
    this.tokens,
    this.timing,
  );
}

/// Source offsets are retained: conversion never regenerates timestamps, ASS
/// styling, drawing commands, VTT settings, or newline conventions.
class SubtitleDocument {
  final String source, format;
  final List<SubtitleCue> cues = [];
  SubtitleDocument(this.source, String extension)
    : format = extension.toLowerCase().replaceFirst('.', '') {
    if (!['ass', 'ssa', 'srt', 'vtt'].contains(format)) {
      throw const AppFailure('不支持此字幕格式。请选择 ASS、SSA、SRT 或 VTT。');
    }
    if (source.length > 16 * 1024 * 1024) {
      throw const AppFailure('字幕超过 16 MiB，暂不支持文字转换。原字幕仍可播放。');
    }
    if (RegExp(
      r'^\s*(<!doctype\s+html|<html)',
      caseSensitive: false,
    ).hasMatch(source)) {
      throw const AppFailure('读取到网页而非字幕，请检查来源认证及文件。');
    }
    if (format == 'ass' || format == 'ssa') {
      var events = false;
      var fields = <String>[];
      for (final match in RegExp(r'[^\r\n]+').allMatches(source)) {
        final line = match[0]!;
        if (RegExp(r'^\s*\[').hasMatch(line)) {
          events = RegExp(
            r'^\s*\[Events\]\s*$',
            caseSensitive: false,
          ).hasMatch(line);
          continue;
        }
        if (!events) continue;
        if (RegExp(r'^\s*Format:', caseSensitive: false).hasMatch(line)) {
          fields = line
              .substring(line.indexOf(':') + 1)
              .split(',')
              .map((v) => v.trim().toLowerCase())
              .toList();
        }
        if (!RegExp(r'^\s*Dialogue:', caseSensitive: false).hasMatch(line)) {
          continue;
        }
        if (fields.isEmpty || fields.last != 'text') {
          throw const AppFailure('ASS Events 的 Text 字段必须在末尾。');
        }
        var offset = line.indexOf(':') + 1;
        for (var i = 1; i < fields.length; i++) {
          final comma = line.indexOf(',', offset);
          if (comma < 0) throw const AppFailure('ASS 字幕字段不完整。');
          offset = comma + 1;
        }
        final values = line
            .substring(line.indexOf(':') + 1, offset - 1)
            .split(',');
        String time(String field) {
          final index = fields.indexOf(field);
          return index < 0 || index >= values.length
              ? ''
              : values[index].trim();
        }

        _add(
          match.start + offset,
          match.end,
          '${time('start')} → ${time('end')}',
        );
      }
    } else {
      for (final block in RegExp(
        r'[^\r\n]+(?:\r?\n(?!\r?\n)[^\r\n]+)*',
      ).allMatches(source)) {
        if (RegExp(
          r'^(?:\uFEFF?WEBVTT|NOTE|STYLE|REGION)(?:\s|$)',
        ).hasMatch(block[0]!)) {
          continue;
        }
        final timing = RegExp(
          r'(?:^|\r?\n)(?:\d+:)?\d{2}:\d{2}[.,]\d{3}\s+-->[^\r\n]*\r?\n',
        ).firstMatch(block[0]!);
        if (timing != null) {
          _add(block.start + timing.end, block.end, timing[0]!.trim());
        }
      }
    }
    if (cues.isEmpty) throw const AppFailure('字幕中没有可转换的文字，可能是图片字幕或格式不完整。');
  }

  static final _placeholder = RegExp(r'⟦S\d+⟧');
  static final _protected = RegExp(
    r'\{[^}]*\}|\\[Nnh]|<[^>]*>|⟦S\d+⟧|\r\n|[\r\n{}<>\\]',
  );
  void _add(int start, int end, String timing) {
    final raw = source.substring(start, end), tokens = <String>[];
    var drawing = false, previous = 0;
    final out = StringBuffer();
    String protect(String v) {
      tokens.add(v);
      return '⟦S${tokens.length - 1}⟧';
    }

    void plain(String v) {
      if (v.isNotEmpty) out.write(drawing ? protect(v) : v);
    }

    for (final match in _protected.allMatches(raw)) {
      plain(raw.substring(previous, match.start));
      final value = match[0]!;
      if (value.startsWith('{') && value.endsWith('}')) {
        final modes = RegExp(r'\\p(\d+)(?!\d)').allMatches(value).toList();
        if (modes.isNotEmpty) drawing = int.parse(modes.last[1]!) > 0;
      }
      out.write(protect(value));
      previous = match.end;
    }
    plain(raw.substring(previous));
    final value = out.toString();
    if (value.replaceAll(_placeholder, '').trim().isNotEmpty) {
      cues.add(SubtitleCue(cues.length, start, end, value, tokens, timing));
    }
  }

  String validate(SubtitleCue cue, String value) {
    if (value.trim().isEmpty) throw AppFailure('第 ${cue.id + 1} 条译文为空。');
    final expected = _placeholder
        .allMatches(cue.text)
        .map((m) => m[0])
        .join('|');
    final actual = _placeholder.allMatches(value).map((m) => m[0]).join('|');
    if (expected != actual) {
      throw AppFailure('第 ${cue.id + 1} 条译文改变了排版标记，请重试或更换模型。');
    }
    final plain = value.replaceAll(_placeholder, '');
    if (RegExp(
          r'[{}<>\\\u0000-\u0008\u000b\u000c\u000e-\u001f]',
        ).hasMatch(plain) ||
        RegExp(r'\r|\n\s*\n').hasMatch(plain) ||
        (['ass', 'ssa'].contains(format) && plain.contains('\n'))) {
      throw AppFailure('第 ${cue.id + 1} 条译文含新增排版指令或无效换行。');
    }
    return value.replaceAllMapped(
      RegExp(r'⟦S(\d+)⟧'),
      (m) => cue.tokens[int.parse(m[1]!)],
    );
  }

  String render(Map<int, String> values) {
    final out = StringBuffer();
    var previous = 0;
    for (final cue in cues) {
      out.write(source.substring(previous, cue.start));
      out.write(
        values.containsKey(cue.id)
            ? validate(cue, values[cue.id]!)
            : source.substring(cue.start, cue.end),
      );
      previous = cue.end;
    }
    out.write(source.substring(previous));
    return out.toString();
  }
}

/// Unicode BOMs are common in Windows subtitle collections. Legacy encodings
/// are left to mpv for playback; transforming them must never silently corrupt.
String decodeSubtitle(Uint8List bytes) {
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    if (bytes.length.isOdd) throw const AppFailure('UTF-16 字幕数据被截断。');
    final data = ByteData.sublistView(bytes), little = bytes[0] == 0xff;
    return String.fromCharCodes([
      for (var i = 2; i < bytes.length; i += 2)
        data.getUint16(i, little ? Endian.little : Endian.big),
    ]);
  }
  try {
    return utf8.decode(bytes).replaceFirst('\uFEFF', '');
  } on FormatException {
    throw const AppFailure(
      '字幕不是 UTF-8 / UTF-16。原字幕可继续播放；请先另存为 UTF-8 再进行繁简转换或翻译。',
    );
  }
}
