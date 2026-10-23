import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import '../core/network.dart';

const _channel = MethodChannel('app.aiplayer/discovery');
const _serviceTypes = ['_smb._tcp', '_webdav._tcp', '_webdavs._tcp'];
int _appleScanSerial = 0;

Future<T> _cancellable<T>(
  Future<T> work,
  CancelToken cancel,
  Duration timeout,
) async {
  final expired = Completer<T>();
  final timer = Timer(
    timeout,
    () => expired.completeError(TimeoutException('Discovery timed out')),
  );
  try {
    return await Future.any<T>([
      work,
      expired.future,
      cancel.whenCancelled.then((_) => throw const Cancelled()),
    ]);
  } finally {
    timer.cancel();
  }
}

bool isPrivateIpv4(String address) {
  final parts = address.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((p) => p == null || p < 0 || p > 255)) {
    return false;
  }
  return parts[0] == 10 ||
      parts[0] == 172 && parts[1]! >= 16 && parts[1]! <= 31 ||
      parts[0] == 192 && parts[1] == 168;
}

int _ipv4(String address) =>
    address.split('.').map(int.parse).fold(0, (v, b) => (v << 8) | b);
String _address(int value) =>
    [24, 16, 8, 0].map((n) => (value >> n) & 255).join('.');

class LocalNetwork {
  final String address;
  final int prefixLength;
  const LocalNetwork(this.address, this.prefixLength);

  bool get valid =>
      isPrivateIpv4(address) && prefixLength >= 8 && prefixLength <= 30;
  bool contains(String candidate) {
    if (!valid || !isPrivateIpv4(candidate)) return false;
    final mask = (0xffffffff << (32 - prefixLength)) & 0xffffffff;
    return (_ipv4(address) & mask) == (_ipv4(candidate) & mask);
  }
}

/// At most 254 neighbours, always inside a verified interface prefix. For large
/// LANs, only the interface's immediate /24 window is probed.
List<String> smbProbeTargets(List<LocalNetwork> networks, {int limit = 254}) {
  final own = networks.map((n) => n.address).toSet();
  final targets = <String>{};
  for (final network in networks.where((n) => n.valid)) {
    final ip = _ipv4(network.address);
    final mask = (0xffffffff << (32 - network.prefixLength)) & 0xffffffff;
    final first = math.max((ip & mask) + 1, (ip & 0xffffff00) + 1);
    final last =
        math.min((ip & mask) | (~mask & 0xffffffff), (ip & 0xffffff00) + 255) -
        1;
    for (var candidate = first; candidate <= last; candidate++) {
      final address = _address(candidate);
      if (!own.contains(address)) targets.add(address);
      if (targets.length >= limit.clamp(0, 254)) {
        return targets.take(limit.clamp(0, 254)).toList();
      }
    }
  }
  return targets.toList();
}

class DiscoveredSource {
  final String kind, name, host, path;
  final int port;
  final bool secure, advertised;
  const DiscoveredSource({
    required this.kind,
    required this.name,
    required this.host,
    required this.port,
    this.path = '/',
    this.secure = false,
    this.advertised = true,
  });
  String get id => '$kind:$host:$port';
  String get endpoint => Uri(host: host, port: port).authority;
  Map<String, dynamic> get configuration => {
    'kind': kind,
    'label': name,
    if (kind == 'smb') 'host': port == 445 ? host : endpoint,
    if (kind == 'webdav')
      'url': Uri(
        scheme: secure ? 'https' : 'http',
        host: host,
        port: port,
        path: path.startsWith('/') ? path : '/$path',
      ).toString(),
  };
}

class DiscoverySnapshot {
  final List<DiscoveredSource> services;
  final int completed, total;
  final bool running, cancelled;
  final String warning;
  const DiscoverySnapshot({
    this.services = const [],
    this.completed = 0,
    this.total = 0,
    this.running = false,
    this.cancelled = false,
    this.warning = '',
  });
}

typedef InterfaceReader = Future<List<LocalNetwork>> Function();
typedef PortProbe =
    Future<bool> Function(String host, int port, CancelToken cancel);
