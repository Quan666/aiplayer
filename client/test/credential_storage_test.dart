import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/credential_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _secureStorageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory documents;
  late List<MethodCall> keychainCalls;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('aiplayer-credentials-');
    keychainCalls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _secureStorageChannel,
      (call) async {
        keychainCalls.add(call);
        return null;
      },
    );
    addTearDown(() async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _secureStorageChannel,
        null,
      );
      await documents.delete(recursive: true);
    });
  });

  LocalCredentialStorage openLocal() {
    final storage = LocalCredentialStorage(documents);
    addTearDown(storage.close);
    return storage;
  }

  test('ordinary builds retain platform secure storage', () async {
    final storage = createCredentialStorage(documents, macosAdhoc: false);

    expect(storage.runtimeType, FlutterSecureStorage);
    expect(await storage.read(key: 'platform-secret'), isNull);
    expect(keychainCalls.map((call) => call.method), ['read']);
    expect(await documents.list().toList(), isEmpty);
  });

  group('personal macOS credential files', () {
    test(
      'factory performs all credential operations without the keychain',
      () async {
        final storage = createCredentialStorage(documents, macosAdhoc: true);
        expect(storage, isA<LocalCredentialStorage>());
        addTearDown((storage as LocalCredentialStorage).close);

        expect(await storage.read(key: 'source:nas'), isNull);
        await storage.write(key: 'source:nas', value: 'nas-password');
        expect(await storage.containsKey(key: 'source:nas'), isTrue);
        expect(await storage.readAll(), {'source:nas': 'nas-password'});
        await storage.delete(key: 'source:nas');
        await storage.write(key: 'syncToken', value: 'sync-token');
        await storage.deleteAll();
        expect(await storage.readAll(), isEmpty);
        expect(keychainCalls, isEmpty);
      },
    );

    test(
      'credentials persist and distinguish an empty value from deletion',
      () async {
        final first = openLocal();
        await first.write(key: 'source:nas', value: '密码-with-\'quotes\'');
        await first.write(key: 'empty', value: '');
        await first.write(key: 'updated', value: 'old');
        await first.write(key: 'updated', value: 'new');
        await first.close();

        final reopened = openLocal();
        expect(await reopened.read(key: 'source:nas'), '密码-with-\'quotes\'');
        expect(await reopened.read(key: 'empty'), '');
        expect(await reopened.containsKey(key: 'empty'), isTrue);
        expect(await reopened.read(key: 'updated'), 'new');
        expect(await reopened.read(key: 'missing'), isNull);
        expect(await reopened.containsKey(key: 'missing'), isFalse);

        await reopened.write(key: 'empty', value: null);
        await reopened.delete(key: 'source:nas');
        await reopened.close();
        final finalReader = openLocal();
        expect(await finalReader.readAll(), {'updated': 'new'});
        await finalReader.deleteAll();
        expect(await finalReader.readAll(), isEmpty);
        expect(keychainCalls, isEmpty);
      },
    );

    test(
      'open instances see each other’s updates and preserve unrelated keys',
      () async {
        final library = openLocal();
        final player = openLocal();

        expect(await library.read(key: 'source:nas'), isNull);
        expect(await player.read(key: 'source:nas'), isNull);
        await library.write(key: 'source:nas', value: 'initial');
        expect(await player.read(key: 'source:nas'), 'initial');
        await player.write(key: 'aiSubtitleToken', value: 'subtitle-token');
        await library.write(key: 'syncToken', value: 'sync-token');
        await player.write(key: 'source:nas', value: 'replacement');
        expect(await library.readAll(), {
          'source:nas': 'replacement',
          'aiSubtitleToken': 'subtitle-token',
          'syncToken': 'sync-token',
        });
        await player.delete(key: 'source:nas');
        expect(await library.read(key: 'source:nas'), isNull);
        expect(await library.read(key: 'syncToken'), 'sync-token');
      },
    );

    for (final existingStore in [false, true]) {
      test(
        'concurrent isolates preserve credentials in a ${existingStore ? 'reopened' : 'new'} store',
        () async {
          final reader = openLocal();
          if (existingStore) {
            await reader.write(key: 'existing', value: 'preserved');
          }
          final path = documents.path;

          final generatedKeys = await Future.wait([
            _startCredentialWriter(path, 'library'),
            _startCredentialWriter(path, 'player'),
          ]);

          final values = await reader.readAll();
          expect(values.length, existingStore ? 82 : 81);
          if (existingStore) expect(values['existing'], 'preserved');
          expect(
            generatedKeys.first,
            isIn(['generated:library', 'generated:player']),
          );
          expect(generatedKeys.last, generatedKeys.first);
          expect(values['sync.digestKey'], generatedKeys.first);
          for (final prefix in ['library', 'player']) {
            for (var index = 0; index < 40; index++) {
              expect(values['$prefix:$index'], 'updated:$index');
            }
          }
        },
      );
    }

    test(
      'readOrCreate preserves existing credentials including empty values',
      () async {
        final storage = openLocal();
        await storage.write(key: 'existing', value: 'user-entered');
        await storage.write(key: 'empty', value: '');

        expect(
          await storage.readOrCreate(key: 'existing', value: 'recovered'),
          'user-entered',
        );
        expect(
          await storage.readOrCreate(key: 'empty', value: 'recovered'),
          '',
        );
        expect(
          await storage.readOrCreate(key: 'new', value: 'generated'),
          'generated',
        );
        expect(await storage.readAll(), {
          'existing': 'user-entered',
          'empty': '',
          'new': 'generated',
        });
      },
    );

    test(
      'new and existing stores restrict directory and file permissions',
      () async {
        final first = openLocal();
        await first.write(key: 'source:nas', value: 'private');
        expect((await first.directory.stat()).mode & 0x1ff, 0x1c0);
        expect((await File(first.path).stat()).mode & 0x1ff, 0x180);
        await first.close();

        expect(
          (await Process.run('/bin/chmod', [
            '777',
            first.directory.path,
          ])).exitCode,
          0,
        );
        expect(
          (await Process.run('/bin/chmod', ['666', first.path])).exitCode,
          0,
        );
        final reopened = openLocal();
        expect(await reopened.read(key: 'source:nas'), 'private');
        expect((await reopened.directory.stat()).mode & 0x1ff, 0x1c0);
        expect((await File(reopened.path).stat()).mode & 0x1ff, 0x180);
      },
    );

    test(
      'corrupt stores fail without replacing or treating credentials as absent',
      () async {
        final storage = openLocal();
        await storage.directory.create(recursive: true);
        final file = File(storage.path);
        final original = List<int>.generate(256, (index) => (index * 17) % 256);
        await file.writeAsBytes(original);

        await expectLater(
          storage.read(key: 'source:nas'),
          throwsA(isA<AppFailure>()),
        );
        await expectLater(storage.readAll(), throwsA(isA<AppFailure>()));
        await expectLater(
          storage.write(key: 'source:nas', value: 'replacement'),
          throwsA(isA<AppFailure>()),
        );
        expect(await file.readAsBytes(), original);
        expect(keychainCalls, isEmpty);
      },
    );
  }, skip: Platform.isWindows);
}

Future<String> _startCredentialWriter(String documentsPath, String prefix) =>
    Isolate.run(() async {
      final storage = LocalCredentialStorage(Directory(documentsPath));
      try {
        final digestKey = await storage.readOrCreate(
          key: 'sync.digestKey',
          value: 'generated:$prefix',
        );
        for (var index = 0; index < 40; index++) {
          await storage.write(key: '$prefix:$index', value: 'initial:$index');
          await storage.write(key: '$prefix:$index', value: 'updated:$index');
        }
        return digestKey;
      } finally {
        await storage.close();
      }
    });
