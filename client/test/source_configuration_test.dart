import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/sources/configuration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'SMB server configuration does not require a share and keeps security mode',
    () {
      final value = buildSourceConfiguration(
        kind: 'smb',
        smbSecurity: 'encrypt',
        fields: {'host': 'nas.local', 'port': '1445'},
      );
      expect(value['share'], '');
      expect(value['label'], 'nas.local');
      expect(value['smbSecurity'], 'encrypt');
    },
  );
  test('pasted WebDAV and UNC addresses split safely into fields', () {
    final dav = splitPastedSourceAddress(
      'http://nas.local:8080/dav/%E5%8A%A8%E6%BC%AB/',
      kind: 'webdav',
    )!;
    expect(dav['host'], 'nas.local');
    expect(dav['port'], 8080);
    expect(dav['encrypted'], false);
    expect(dav['path'], '/dav/动漫/');
    final smb = splitPastedSourceAddress(r'\\nas.local\videos', kind: 'smb')!;
    expect(smb['host'], 'nas.local');
    expect(smb['share'], 'videos');
    expect(smb['port'], 445);
    expect(
      () => splitPastedSourceAddress(
        'https://user:private@nas.local/dav/',
        kind: 'webdav',
      ),
      throwsA(isA<AppFailure>()),
    );
    expect(
      () => splitPastedSourceAddress(
        'https://nas.local/share?token=private',
        kind: 'webdav',
      ),
      throwsA(isA<AppFailure>()),
    );
  });
  test('legacy SMB host and WebDAV URL become editable component fields', () {
    final smb = sourceFormValues({'kind': 'smb', 'host': 'nas.local:1445'});
    expect(smb['host'], 'nas.local');
    expect(smb['port'], 1445);
    final dav = sourceFormValues({
      'kind': 'webdav',
      'url': 'https://nas.local:8443/dav/%E5%8A%A8%E6%BC%AB/',
    });
    expect(dav['host'], 'nas.local');
    expect(dav['port'], 8443);
    expect(dav['path'], '/dav/动漫/');
    expect(dav['encrypted'], true);
  });

  test(
    'SMB defaults and independent port survive configuration round trip',
    () {
      expect(sourceFormValues(null)['port'], 445);
      final source = buildSourceConfiguration(
        kind: 'smb',
        fields: {
          'host': ' nas.local ',
          'port': '1445',
          'share': '动漫',
          'password': ' keep spaces ',
        },
      );
      expect(source['host'], 'nas.local');
      expect(source['port'], 1445);
      expect(source['label'], 'nas.local · 动漫');
      expect(source['password'], ' keep spaces ');
      expect(sourceFormValues(source)['port'], 1445);
    },
  );

  test('WebDAV encryption and Chinese path produce a valid final URL', () {
    final source = buildSourceConfiguration(
      kind: 'webdav',
      encrypted: false,
      fields: {'host': 'nas.local', 'port': '8080', 'path': 'dav/动漫'},
    );
    final uri = Uri.parse(source['url']);
    expect(uri.scheme, 'http');
    expect(uri.port, 8080);
    expect(uri.pathSegments, ['dav', '动漫', '']);
    expect(sourceFormValues(source)['path'], '/dav/动漫/');
  });

  test(
    'invalid port, embedded credentials and mixed host path are rejected',
    () {
      for (final fields in [
        {'host': 'nas.local', 'port': '0', 'share': 'videos'},
        {'host': 'nas.local', 'port': '65536', 'share': 'videos'},
        {'host': 'http://nas.local', 'port': '445', 'share': 'videos'},
        {'host': 'nas.local/dav', 'port': '445', 'share': 'videos'},
        {'host': 'user:secret@nas.local', 'port': '445', 'share': 'videos'},
        {'host': 'nas.local', 'port': '445', 'share': 'videos/subdir'},
      ]) {
        expect(
          () => buildSourceConfiguration(kind: 'smb', fields: fields),
          throwsA(isA<AppFailure>()),
        );
      }
    },
  );
}
