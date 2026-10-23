import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/sources/discovery.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'SMB targets stay in verified private prefixes and obey total limit',
    () {
      const narrow = LocalNetwork('192.168.2.200', 25);
      final hosts = smbProbeTargets([narrow]);
      expect(hosts.length, 125);
      expect(hosts.every(narrow.contains), isTrue);
      expect(hosts, isNot(contains('192.168.2.128')));
      expect(hosts, isNot(contains('192.168.2.255')));
      expect(hosts, isNot(contains(narrow.address)));
      expect(
        smbProbeTargets([
          const LocalNetwork('10.2.4.10', 8),
          const LocalNetwork('172.16.4.1', 24),
        ]).length,
        254,
      );
      expect(
        smbProbeTargets([
          const LocalNetwork('8.8.8.8', 24),
          const LocalNetwork('127.0.0.1', 8),
          const LocalNetwork('169.254.1.2', 16),
          const LocalNetwork('192.168.1.10', 0),
        ]),
        isEmpty,
      );
      expect(smbProbeTargets([narrow], limit: 0), isEmpty);
    },
  );

  test('mDNS handles compressed PTR plus split SRV/A/TXT responses', () {
    final registry = MdnsRegistry();
    final label = utf8.encode('Office NAS');
    registry.add(
      _packet([
        _record('_smb._tcp.local', 12, [label.length, ...label, 0xc0, 12]),
      ]),
    );
    expect(registry.services, isEmpty);
    expect(registry.questions, contains(('office nas._smb._tcp.local', 33)));
    registry.add(
      _packet([
        _record('Office NAS._smb._tcp.local', 33, [
          0,
          0,
          0,
          0,
          1,
          189,
          ..._name('nas.local'),
        ]),
        _record('nas.local', 1, [192, 168, 2, 50]),
      ]),
    );
    final smb = registry.services.single;
    expect(smb.name, 'Office NAS');
    expect(smb.host, '192.168.2.50');
    expect(smb.configuration['host'], '192.168.2.50');
    expect(smb.advertised, isTrue);

    final path = utf8.encode('path=/媒体/');
    registry.add(
      _packet([
        _record('_webdavs._tcp.local', 12, _name('云端片库._webdavs._tcp.local')),
        _record('云端片库._webdavs._tcp.local', 33, [
          0,
          0,
          0,
          0,
          0x20,
          0xfb,
          ..._name('nas.local'),
        ]),
        _record('云端片库._webdavs._tcp.local', 16, [path.length, ...path]),
      ]),
    );
    final webdav = registry.services.firstWhere((s) => s.kind == 'webdav');
    final uri = Uri.parse(webdav.configuration['url'] as String);
    expect(uri.scheme, 'https');
    expect(uri.port, 8443);
    expect(Uri.decodeComponent(uri.path), '/媒体/');
  });

  test(
    'mDNS rejects malformed compression, public addresses and unrelated HTTP',
    () {
      final registry = MdnsRegistry();
      registry.add([0, 0, 0x80, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0xc0, 12]);
      registry.add([0, 0, 0]);
      registry.add(
        _packet([
          _record('_http._tcp.local', 12, _name('Web._http._tcp.local')),
          _record('Web._http._tcp.local', 33, [
            0,
            0,
            0,
            0,
            0,
            80,
            ..._name('host.local'),
          ]),
          _record('host.local', 1, [192, 168, 1, 1]),
          _record('_smb._tcp.local', 12, _name('Outside._smb._tcp.local')),
          _record('Outside._smb._tcp.local', 33, [
            0,
            0,
            0,
            0,
            1,
            189,
            ..._name('public.local'),
          ]),
          _record('public.local', 1, [8, 8, 8, 8]),
        ]),
      );
      expect(registry.services, isEmpty);
      final query = mdnsQuery('_smb._tcp.local', 12);
      expect(query.sublist(4, 6), [0, 1]);
      expect(query.sublist(query.length - 4), [0, 12, 0, 1]);
    },
  );

  test(
    'discovery caps concurrency and keeps advertised service identity',
    () async {
      var active = 0, peak = 0, attempts = 0;
      final snapshots = <DiscoverySnapshot>[];
      final discovery = LanDiscovery(
        concurrency: 100,
        interfaces: () async => [const LocalNetwork('192.168.1.2', 24)],
        browse: (cancel, duration, found) async {
          found(
            const DiscoveredSource(
              kind: 'smb',
              name: 'My NAS',
              host: '192.168.1.50',
              port: 445,
            ),
          );
        },
        probe: (host, port, cancel) async {
          expect(port, 445);
          attempts++;
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          active--;
          return host == '192.168.1.50';
        },
      );
      final result = await discovery.scan(
        cancel: CancelToken(),
        onUpdate: snapshots.add,
      );
      expect(attempts, 253);
      expect(peak, lessThanOrEqualTo(24));
      expect(result.services.single.name, 'My NAS');
      expect(result.services.single.advertised, isTrue);
      expect(result.running, isFalse);
      expect(result.completed, result.total);
      expect(snapshots.first.running, isTrue);
    },
  );

  test('cancel stops probes and suppresses late service callbacks', () async {
    final started = Completer<void>();
    final cancel = CancelToken();
    late void Function(DiscoveredSource) lateFound;
    var attempts = 0, updates = 0;
    final discovery = LanDiscovery(
      interfaces: () async => [const LocalNetwork('192.168.1.2', 24)],
      browse: (token, duration, found) async {
        lateFound = found;
        await token.whenCancelled;
      },
      probe: (host, port, token) async {
        attempts++;
        if (!started.isCompleted) started.complete();
        await token.whenCancelled;
        token.check();
        return false;
      },
    );
    final scan = discovery.scan(cancel: cancel, onUpdate: (_) => updates++);
    await started.future;
    cancel.cancel();
    final result = await scan;
    final updatesAtFinish = updates;
    lateFound(
      const DiscoveredSource(
        kind: 'smb',
        name: 'late',
        host: '192.168.1.3',
        port: 445,
      ),
    );
    expect(result.cancelled, isTrue);
    expect(result.services, isEmpty);
    expect(attempts, lessThanOrEqualTo(24));
    expect(updates, updatesAtFinish);
  });

  test(
    'permission rejection produces a useful warning without false services',
    () async {
      final discovery = LanDiscovery(
        interfaces: () async =>
            throw PlatformException(code: 'permission_denied'),
        browse: (cancel, duration, found) async {},
        probe: (_, _, _) async => fail('must not probe without a local prefix'),
      );
      final result = await discovery.scan(
        cancel: CancelToken(),
        onUpdate: (_) {},
      );
      expect(result.warning, contains('拒绝'));
      expect(result.services, isEmpty);
      expect(result.running, isFalse);
    },
  );

  test('TCP probe reaches a listening socket and closes it', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final subscription = server.listen((socket) => socket.destroy());
    try {
      expect(await probeSmbPort('127.0.0.1', port, CancelToken()), isTrue);
    } finally {
      await subscription.cancel();
      await server.close();
    }
    expect(await probeSmbPort('127.0.0.1', port, CancelToken()), isFalse);
  });
}

List<int> _name(String value) => [
  for (final label in value.split('.')) ...[
    utf8.encode(label).length,
    ...utf8.encode(label),
  ],
  0,
];
List<int> _record(String name, int type, List<int> value) => [
  ..._name(name),
  type >> 8,
  type & 255,
  0,
  1,
  0,
  0,
  0,
  120,
  value.length >> 8,
  value.length & 255,
  ...value,
];
List<int> _packet(List<List<int>> records) => [
  0,
  0,
  0x84,
  0,
  0,
  0,
  records.length >> 8,
  records.length & 255,
  0,
  0,
  0,
  0,
  for (final record in records) ...record,
];
