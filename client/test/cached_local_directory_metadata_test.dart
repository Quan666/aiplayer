import 'dart:convert';

import 'package:aiplayer/data/directory_preview_context.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/local_directory_metadata.dart';
import 'package:aiplayer/data/media_identity.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

const _source = 'dav';
const _parent = '2026-10/归还者的魔法要特别 第二季';
const _file = '$_parent/归还者的魔法要特别 第二季 - E16 [ANi] [繁体].mp4';
const _other = '$_parent/归还者的魔法要特别 第二季 - E15 [ANi] [繁体].mp4';
final _context = directoryPreviewContext(
  source: const {'id': _source, 'kind': 'webdav', 'url': 'http://nas/share/'},
  strategy: 'conservative',
  aiContext: 'disabled',
);

void main() {
  test(
    'stored directory facts enrich only exact requested members without writes',
    () {
      final store = AppStore(':memory:');
      try {
        final raw = _persist(store);
        final changes = store.db.select('SELECT total_changes() n').single['n'];
        final donor = _decode(raw)!;
        final fields = donor.fieldsFor(path: _file, size: 123, modified: 456)!;
        expect(fields['bangumiId'], '12345');
        expect(fields['metadataTitle'], '归还者的魔法要特别 第二季');
        expect(fields['poster'], 'https://images.example/poster.jpg');
        expect(fields['series'], '归还者的魔法要特别');
        expect(fields['season'], '2');
        expect(fields['episode'], '16');
        expect(fields['episodeTitle'], '第十六集');
        expect(fields, isNot(contains('videos')));
        expect(fields, isNot(contains('identities')));
        expect(
          donor.fieldsFor(path: _other, size: 234, modified: 567)?['episode'],
          '15',
        );
        expect(store.all('media'), isEmpty);
        expect(
          store.db.select('SELECT total_changes() n').single['n'],
          changes,
        );
      } finally {
        store.dispose();
      }
    },
  );

  test(
    'cache identity, membership format and epoch changes reject a donor',
    () {
      final store = AppStore(':memory:');
      try {
        final raw = _persist(store);
        for (final patch in <Map<String, dynamic>>[
          {'sourceId': 'another-source'},
          {'membershipRevision': directoryPreviewMembershipRevision - 1},
          {'epoch': 1},
          {'sourceEpoch': 2},
          {'context': 'configuration-changed'},
          {'complete': false},
          {'collection': null},
        ]) {
          expect(_decode({...raw, ...patch}), isNull, reason: '$patch');
        }
        expect(_decode(raw, cacheEpoch: 3), isNull);
        expect(_decode(raw, sourceEpoch: 4), isNull);
        expect(_decode(raw, parentPath: 'another-folder'), isNull);
        expect(_decode(raw, parentPath: 'ignored/../$_parent'), isNull);
        final envelope = store.local(
          directoryPreviewStorageKey(
            _source,
            _parent,
          ).replaceFirst('directory-preview:', 'directory-preview-envelope:'),
        );
        expect(_decode(envelope), isNull);
      } finally {
        store.dispose();
      }
    },
  );

  test(
    'a cached path and identity plus unchanged size and modification are required',
    () {
      final store = AppStore(':memory:');
      try {
        final raw = _persist(store);
        final donor = _decode(raw)!;
        expect(donor.fieldsFor(path: _file, size: 124, modified: 456), isNull);
        expect(donor.fieldsFor(path: _file, size: 123, modified: 457), isNull);
        expect(donor.fieldsFor(path: _file, size: 0, modified: 0), isNull);
        expect(
          donor.fieldsFor(path: 'other/$_file', size: 123, modified: 456),
          isNull,
        );
        expect(
          donor.fieldsFor(path: 'ignored/../$_file', size: 123, modified: 456),
          isNull,
        );
        expect(
          donor.fieldsFor(
            path: '$_parent/unlisted.mp4',
            size: 123,
            modified: 456,
          ),
          isNull,
        );
        final missingIdentity = _copy(raw);
        (missingIdentity['collection']['identities'] as Map).remove(_file);
        expect(
          _decode(
            missingIdentity,
          )!.fieldsFor(path: _file, size: 123, modified: 456),
          isNull,
        );
      } finally {
        store.dispose();
      }
    },
  );

  test('ambiguous canonical paths and malformed subjects cannot donate', () {
    final store = AppStore(':memory:');
    try {
      final raw = _persist(store);
      final duplicate = _copy(raw);
      final collection = duplicate['collection'] as Map;
      (collection['videos'] as List).add({
        ...(collection['videos'] as List).first as Map,
        'path': './$_file',
      });
      (collection['identities'] as Map)['./$_file'] = ['Different', '1', '1'];
      expect(
        _decode(duplicate)!.fieldsFor(path: _file, size: 123, modified: 456),
        isNull,
      );
      for (final subject in [
        <String, dynamic>{'name': 'Missing identity'},
        <String, dynamic>{'id': 123, 'images': 'broken map'},
      ]) {
        final malformed = _copy(raw);
        malformed['collection']['subject'] = subject;
        expect(_decode(malformed), isNull);
      }
    } finally {
      store.dispose();
    }
  });

  test(
    'presentation fields are immutable and independent of the cache value',
    () {
      final store = AppStore(':memory:');
      try {
        final raw = _persist(store);
        final donor = _decode(raw)!;
        final fields = donor.fieldsFor(path: _file, size: 123, modified: 456)!;
        expect(() => fields['episode'] = '99', throwsUnsupportedError);
        expect(
          () => (fields['genres'] as List).clear(),
          throwsUnsupportedError,
        );
        raw['collection']['subject']['images']['large'] = 'changed';
        raw['collection']['subject']['genres'].clear();
        raw['collection']['episodeTitles']['16'] = 'changed';
        final reread = donor.fieldsFor(path: _file, size: 123, modified: 456)!;
        expect(reread['poster'], 'https://images.example/poster.jpg');
        expect(reread['genres'], ['动画']);
        expect(reread['episodeTitle'], '第十六集');
      } finally {
        store.dispose();
      }
    },
  );
}

