import 'dart:convert';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/sync_profile.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = 'secret:api-key-entry';
const _token = 'fixture-sync-token-do-not-log';
const _apiKey = 'fixture-api-key-do-not-log';
const _password = 'fixture-password-do-not-log';
const _provider = 'https://fixture-private-provider.invalid/v1';
const _limit = 180 * 1024;
const _payload = {
  'type': 'secret',
  'key': 'aiSubtitleToken',
  'value': _apiKey,
  'provider': _provider,
  'source': {
    'password': _password,
    'folders': ['番剧', '第 1 季'],
    'enabled': true,
    'port': 443,
    'optional': null,
  },
};

SyncRecord _record(Map<String, dynamic> data, {String id = _id}) =>
    SyncRecord(kind: 'vault', id: id, data: data);

String _corrupt(String encoded) {
  final bytes = base64Decode(encoded);
  bytes[bytes.length ~/ 2] ^= 1;
  return base64Encode(bytes);
}

Future<Map<String, dynamic>> _encryptRaw(
  SecretKey key,
  List<int> plaintext, {
  String id = _id,
}) async {
  final box = await AesGcm.with256bits().encrypt(
    plaintext,
    secretKey: key,
    aad: utf8.encode('aiplayer:vault:1:$id'),
  );
  return {
    'algorithm': 'AES-GCM-256',
    'nonce': base64Encode(box.nonce),
    'ciphertext': base64Encode(box.cipherText),
    'mac': base64Encode(box.mac.bytes),
  };
}

Matcher get _safeFailure => isA<AppFailure>().having(
  (error) => error.toString(),
  'redacted error',
  allOf([
    isNot(contains(_token)),
    isNot(contains(_apiKey)),
    isNot(contains(_password)),
    isNot(contains(_provider)),
    isNot(contains('JsonUnsupportedObjectError')),
    isNot(contains('SecretBoxAuthenticationError')),
  ]),
);

class _UnsupportedSecret {
  @override
  String toString() => _apiKey;
}

