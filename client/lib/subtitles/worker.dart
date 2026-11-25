import 'dart:async';
import 'dart:isolate';

import '../core/network.dart';

Future<T> subtitleCancelable<T>(Future<T> work, CancelToken token) {
  token.check();
  return Future.any([
    work,
    token.whenCancelled.then<T>((_) => throw const Cancelled()),
  ]);
}

Future<T> runSubtitleWork<T>(
  FutureOr<T> Function() work,
  CancelToken cancel,
) async {
  cancel.check();
  final replies = ReceivePort();
  Isolate? worker;
  try {
    worker = await Isolate.spawn(
      _runSubtitleWork<T>,
      (replies.sendPort, work),
      onExit: replies.sendPort,
      debugName: 'subtitle-work',
    );
    cancel.check();
    final reply = await subtitleCancelable(replies.first, cancel);
    cancel.check();
    if (reply case (final Object error, final StackTrace stack)) {
      Error.throwWithStackTrace(error, stack);
    }
    if (reply case (final T result,)) return result;
    throw const AppFailure('字幕后台处理已结束，请重试。');
  } finally {
    worker?.kill(priority: Isolate.immediate);
    replies.close();
  }
}

Future<void> _runSubtitleWork<T>(
  (SendPort, FutureOr<T> Function()) work,
) async {
  final (reply, run) = work;
  try {
    Isolate.exit(reply, (await run(),));
  } catch (error, stack) {
    Isolate.exit(reply, (error, stack));
  }
}
