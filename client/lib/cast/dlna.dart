import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:xml/xml.dart';
import '../core/network.dart';

bool isLocalCastAddress(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) return false;
  final b = address.rawAddress;
  return b[0] == 10 ||
      b[0] == 127 ||
      b[0] == 192 && b[1] == 168 ||
      b[0] == 172 && b[1] >= 16 && b[1] <= 31 ||
      b[0] == 169 && b[1] == 254;
}

String _xmlText(XmlElement root, String name) =>
    root.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == name)
        .firstOrNull
        ?.innerText
        .trim() ??
    '';

class DlnaDevice {
  final String id, name, serviceType;
  final Uri description, control;
  final Uri? volumeControl;
  final String? volumeService;
  const DlnaDevice({
    required this.id,
    required this.name,
    required this.description,
    required this.control,
    required this.serviceType,
    this.volumeControl,
    this.volumeService,
  });
  static DlnaDevice parse(Uri location, String xml) {
    if (!['http', 'https'].contains(location.scheme) ||
        location.userInfo.isNotEmpty ||
        !isLocalCastAddress(
          InternetAddress.tryParse(location.host) ?? InternetAddress.anyIPv4,
        )) {
      throw const AppFailure('投屏设备必须位于本地网络。');
    }
    if (xml.length > 1024 * 1024 || xml.toLowerCase().contains('<!doctype')) {
      throw const AppFailure('投屏设备描述格式无效。');
    }
    final root = XmlDocument.parse(xml).rootElement;
    final baseText = _xmlText(root, 'URLBase');
    final base = baseText.isEmpty ? location : location.resolve(baseText);
    Uri endpoint(String value) {
      final uri = base.resolve(value);
      if (value.isEmpty ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host != location.host ||
          uri.userInfo.isNotEmpty) {
        throw const AppFailure('设备返回了不属于它的控制地址。');
      }
      return uri;
    }

    final services = root.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'service',
    );
    final transport = services
        .where(
          (e) => _xmlText(
            e,
            'serviceType',
          ).startsWith('urn:schemas-upnp-org:service:AVTransport:'),
        )
        .firstOrNull;
    final rendering = services
        .where(
          (e) => _xmlText(
            e,
            'serviceType',
          ).startsWith('urn:schemas-upnp-org:service:RenderingControl:'),
        )
        .firstOrNull;
    if (transport == null) throw const AppFailure('该设备没有可用的视频投屏服务。');
    return DlnaDevice(
      id: _xmlText(root, 'UDN').isEmpty
          ? location.toString()
          : _xmlText(root, 'UDN'),
      name: _xmlText(root, 'friendlyName').isEmpty
          ? '局域网播放器'
          : _xmlText(root, 'friendlyName'),
      description: location,
      control: endpoint(_xmlText(transport, 'controlURL')),
      serviceType: _xmlText(transport, 'serviceType'),
      volumeControl: rendering == null
          ? null
          : endpoint(_xmlText(rendering, 'controlURL')),
      volumeService: rendering == null
          ? null
          : _xmlText(rendering, 'serviceType'),
    );
  }
}