typedef ServiceBrowser =
    Future<void> Function(
      CancelToken cancel,
      Duration duration,
      void Function(DiscoveredSource) found,
    );

class LanDiscovery {
  final InterfaceReader interfaces;
  final PortProbe probe;
  final ServiceBrowser browse;
  final int concurrency;
  final Duration duration;
  LanDiscovery({
    InterfaceReader? interfaces,
    PortProbe? probe,
    ServiceBrowser? browse,
    this.concurrency = 24,
    this.duration = const Duration(seconds: 6),
  }) : interfaces = interfaces ?? readLocalNetworks,
       probe = probe ?? probeSmbPort,
       browse = browse ?? browseLocalServices;

  Future<DiscoverySnapshot> scan({
    required CancelToken cancel,
    required void Function(DiscoverySnapshot) onUpdate,
  }) async {
    final found = <String, DiscoveredSource>{};
    var completed = 0, total = 0;
    var warning = '';
    var active = true;
    final clock = Stopwatch()..start();
    var lastUpdate = -100;
    DiscoverySnapshot snapshot(bool running) => DiscoverySnapshot(
      services: found.values.toList()..sort((a, b) => a.name.compareTo(b.name)),
      completed: completed,
      total: total,
      running: running,
      cancelled: cancel.cancelled,
      warning: warning,
    );
    void emit({bool force = false}) {
      if (!active || cancel.cancelled) return;
      if (force || clock.elapsedMilliseconds - lastUpdate >= 80) {
        lastUpdate = clock.elapsedMilliseconds;
        onUpdate(snapshot(true));
      }
    }

    void discovered(DiscoveredSource service) {
      if (!active || cancel.cancelled) return;
      final old = found[service.id];
      if (old == null || service.advertised) found[service.id] = service;
      emit(force: true);
    }

    void failure(Object error) {
      if (error is Cancelled || cancel.cancelled) return;
      if (_permissionDenied(error)) {
        warning = '局域网访问被系统拒绝，请在系统设置中允许本地网络访问。';
      } else if (warning.isEmpty) {
        warning = '部分发现方式不可用，可手动添加来源。';
      }
      emit(force: true);
    }

    emit(force: true);
    final servicesTask = Future<void>.sync(
      () => browse(cancel, duration, discovered),
    ).catchError(failure);
    Future<void> hosts() async {
      try {
        final networks = await _cancellable(
          interfaces(),
          cancel,
          const Duration(seconds: 3),
        );
        cancel.check();
        final targets = smbProbeTargets(networks);
        total = targets.length;
        if (targets.isEmpty && warning.isEmpty) {
          warning = '未获取到局域网 IPv4 网段，仅查找广播服务。';
        }
        emit(force: true);
        var next = 0;
        Future<void> worker() async {
          while (!cancel.cancelled && next < targets.length) {
            final host = targets[next++];
            try {
              if (await probe(host, 445, cancel)) {
                discovered(
                  DiscoveredSource(
                    kind: 'smb',
                    name: host,
                    host: host,
                    port: 445,
                    advertised: false,
                  ),
                );
              }
            } catch (e) {
              failure(e);
              if (_permissionDenied(e)) break;
            }
            completed++;
            emit();
          }
        }

        await Future.wait(
          List.generate(concurrency.clamp(1, 24), (_) => worker()),
        );
      } catch (e) {
        failure(e);
      }
    }

    await Future.any<void>([
      Future.wait<void>([servicesTask, hosts()]).then((_) {}),
      cancel.whenCancelled,
    ]);
    active = false;
    final result = snapshot(false);
    onUpdate(result);
    return result;
  }
}

bool _permissionDenied(Object error) =>
    error is PlatformException && error.code == 'permission_denied' ||
    error is SocketException &&
        [1, 13, 10013].contains(error.osError?.errorCode);

