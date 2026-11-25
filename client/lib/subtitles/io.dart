import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/network.dart';
import '../sources/source.dart';
import 'document.dart';
import 'worker.dart';

Future<SubtitleDocument> readExternalSubtitleDocument(
  String path,
  String format,
  CancelToken cancel,
) => runSubtitleWork(() async {
  final bytes = await File(path).readAsBytes();
  if (bytes.isEmpty) throw const AppFailure('字幕文件为空。');
  return SubtitleDocument(decodeSubtitle(bytes), format);
}, cancel);

Future<SubtitleDocument> parseSubtitleDocument(
  String text,
  String format,
  CancelToken cancel,
) => runSubtitleWork(() => SubtitleDocument(text, format), cancel);

Future<void> downloadExternalSubtitle(
  SourceAdapter source,
  String path,
  File file,
  CancelToken cancel,
) async {
  cancel.check();
  final Stream<List<int>> stream;
  final int? expectedSize;
  if (source is HttpSource) {
    stream = await subtitleCancelable(source.readFile(path), cancel);
    expectedSize = null;
  } else {
    final stat = await subtitleCancelable(source.stat(path), cancel);
    expectedSize = stat.size;
    if (expectedSize <= 0) throw const AppFailure('字幕文件为空。');
    cancel.check();
    stream = source.read(path, 0, expectedSize - 1);
  }

  cancel.check();
  final output = await file.open(mode: FileMode.writeOnly);
  final input = StreamIterator(stream.timeout(const Duration(seconds: 25)));
  var done = false;
  Future<void>? stopping;
  unawaited(
    cancel.whenCancelled
        .then((_) async {
          if (!done) await (stopping ??= input.cancel());
        })
        .catchError((Object _) {}),
  );
  try {
    cancel.check();
    var received = 0;
    while (await input.moveNext()) {
      cancel.check();
      final bytes = input.current;
      received += bytes.length;
      if (expectedSize != null && received > expectedSize) {
        throw const AppFailure('来源返回的字幕大小不一致，请重试。');
      }
      await output.writeFrom(bytes);
    }
    cancel.check();
    if (expectedSize != null && received != expectedSize) {
      throw const AppFailure('字幕数据不完整，请检查来源连接。');
    }
  } finally {
    done = true;
    try {
      await (stopping ??= input.cancel());
    } finally {
      await output.close();
    }
  }
  await validateExternalSubtitle(file, cancel);
}

Future<void> validateExternalSubtitle(File file, CancelToken cancel) async {
  cancel.check();
  final input = await file.open();
  try {
    cancel.check();
    // Authentication pages may be served with HTTP 200. Inspect only a prefix
    // so opening a subtitle never decodes or parses the entire file in Dart.
    final prefix = await input.read(4096);
    cancel.check();
    if (prefix.isEmpty) throw const AppFailure('字幕文件为空。');
    rejectSubtitleHtml(decodeSubtitle(prefix, allowIncomplete: true));
  } finally {
    await input.close();
  }
}

Future<Uint8List> readSubtitleRange(
  SourceAdapter source,
  String path,
  int offset,
  int length,
  CancelToken cancel,
) async {
  if (length <= 0) throw const AppFailure('字幕文件为空。');
  cancel.check();
  final result = BytesBuilder(copy: false);
  final iterator = StreamIterator(
    source
        .read(path, offset, offset + length - 1)
        .timeout(const Duration(seconds: 25)),
  );
  try {
    while (await subtitleCancelable(iterator.moveNext(), cancel)) {
      cancel.check();
      result.add(iterator.current);
      if (result.length > length) {
        throw const AppFailure('来源忽略了 Range 范围，已停止字幕读取。');
      }
    }
    cancel.check();
    if (result.length != length) throw const AppFailure('字幕数据不完整，请检查来源连接。');
    return result.takeBytes();
  } finally {
    await iterator.cancel();
  }
}
