import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:aiplayer/playback/native_property_reader.dart';
import 'package:flutter_test/flutter_test.dart';

class _Fixture {
  final DynamicLibrary library;
  late final create = library
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'fixture_create',
      );
  late final release = library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('fixture_release');
  late final blocked = library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('fixture_blocked');
  late final calls = library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('fixture_calls');
  late final maxActive = library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('fixture_max_active');
  late final retire = library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('fixture_retire');
  late final afterRetirement = library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('fixture_after_retirement');
  late final destroy = library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('fixture_destroy');
  late final thread = library.lookupFunction<Uint64 Function(), int Function()>(
    'fixture_thread',
  );

  _Fixture(String path) : library = DynamicLibrary.open(path);
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Native worker did not enter.');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('background native property reader', () {
    late Directory directory;
    late String libraryPath;
    late _Fixture fixture;
    late Pointer<Void> handle;
    late NativePropertyReader reader;

    setUpAll(() async {
      directory = await Directory.systemTemp.createTemp('native-properties-');
      libraryPath = '${directory.path}/fixture.so';
      final compiled = await Process.run('cc', [
        '-std=c11',
        '-shared',
        '-fPIC',
        '-pthread',
        'test/fixtures/native_property_reader_fixture.c',
        '-o',
        libraryPath,
      ]);
      expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
      fixture = _Fixture(libraryPath);
    });

    tearDownAll(() async => directory.delete(recursive: true));

    setUp(() {
      handle = fixture.create();
      reader = NativePropertyReader(
        libraryPath: libraryPath,
        handleAddress: handle.address,
      );
    });

    tearDown(() async {
      fixture.release(handle);
      await reader.close();
      fixture.destroy(handle);
    });

    test(
      'reads on another native thread and returns immutable snapshots',
      () async {
        final callerThread = fixture.thread();
        final values = await reader.read(['thread', 'missing', 'codec']);
        expect(int.parse(values['thread']!), isNot(callerThread));
        expect(values['missing'], '');
        expect(values['codec'], '3:codec');
        expect(() => values['codec'] = 'changed', throwsUnsupportedError);
        final next = await reader.read(['codec']);
        expect(next['codec'], '4:codec');
        expect(values['codec'], '3:codec');
        expect(fixture.maxActive(handle), 1);
      },
    );

    test(
      'blocked native reads leave the caller responsive and bound the queue',
      () async {
        final gated = reader.read(['gate']);
        await _until(() => fixture.blocked(handle) == 1);
        var timerFired = false;
        final timer = Timer(
          const Duration(milliseconds: 15),
          () => timerFired = true,
        );
        final second = reader.read(['second']);
        final third = reader.read(['third']);
        final fourth = reader.read(['fourth']);
        await expectLater(reader.read(['excess']), throwsStateError);
        await Future<void>.delayed(const Duration(milliseconds: 35));
        timer.cancel();
        expect(timerFired, true);
        expect(fixture.calls(handle), 1);
        fixture.release(handle);
        final values = await Future.wait([gated, second, third, fourth]);
        expect(values.map((value) => value.values.single), [
          '1:gate',
          '2:second',
          '3:third',
          '4:fourth',
        ]);
        expect(fixture.maxActive(handle), 1);
      },
    );

    test(
      'close drains accepted requests before the borrowed handle retires',
      () async {
        final first = reader.read(['gate']);
        final second = reader.read(['second']);
        await _until(() => fixture.blocked(handle) == 1);
        var closed = false;
        final closing = reader.close().then((_) => closed = true);
        await expectLater(reader.read(['late']), throwsStateError);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(closed, false);
        fixture.release(handle);
        expect((await first)['gate'], '1:gate');
        expect((await second)['second'], '2:second');
        await closing;
        fixture.retire(handle);
        await reader.close();
        await expectLater(reader.read(['retired']), throwsStateError);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(fixture.calls(handle), 2);
        expect(fixture.afterRetirement(handle), 0);
      },
    );

    test(
      'close before worker readiness still drains the startup outbox',
      () async {
        final reading = reader.read(['codec']);
        final closing = reader.close();
        expect((await reading)['codec'], '1:codec');
        await closing;
        expect(fixture.calls(handle), 1);
      },
    );

    test(
      'unused readers close without accessing the borrowed handle',
      () async {
        await reader.close();
        await reader.close();
        expect(fixture.calls(handle), 0);
        await expectLater(reader.read(['codec']), throwsStateError);
      },
    );

    test(
      'failed library startup rejects reads and still allows close',
      () async {
        final broken = NativePropertyReader(
          libraryPath: '${directory.path}/missing.so',
          handleAddress: handle.address,
        );
        await expectLater(broken.read(['codec']), throwsStateError);
        await broken.close().timeout(const Duration(seconds: 3));
        expect(fixture.calls(handle), 0);
      },
    );

    test('request size is bounded before starting a worker', () async {
      await expectLater(
        reader.read(
          List.filled(
            NativePropertyReader.maxPropertiesPerRequest + 1,
            'codec',
          ),
        ),
        throwsArgumentError,
      );
      await expectLater(reader.read(['']), throwsArgumentError);
      await reader.close();
      expect(fixture.calls(handle), 0);
    });
  }, skip: !Platform.isLinux);
}
