import 'dart:async';

import 'package:aiplayer/core/system_proxy.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // flutter_tester has no OS runner. Resolver tests explicitly select each OS
  // and mock its channel; network/worker tests use their own local servers.
  overrideSystemProxyPlatformForTesting('unit-test');
  await testMain();
}