Future<bool> probeSmbPort(String host, int port, CancelToken cancel) async {
  cancel.check();
  ConnectionTask<Socket>? connection;
  Socket? socket;
  try {
    connection = await Socket.startConnect(host, port);
    socket = await _cancellable(
      connection.socket,
      cancel,
      const Duration(milliseconds: 450),
    );
    cancel.check();
    return true;
  } on SocketException catch (e) {
    if (_permissionDenied(e)) rethrow;
    return false;
  } on TimeoutException {
    return false;
  } finally {
    socket?.destroy();
    connection?.cancel();
  }
}

Future<List<LocalNetwork>> readLocalNetworks() async {
  try {
    final entries = await _channel.invokeListMethod<dynamic>('interfaces');
    if (entries != null) {
      return entries
          .whereType<Map>()
          .map(
            (e) => LocalNetwork(
              '${e['address']}',
              (e['prefixLength'] as num?)?.toInt() ?? 0,
            ),
          )
          .where((n) => n.valid)
          .toList();
    }
  } on MissingPluginException {
    // Desktop platforms may use the system routing table instead.
  }
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  final addresses = <String, List<String>>{
    for (final iface in interfaces)
      if (!RegExp(
        r'^(tun|tap|utun|veth|docker|virbr|vmnet|vbox)',
        caseSensitive: false,
      ).hasMatch(iface.name))
        iface.name: iface.addresses
            .map((a) => a.address)
            .where(isPrivateIpv4)
            .toList(),
  };
  if (Platform.isLinux || Platform.isAndroid) {
    try {
      final routes = await File('/proc/net/route').readAsLines();
      final result = <LocalNetwork>[];
      for (final row in routes.skip(1)) {
        final fields = row.trim().split(RegExp(r'\s+'));
        if (fields.length < 8 ||
            !addresses.containsKey(fields[0]) ||
            fields[2] != '00000000') {
          continue;
        }
        int routeNumber(String hex) {
          final little = int.tryParse(hex, radix: 16) ?? 0;
          return ((little & 255) << 24) |
              ((little & 0xff00) << 8) |
              ((little >> 8) & 0xff00) |
              ((little >> 24) & 255);
        }

        final mask = routeNumber(fields[7]);
        final bits = mask.toRadixString(2).replaceAll('0', '').length;
        if (bits < 8 ||
            bits > 30 ||
            mask != ((0xffffffff << (32 - bits)) & 0xffffffff)) {
          continue;
        }
        for (final address in addresses[fields[0]]!) {
          if ((_ipv4(address) & mask) == routeNumber(fields[1])) {
            result.add(LocalNetwork(address, bits));
          }
        }
      }
      return result;
    } on FileSystemException {
      return [];
    }
  }
  if (Platform.isWindows) {
    // Only read OS interface metadata; never interpolate user input into shell code.
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Get-NetIPAddress -AddressFamily IPv4 | Select-Object IPAddress,PrefixLength | ConvertTo-Json -Compress',
    ]).timeout(const Duration(seconds: 2));
    if (result.exitCode == 0) {
      final json = jsonDecode('${result.stdout}');
      final entries = json is List ? json : [json];
      final own = addresses.values.expand((v) => v).toSet();
      return entries
          .whereType<Map>()
          .where((e) => own.contains(e['IPAddress']))
          .map(
            (e) => LocalNetwork(
              '${e['IPAddress']}',
              (e['PrefixLength'] as num).toInt(),
            ),
          )
          .where((n) => n.valid)
          .toList();
    }
  }
  return [];
}