CachedLocalDirectoryMetadata? _decode(
  Object? raw, {
  String parentPath = _parent,
  int cacheEpoch = 2,
  int sourceEpoch = 3,
}) => CachedLocalDirectoryMetadata.decode(
  raw,
  sourceId: _source,
  parentPath: parentPath,
  cacheEpoch: cacheEpoch,
  sourceEpoch: sourceEpoch,
  context: _context,
);

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

Map<String, dynamic> _persist(AppStore store) {
  store.setLocal('directoryPreviewEpoch', 2);
  store.setLocal('directoryPreviewSourceEpoch:$_source', 3);
  persistDirectoryPreview(
    store,
    _source,
    _parent,
    DirectoryPreview(
      collection: const DirectoryCollection(
        title: '归还者的魔法要特别',
        season: '2',
        videos: [
          SourceEntry(name: 'E16.mp4', path: _file, size: 123, modified: 456),
          SourceEntry(name: 'E15.mp4', path: _other, size: 234, modified: 567),
        ],
        identities: {
          _file: ReleaseName('归还者的魔法要特别', '2', '16'),
          _other: ReleaseName('归还者的魔法要特别', '2', '15'),
        },
        subject: {
          'id': 12345,
          'name': '归还者的魔法要特别 第二季',
          'images': {'large': 'https://images.example/poster.jpg'},
          'genres': ['动画'],
        },
        episodeTitles: {'16': '第十六集'},
      ),
      context: _context,
      fingerprint: 'stored-listing',
      updatedAt: 100,
      modified: 200,
      cacheEpoch: 2,
      sourceEpoch: 3,
    ),
  );
  return _copy(
    store.local(directoryPreviewStorageKey(_source, _parent))
        as Map<String, dynamic>,
  );
}
