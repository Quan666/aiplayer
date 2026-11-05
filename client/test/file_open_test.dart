import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/file_open.dart';
import 'package:aiplayer/core/network.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android sends only the selected local path to the platform', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ExternalFileOpener.channel, (call) async {
          received = call;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ExternalFileOpener.channel, null);
    });
    await const ExternalFileOpener(operatingSystem: 'android')
        .open('/tmp/report.pdf');
    expect(received?.method, 'open');
    expect(received?.arguments, '/tmp/report.pdf');
  });

  test('missing file association is surfaced to the caller', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ExternalFileOpener.channel, (_) async {
          throw PlatformException(code: 'no_handler', message: '没有可打开此文件的应用。');
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ExternalFileOpener.channel, null);
    });
    await expectLater(
      const ExternalFileOpener(operatingSystem: 'android')
          .open('/tmp/file.bin'),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.message,
          'message',
          '没有可打开此文件的应用。',
        ),
      ),
    );
  });

  test('Linux passes a URI so option-like filenames stay data', () async {
    final opener = ExternalFileOpener(
      operatingSystem: 'linux',
      process: (executable, arguments, {environment}) async {
        expect(executable, 'xdg-open');
        expect(arguments, [r'file:///tmp/-report%20$(run).pdf']);
        expect(environment, isNull);
        return ProcessResult(1, 0, '', '');
      },
    );
    await opener.open(r'/tmp/-report $(run).pdf');
  });

  test('Windows never interpolates paths into PowerShell source', () async {
    const path = r"/tmp/report'; Write-Output 'oops.pdf";
    final opener = ExternalFileOpener(
      operatingSystem: 'windows',
      process: (executable, arguments, {environment}) async {
        expect(executable, 'powershell.exe');
        expect(arguments.last, isNot(contains(path)));
        expect(environment?['AIPLAYER_EXTERNAL_FILE'], path);
        return ProcessResult(1, 0, '', '');
      },
    );
    await opener.open(path);
  });

  test('desktop opener failure does not pretend the file was opened', () async {
    final opener = ExternalFileOpener(
      operatingSystem: 'linux',
      process: (_, _, {environment}) async => ProcessResult(1, 4, '', ''),
    );
    await expectLater(opener.open('/tmp/file.bin'), throwsA(isA<AppFailure>()));
  });

  test('prelaunch cancellation reaches the native runner', () async {
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ExternalFileOpener.channel, (call) async {
          methods.add(call.method);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ExternalFileOpener.channel, null);
    });
    await const ExternalFileOpener(operatingSystem: 'android').cancelPending();
    expect(methods, ['cancel']);
  });

  test(
    'unresponsive native handoff is cancelled and reports a retryable error',
    () async {
      final pending = Completer<void>();
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ExternalFileOpener.channel, (call) async {
            methods.add(call.method);
            if (call.method == 'open') await pending.future;
            return null;
          });
      addTearDown(() {
        pending.complete();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ExternalFileOpener.channel, null);
      });
      await expectLater(
        const ExternalFileOpener(
          operatingSystem: 'android',
          handoffTimeout: Duration(milliseconds: 20),
        ).open('/tmp/any-file.unknown'),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'message',
            contains('系统未响应'),
          ),
        ),
      );
      expect(methods, ['open', 'cancel']);
    },
  );
}
