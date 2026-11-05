import 'dart:io';
import 'dart:typed_data';

import 'package:aiplayer/data/text_document.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// Opt-in real native SMB regression. Start scripts/smb_fixture.sh, then run:
// AIPLAYER_SMB_FIXTURE=true AIPLAYER_SMB_FIXTURE_SHARE=/tmp/<fixture>/share \
// LD_LIBRARY_PATH=<repo>/client/build/linux/x64/debug/bundle/lib \
// flutter test --no-pub test/smb_external_file_test.dart
// The bytes are synthetic binary payloads, not installable APKs. This checks
// authenticated SMB materialization, not Android's external-app chooser.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['AIPLAYER_SMB_FIXTURE'] == 'true';
  final sharePath = Platform.environment['AIPLAYER_SMB_FIXTURE_SHARE'];
  test(
    'real SMB prepares APK, ZIP, unknown and extensionless files intact',
    () async {
      expect(sharePath, isNotNull);
      final root = await Directory.systemTemp.createTemp('smb-external-');
      final payload = Uint8List.fromList(
        List.generate(2 * 1024 * 1024 + 37, (index) => index % 256),
      );
      final expectedDigest = sha256.convert(payload);
      final fixtureFiles = <File>[];
      try {
        for (final name in ['安装包.apk', '归档.zip', '未知.custom', '无扩展名']) {
          final fixtureName = '${p.basename(root.path)}-$name';
          final fixture = File(p.join(sharePath!, fixtureName));
          fixtureFiles.add(fixture);
          await fixture.writeAsBytes(payload, flush: true);
          final stat = await fixture.stat();
          final service = TextDocumentService(
            source: {
              'id': 'smb-external-fixture',
              'kind': 'smb',
              'host': '127.0.0.1',
              'port': 1445,
              'share': 'video',
              'user': Platform.environment['SMB_TEST_USER'] ?? 'root',
              'smbSecurity': 'sign',
            },
            password: 'aiplayer-fixture-password',
            documentsPath: root.path,
          );
          try {
            final started = Stopwatch()..start();
            final progress = <(int, int)>[];
            final localPath = await service
                .prepareExternal(
                  SourceEntry(
                    name: fixtureName,
                    path: fixtureName,
                    size: stat.size,
                    modified: stat.modified.millisecondsSinceEpoch,
                  ),
                  cacheDirectory: p.join(root.path, 'external-files-v1'),
                  onProgress: (received, total) =>
                      progress.add((received, total)),
                )
                .timeout(const Duration(seconds: 20));
            final local = File(localPath);
            expect(p.basename(localPath), fixtureName);
            expect(await local.length(), payload.length);
            expect(await sha256.bind(local.openRead()).first, expectedDigest);
            expect(progress.first, (0, payload.length));
            expect(progress.last, (payload.length, payload.length));
            for (var index = 1; index < progress.length; index++) {
              expect(
                progress[index].$1,
                greaterThanOrEqualTo(progress[index - 1].$1),
              );
              expect(progress[index].$2, payload.length);
            }
            expect(
              await File(p.join(local.parent.parent.path, '.complete'))
                  .exists(),
              isTrue,
            );
            // Timing is diagnostic only; it is not a device performance claim.
            // ignore: avoid_print
            print(
              'SMB_EXTERNAL $name ${payload.length} bytes '
              '${started.elapsedMilliseconds} ms progress=$progress '
              'sha256=$expectedDigest',
            );
          } finally {
            service.dispose();
            final deadline = DateTime.now().add(const Duration(seconds: 5));
            while (TextDocumentService.activeSmbWorkers > 0 &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            expect(TextDocumentService.activeSmbWorkers, 0);
            expect(TextDocumentService.waitingSmbWorkers, 0);
          }
        }
      } finally {
        for (final fixture in fixtureFiles) {
          if (await fixture.exists()) await fixture.delete();
        }
        await root.delete(recursive: true);
      }
    },
    skip: enabled
        ? false
        : 'Requires scripts/smb_fixture.sh and explicit opt-in',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