Future<void> browseLocalServices(
  CancelToken cancel,
  Duration duration,
  void Function(DiscoveredSource) found,
) async {
  cancel.check();
  if (Platform.isIOS || Platform.isMacOS) {
    final serial = ++_appleScanSerial;
    var finished = false;
    unawaited(
      cancel.whenCancelled.then((_) async {
        if (!finished && serial == _appleScanSerial) {
          try {
            await _channel.invokeMethod<void>('cancel');
          } catch (_) {
            /* best effort */
          }
        }
      }),
    );
    try {
      final response = await _cancellable(
        _channel.invokeListMethod<dynamic>('scan', {
          'types': _serviceTypes,
          'timeoutMs': duration.inMilliseconds,
        }),
        cancel,
        duration + const Duration(seconds: 2),
      );
      cancel.check();
      for (final entry in response ?? []) {
        if (entry is! Map) continue;
        final kind = '${entry['kind']}';
        final host = '${entry['host'] ?? ''}'.replaceFirst(RegExp(r'\.$'), '');
        final port = (entry['port'] as num?)?.toInt() ?? 0;
        if (!['smb', 'webdav', 'webdavs'].contains(kind) ||
            host.isEmpty ||
            port < 1 ||
            port > 65535) {
          continue;
        }
        found(
          DiscoveredSource(
            kind: kind == 'smb' ? 'smb' : 'webdav',
            name: '${entry['name'] ?? host}',
            host: host,
            port: port,
            path: '${entry['path'] ?? '/'}',
            secure: kind == 'webdavs',
          ),
        );
      }
    } finally {
      finished = true;
    }
    return;
  }
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final registry = MdnsRegistry();
  final queried = <String>{};
  final seen = <String>{};
  final done = Completer<void>();
  StreamSubscription<RawSocketEvent>? subscription;
  Timer? retry, deadline;
  try {
    cancel.check();
    socket.multicastHops = 255;
    void query(String name, int type) {
      final key = '$name:$type';
      if (queried.length >= 256 || !queried.add(key)) return;
      socket.send(mdnsQuery(name, type), InternetAddress('224.0.0.251'), 5353);
    }

    void failed(Object error) {
      if (!done.isCompleted) done.completeError(error);
    }

    subscription = socket.listen((event) {
      if (event != RawSocketEvent.read || cancel.cancelled) return;
      Datagram? packet;
      while ((packet = socket.receive()) != null) {
        if (packet!.port != 5353 || !isPrivateIpv4(packet.address.address)) {
          continue;
        }
        registry.add(packet.data);
        for (final question in registry.questions) {
          query(question.$1, question.$2);
        }
        for (final service in registry.services) {
          final identity = '${service.id}:${service.name}:${service.path}';
          if (seen.add(identity)) found(service);
        }
      }
    }, onError: failed);
    for (final type in _serviceTypes) {
      query('$type.local', 12);
    }
    retry = Timer(const Duration(seconds: 2), () {
      if (cancel.cancelled) return;
      try {
        queried.clear();
        for (final type in _serviceTypes) {
          query('$type.local', 12);
        }
      } catch (e) {
        failed(e);
      }
    });
    deadline = Timer(duration, () {
      if (!done.isCompleted) done.complete();
    });
    await Future.any<void>([done.future, cancel.whenCancelled]);
  } finally {
    retry?.cancel();
    deadline?.cancel();
    await subscription?.cancel();
    socket.close();
  }
}