void main() {
  late SecretKey key;
  late SyncVault vault;

  setUp(() async {
    key = await SyncVault.derive(_token);
    vault = SyncVault(key);
  });

  test(
    'token derivation is deterministic, 256-bit and isolated by token',
    () async {
      final again = await SyncVault.derive(_token);
      final another = await SyncVault.derive('different-fixture-token');
      expect(await key.extractBytes(), hasLength(32));
      expect(await again.extractBytes(), await key.extractBytes());
      expect(await another.extractBytes(), isNot(await key.extractBytes()));
      final data = await vault.seal(_id, _payload);
      await expectLater(
        SyncVault(another).open(_record(data)),
        throwsA(_safeFailure),
      );
    },
  );

  test(
    'nested Unicode settings roundtrip without cleartext credentials',
    () async {
      final data = await vault.seal(_id, _payload);
      expect(data.keys.toSet(), {'algorithm', 'nonce', 'ciphertext', 'mac'});
      expect(data['algorithm'], 'AES-GCM-256');
      expect(base64Decode(data['nonce'] as String), hasLength(12));
      expect(base64Decode(data['mac'] as String), hasLength(16));
      final serialized = jsonEncode(data);
      for (final secret in [_token, _apiKey, _password, _provider]) {
        expect(serialized, isNot(contains(secret)));
      }
      // Simulate serialization/storage and a separately constructed recipient.
      final received = Map<String, dynamic>.from(jsonDecode(serialized));
      expect(
        await SyncVault(await SyncVault.derive(_token)).open(_record(received)),
        _payload,
      );
    },
  );

  test('repeated sealing creates independent nonces and ciphertext', () async {
    final nonces = <String>{};
    final ciphertexts = <String>{};
    for (var i = 0; i < 8; i++) {
      final sealed = await vault.seal(_id, _payload);
      nonces.add(sealed['nonce'] as String);
      ciphertexts.add(sealed['ciphertext'] as String);
      expect(await vault.open(_record(sealed)), _payload);
    }
    expect(nonces, hasLength(8));
    expect(ciphertexts, hasLength(8));
  });

  test(
    'the authenticated record ID prevents moving ciphertext to another item',
    () async {
      final data = await vault.seal(_id, _payload);
      await expectLater(
        vault.open(_record(data, id: 'secret:another-api-key-entry')),
        throwsA(_safeFailure),
      );
      expect(await vault.open(_record(data)), _payload);
    },
  );

  for (final field in ['ciphertext', 'mac', 'nonce']) {
    test('a one-bit change in $field is rejected', () async {
      final data = await vault.seal(_id, _payload);
      final altered = {...data, field: _corrupt(data[field] as String)};
      await expectLater(vault.open(_record(altered)), throwsA(_safeFailure));
    });
  }

  test(
    'rotation can read previous keys and only seals with the current key',
    () async {
      final next = await SyncVault.derive('rotated-fixture-token');
      final unrelated = await SyncVault.derive('unrelated-fixture-token');
      final oldData = await vault.seal(_id, _payload);
      final rotated = SyncVault(next, [unrelated, key]);
      expect(await rotated.open(_record(oldData)), _payload);
      final newData = await rotated.seal(_id, _payload);
      expect(await SyncVault(next).open(_record(newData)), _payload);
      await expectLater(vault.open(_record(newData)), throwsA(_safeFailure));
      await expectLater(
        SyncVault(next, [unrelated]).open(_record(oldData)),
        throwsA(_safeFailure),
      );
    },
  );

  test('the 180 KiB limit allows its exact JSON byte boundary', () async {
    final overhead = utf8.encode(jsonEncode({'value': ''})).length;
    final boundary = {'value': 'x' * (_limit - overhead)};
    expect(utf8.encode(jsonEncode(boundary)), hasLength(_limit));
    final data = await vault.seal(_id, boundary);
    expect(await vault.open(_record(data)), boundary);
    final oversized = {'value': '${boundary['value']}x'};
    await expectLater(vault.seal(_id, oversized), throwsA(_safeFailure));
    final validButOversized = await _encryptRaw(
      key,
      utf8.encode(jsonEncode(oversized)),
    );
    await expectLater(
      vault.open(_record(validButOversized)),
      throwsA(_safeFailure),
    );
  });

  test('size validation counts UTF-8 bytes rather than code units', () async {
    final data = {'value': '密' * (_limit ~/ 3)};
    final json = jsonEncode(data);
    expect(json.length, lessThan(_limit));
    expect(utf8.encode(json).length, greaterThan(_limit));
    await expectLater(vault.seal(_id, data), throwsA(_safeFailure));
  });

  test(
    'malformed envelopes never expose credentials or decoder exceptions',
    () async {
      final data = await vault.seal(_id, _payload);
      final malformed = <Map<String, dynamic>>[
        {...data, 'algorithm': _apiKey},
        {...data, 'unexpected': _password},
        {...data}..remove('nonce'),
        {...data, 'ciphertext': _provider},
        {...data, 'ciphertext': _payload},
        {...data, 'ciphertext': ''},
        {...data, 'nonce': base64Encode(List.filled(11, 0))},
        {...data, 'mac': base64Encode(List.filled(15, 0))},
        await _encryptRaw(key, utf8.encode('invalid JSON $_apiKey $_provider')),
        await _encryptRaw(key, utf8.encode(jsonEncode([_apiKey, _password]))),
        await _encryptRaw(key, [0xff, 0xfe, ...utf8.encode(_password)]),
      ];
      for (final entry in malformed) {
        await expectLater(vault.open(_record(entry)), throwsA(_safeFailure));
      }
    },
  );

  test(
    'invalid outbound configuration reports a redacted application error',
    () async {
      await expectLater(
        vault.seal(_id, {'value': _UnsupportedSecret()}),
        throwsA(_safeFailure),
      );
    },
  );

  test(
    'deleted records need no ciphertext and do not restore any secret',
    () async {
      final deleted = SyncRecord(
        kind: 'vault',
        id: _id,
        data: _payload,
        deleted: true,
      );
      expect(await vault.open(deleted), isEmpty);
    },
  );
}
