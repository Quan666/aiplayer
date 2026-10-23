import 'dart:async';
import 'dart:typed_data';
import '../core/network.dart';
import '../sources/source.dart';

Future<T> subtitleCancelable<T>(Future<T> work, CancelToken token) {
  token.check();
  return Future.any([
    work,
    token.whenCancelled.then<T>((_) => throw const Cancelled()),
  ]);
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