Uint8List mdnsQuery(String name, int type) {
  final bytes = BytesBuilder()..add([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
  for (final label in name.split('.').where((s) => s.isNotEmpty)) {
    final encoded = utf8.encode(label);
    if (encoded.length > 63) throw const FormatException('DNS label too long');
    bytes.add([encoded.length]);
    bytes.add(encoded);
  }
  // Legacy queries originate at an ephemeral port and request unicast replies.
  bytes.add([0, type >> 8, type & 255, 0, 1]);
  return bytes.takeBytes();
}

/// Bounds-checked DNS reader, including compressed names and split responses.
class MdnsRegistry {
  final _instances = <String, String>{};
  final _names = <String, String>{};
  final _servers = <String, ({String host, int port})>{};
  final _addresses = <String, String>{};
  final _paths = <String, String>{};
  Iterable<(String, int)> get questions sync* {
    for (final name in _instances.keys) {
      if (!_servers.containsKey(name)) yield (name, 33);
      if (!_paths.containsKey(name)) yield (name, 16);
    }
    for (final server in _servers.values) {
      if (!_addresses.containsKey(server.host)) yield (server.host, 1);
    }
  }

  Iterable<DiscoveredSource> get services sync* {
    for (final instance in _instances.entries) {
      final key = instance.key;
      final server = _servers[key];
      if (server == null || server.port == 0) continue;
      final host = _addresses[server.host];
      if (host == null || !isPrivateIpv4(host)) continue;
      final type = instance.value;
      final suffix = '.$type.local';
      final name = (_names[key] ?? key).substring(
        0,
        key.length - suffix.length,
      );
      yield DiscoveredSource(
        kind: type == '_smb._tcp' ? 'smb' : 'webdav',
        name: name,
        host: host,
        port: server.port,
        secure: type == '_webdavs._tcp',
        path: _paths[key] ?? '/',
      );
    }
  }

  void add(List<int> data) {
    if (data.length < 12 || data.length > 65535 || data[2] & 0x80 == 0) return;
    final reader = _DnsReader(Uint8List.fromList(data));
    try {
      reader.offset = 4;
      final questions = reader.u16();
      final records = reader.u16() + reader.u16() + reader.u16();
      if (questions > 64 || records > 512) return;
      for (var i = 0; i < questions; i++) {
        reader.name();
        reader.offset += 4;
      }
      for (var i = 0; i < records; i++) {
        final name = reader.name().toLowerCase();
        final type = reader.u16();
        reader.u16();
        final ttl = reader.u32();
        final length = reader.u16(), start = reader.offset;
        final end = start + length;
        if (end > data.length) return;
        if (ttl == 0) {
          reader.offset = end;
          continue;
        }
        if (type == 12) {
          final label = reader.name();
          final instance = label.toLowerCase();
          final service = name.replaceFirst(RegExp(r'\.local$'), '');
          if (_serviceTypes.contains(service) &&
              instance.endsWith('.$name') &&
              _instances.length < 128) {
            _instances[instance] = service;
            _names[instance] = label;
          }
        } else if (type == 33 && length >= 7 && _servers.length < 128) {
          reader.offset += 4;
          final port = reader.u16();
          _servers[name] = (host: reader.name().toLowerCase(), port: port);
        } else if (type == 1 && length == 4 && _addresses.length < 128) {
          _addresses[name] = data.sublist(start, end).join('.');
        } else if (type == 16) {
          while (reader.offset < end) {
            final n = reader.byte();
            if (reader.offset + n > end) break;
            final text = utf8.decode(
              data.sublist(reader.offset, reader.offset + n),
              allowMalformed: true,
            );
            reader.offset += n;
            if (text.startsWith('path=') &&
                text.length <= 2048 &&
                _paths.length < 128) {
              final path = text.substring(5);
              if (path.startsWith('/') &&
                  !path.contains(RegExp(r'[\x00-\x1f]'))) {
                _paths[name] = path;
              }
            }
          }
        }
        reader.offset = end;
      }
    } on FormatException {
      return;
    } on RangeError {
      return;
    }
  }
}

class _DnsReader {
  final Uint8List data;
  int offset = 0;
  _DnsReader(this.data);
  int byte() => data[offset++];
  int u16() => (byte() << 8) | byte();
  int u32() => (u16() << 16) | u16();
  String name() {
    final labels = <String>[];
    final seen = <int>{};
    int? continuation;
    var cursor = offset;
    while (true) {
      if (cursor >= data.length || !seen.add(cursor) || seen.length > 128) {
        throw const FormatException('Invalid DNS name');
      }
      final n = data[cursor++];
      if (n == 0) break;
      if (n & 0xc0 == 0xc0) {
        if (cursor >= data.length) {
          throw const FormatException('Invalid DNS pointer');
        }
        continuation ??= cursor + 1;
        cursor = ((n & 0x3f) << 8) | data[cursor];
      } else {
        if (n > 63 || cursor + n > data.length) {
          throw const FormatException('Invalid DNS label');
        }
        labels.add(
          utf8.decode(data.sublist(cursor, cursor + n), allowMalformed: true),
        );
        cursor += n;
      }
    }
    offset = continuation ?? cursor;
    return labels.join('.');
  }
}