class DlnaClient {
  final Duration timeout;
  final HttpClient _http;
  bool _closed = false;
  DlnaClient({this.timeout = const Duration(seconds: 8), HttpClient? http})
    : _http = http ?? HttpClient() {
    _http.connectionTimeout = timeout;
  }
  Future<String> _request(
    Uri uri, {
    String? action,
    String? service,
    String? body,
  }) async {
    if (_closed) throw const Cancelled();
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        !isLocalCastAddress(
          InternetAddress.tryParse(uri.host) ?? InternetAddress.anyIPv4,
        )) {
      throw const AppFailure('投屏地址必须是局域网 IP 地址。');
    }
    try {
      final request = await _http
          .openUrl(body == null ? 'GET' : 'POST', uri)
          .timeout(timeout);
      request.followRedirects = false;
      if (body != null) {
        request.headers.set(
          HttpHeaders.contentTypeHeader,
          'text/xml; charset="utf-8"',
        );
        request.headers.set('SOAPACTION', '"$service#$action"');
        final bytes = utf8.encode(body);
        // Older renderers require a fixed length and reject chunked SOAP.
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(timeout);
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        if (bytes.length + chunk.length > 1024 * 1024) {
          throw const AppFailure('投屏设备返回的数据过大。');
        }
        bytes.addAll(chunk);
      }
      final value = utf8.decode(bytes, allowMalformed: false);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = RegExp(
          r'<(?:\w+:)?errorCode>(\d+)</',
        ).firstMatch(value)?.group(1);
        throw AppFailure(
          code == null
              ? '投屏请求失败（HTTP ${response.statusCode}）。'
              : '投屏设备返回错误 $code，请检查设备支持的视频格式和播放状态。',
        );
      }
      return value;
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      throw const AppFailure('投屏设备响应超时。');
    } catch (_) {
      if (_closed) throw const Cancelled();
      throw const AppFailure('无法连接投屏设备，请确认在同一局域网。');
    }
  }

  Future<DlnaDevice> describe(Uri uri) async =>
      DlnaDevice.parse(uri, await _request(uri));
  Future<Map<String, String>> command(
    DlnaDevice device,
    String action, [
    Map<String, String> arguments = const {},
    bool volume = false,
  ]) async {
    final service = volume ? device.volumeService : device.serviceType;
    final control = volume ? device.volumeControl : device.control;
    if (service == null || control == null) {
      throw const AppFailure('设备不支持远程音量控制。');
    }
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="utf-8"');
    builder.element(
      's:Envelope',
      attributes: {
        'xmlns:s': 'http://schemas.xmlsoap.org/soap/envelope/',
        's:encodingStyle': 'http://schemas.xmlsoap.org/soap/encoding/',
      },
      nest: () {
        builder.element(
          's:Body',
          nest: () {
            builder.element(
              'u:$action',
              attributes: {'xmlns:u': service},
              nest: () {
                builder.element('InstanceID', nest: '0');
                arguments.forEach(
                  (name, value) => builder.element(name, nest: value),
                );
              },
            );
          },
        );
      },
    );
    final value = await _request(
      control,
      action: action,
      service: service,
      body: builder.buildDocument().toXmlString(),
    );
    if (value.isEmpty) return {};
    try {
      final xml = XmlDocument.parse(value);
      return {
        for (final e in xml.descendants.whereType<XmlElement>())
          if (e.childElements.isEmpty) e.name.local: e.innerText,
      };
    } on XmlParserException {
      throw const AppFailure('投屏设备返回的控制结果无效。');
    }
  }

  Future<void> open(
    DlnaDevice device,
    Uri video,
    String title,
    String mime,
  ) async {
    final b = XmlBuilder();
    b.element(
      'DIDL-Lite',
      attributes: {
        'xmlns': 'urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/',
        'xmlns:dc': 'http://purl.org/dc/elements/1.1/',
        'xmlns:upnp': 'urn:schemas-upnp-org:metadata-1-0/upnp/',
      },
      nest: () {
        b.element(
          'item',
          attributes: {'id': '0', 'parentID': '-1', 'restricted': '1'},
          nest: () {
            b.element('dc:title', nest: title);
            b.element('upnp:class', nest: 'object.item.videoItem');
            b.element(
              'res',
              attributes: {'protocolInfo': 'http-get:*:$mime:*'},
              nest: video.toString(),
            );
          },
        );
      },
    );
    await command(device, 'SetAVTransportURI', {
      'CurrentURI': video.toString(),
      'CurrentURIMetaData': b.buildDocument().toXmlString(),
    });
    await command(device, 'Play', {'Speed': '1'});
  }

  Future<void> play(DlnaDevice d) async {
    await command(d, 'Play', {'Speed': '1'});
  }

  Future<void> pause(DlnaDevice d) async {
    await command(d, 'Pause');
  }

  Future<void> stop(DlnaDevice d) async {
    await command(d, 'Stop');
  }

  Future<void> seek(DlnaDevice d, Duration time) async {
    final seconds = time.inSeconds.clamp(0, 1 << 40);
    String two(int n) => n.toString().padLeft(2, '0');
    await command(d, 'Seek', {
      'Unit': 'REL_TIME',
      'Target':
          '${two(seconds ~/ 3600)}:${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}',
    });
  }

  Future<void> volume(DlnaDevice d, int value) async {
    await command(d, 'SetVolume', {
      'Channel': 'Master',
      'DesiredVolume': '${value.clamp(0, 100)}',
    }, true);
  }

  static Duration parseTime(String? value) {
    final parts = (value ?? '').split(':');
    if (parts.length != 3) return Duration.zero;
    final h = int.tryParse(parts[0]),
        m = int.tryParse(parts[1]),
        s = double.tryParse(parts[2]);
    if (h == null ||
        m == null ||
        s == null ||
        !s.isFinite ||
        h < 0 ||
        m < 0 ||
        s < 0) {
      return Duration.zero;
    }
    return Duration(milliseconds: ((h * 3600 + m * 60 + s) * 1000).round());
  }

  void close() {
    _closed = true;
    _http.close(force: true);
  }
}

class DlnaDiscovery {
  Future<List<DlnaDevice>> scan({
    CancelToken? cancel,
    Duration duration = const Duration(seconds: 5),
  }) async {
    cancel?.check();
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.multicastHops = 1;
    final client = DlnaClient(timeout: const Duration(seconds: 4));
    final found = <String, DlnaDevice>{};
    final seen = <String>{};
    final tasks = <Future<void>>[];
    var closed = false;
    final listener = socket.listen((event) {
      if (event != RawSocketEvent.read || closed) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final packet = datagram!;
        if (!isLocalCastAddress(packet.address) || seen.length >= 24) continue;
        final text = utf8.decode(packet.data, allowMalformed: true);
        final location = RegExp(
          r'^location:\s*(.+)$',
          multiLine: true,
          caseSensitive: false,
        ).firstMatch(text)?.group(1)?.trim();
        final uri = location == null ? null : Uri.tryParse(location);
        if (uri == null ||
            uri.host != packet.address.address ||
            !seen.add(uri.toString())) {
          continue;
        }
        if (tasks.length >= 8) continue;
        tasks.add(() async {
          try {
            final device = await client.describe(uri);
            if (!closed && !(cancel?.cancelled ?? false)) {
              found[device.id] = device;
            }
          } catch (_) {
            /* Ignore unrelated or malformed SSDP responders. */
          }
        }());
      }
    });
    try {
      final request = utf8.encode(
        'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n',
      );
      socket.send(request, InternetAddress('239.255.255.250'), 1900);
      await Future.any([
        Future<void>.delayed(duration),
        if (cancel != null) cancel.whenCancelled,
      ]);
      cancel?.check();
      socket.close();
      await Future.wait(tasks);
      return found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    } finally {
      closed = true;
      socket.close();
      client.close();
      await listener.cancel();
    }
  }
}
