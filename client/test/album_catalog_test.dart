import 'package:aiplayer/data/album_catalog.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

SourceEntry photo(
  String name, {
  String parent = '/trip',
  int size = 100,
  int modified = 1700000000000,
  bool hidden = false,
}) => SourceEntry(
  name: name,
  path: '$parent/$name',
  size: size,
  modified: modified,
  hidden: hidden,
);

AlbumIndex index(
  List<SourceEntry> entries, {
  Map<String, AlbumFileMetadata> metadata = const {},
  bool caseSensitive = true,
  String sourceId = 'nas',
}) => AlbumIndex(
  entries,
  sourceId: sourceId,
  directory: '/trip',
  metadata: metadata,
  caseSensitive: caseSensitive,
);

void main() {
  group('explicit file types and worker-prepared navigation', () {
    final entries = [
      const SourceEntry(name: 'folder', path: '/trip/folder', directory: true),
      photo('001.jpg'),
      photo('001.jpeg'),
      photo('001.arw'),
      photo('001.xmp'),
      photo('002.txt'),
      photo('003.mp4'),
      photo('004.flac'),
      photo('README'),
      photo('trailing.'),
      photo('.hidden.gif'),
    ];

    test(
      'folder and extensionless selections are distinct exact file types',
      () {
        final data = index(entries);
        final folders = data.filter(AlbumOptions(types: const {'folder'}));
        expect(folders.items.single.isDirectory, isTrue);
        expect(folders.matchedFileCount, 0);
        expect(folders.audioEntries, isEmpty);
        expect(folders.previousMediaIndex, isEmpty);
        expect(folders.nextMediaIndex, isEmpty);
        final noExtension = data.filter(AlbumOptions(types: const {'file'}));
        expect(noExtension.items.map((item) => item.preferred.name), [
          'README',
          'trailing.',
        ]);
        expect(
          noExtension.items.every((item) => item.kind == MediaKind.other),
          isTrue,
        );
        expect(noExtension.matchedFileCount, 2);
      },
    );

    test(
      'JPG differs from JPEG, matching original members keep group identity',
      () {
        final data = index(entries);
        final original = data
            .filter(AlbumOptions())
            .items
            .singleWhere((item) => item.isPhoto);
        final jpg = data.filter(AlbumOptions(types: const {'JPG'}));
        expect(jpg.items.single.members.map((entry) => entry.name), [
          '001.jpg',
        ]);
        expect(jpg.items.single.allMembers, hasLength(3));
        expect(jpg.items.single.id, original.id);
        final jpeg = data.filter(AlbumOptions(types: const {'.JPEG'}));
        expect(jpeg.items.single.members.map((entry) => entry.name), [
          '001.jpeg',
        ]);
        expect(jpeg.items.single.id, original.id);
        final both = data.filter(AlbumOptions(types: const {'.jpg', '.jpeg'}));
        expect(both.matchedFileCount, 2);
        expect(both.items.single.preferred.name, '001.jpg');
        expect(both.items.single.members.map((entry) => entry.name), [
          '001.jpg',
          '001.jpeg',
        ]);
      },
    );

    test('generic files, sidecars and audio require selection or All', () {
      final data = index(entries);
      final defaults = data.filter(AlbumOptions());
      expect(defaults.items.map((item) => item.kind), [
        MediaKind.folder,
        MediaKind.image,
        MediaKind.video,
      ]);
      final selected = data.filter(
        AlbumOptions(types: const {'.txt', '.xmp', '.flac'}),
      );
      expect(selected.items.map((item) => item.preferred.name), [
        '001.xmp',
        '002.txt',
        '004.flac',
      ]);
      expect(selected.items.first.kind, MediaKind.sidecar);
      expect(selected.items[1].kind, MediaKind.other);
      expect(selected.items.first.isGroup, isFalse);
      expect(selected.audioEntries.single.name, '004.flac');
      final all = data.filter(AlbumOptions(types: const {'*'}));
      expect(all.items, hasLength(8));
      expect(all.matchedFileCount, 9);
      expect(
        all.items.where((item) => item.isPhoto).single.members,
        hasLength(3),
      );
      expect(
        all.items.any((item) => item.preferred.name == '.hidden.gif'),
        isFalse,
      );
    });

    test('available types remain complete when selected types and other predicates exclude them', () {
      final snapshot = index(entries).filter(
        AlbumOptions(
          types: const {'.jpg'},
          query: 'nothing-matches',
          kinds: const {MediaKind.image},
          includeExtensions: const {'.jpg', '.jpeg'},
          excludeExtensions: const {'.jpeg', '.txt', '.xmp', '.flac'},
          showDirectories: false,
        ),
      );
      expect(snapshot.items, isEmpty);
      expect(snapshot.availableTypes, [
        'folder',
        '.arw',
        '.flac',
        '.jpeg',
        '.jpg',
        '.mp4',
        '.txt',
        '.xmp',
        'file',
      ]);
      expect(snapshot.defaultTypes, {'.jpg'});
      final hidden = index(entries)
          .filter(AlbumOptions(hideHiddenFiles: false));
      expect(hidden.availableTypes, contains('.gif'));
      expect(() => snapshot.availableTypes.clear(), throwsUnsupportedError);
      expect(() => snapshot.defaultTypes.add('.png'), throwsUnsupportedError);
    });

    test(
      'legacy kind and suffix exclusions still combine with explicit types',
      () {
        final data = index(entries);
        final excluded = data.filter(
          AlbumOptions(
            types: const {'*'},
            kinds: const {MediaKind.image},
            includeExtensions: const {'.jpg', '.jpeg'},
            excludeExtensions: const {'.jpg'},
            showDirectories: false,
          ),
        );
        expect(excluded.items.single.preferred.name, '001.jpeg');
        expect(excluded.defaultTypes, {'.jpeg'});
        expect(
          data
              .filter(
                AlbumOptions(
                  types: const {'.jpg'},
                  kinds: const {MediaKind.raw},
                ),
              )
              .items,
          isEmpty,
        );
      },
    );

    test('neighbor maps skip all generic files, folders and sidecars in either sort direction', () {
      final data = index(entries);
      for (final descending in [false, true]) {
        final snapshot = data.filter(
          AlbumOptions(types: const {'*'}, descending: descending),
        );
        final media = [
          for (var i = 0; i < snapshot.items.length; i++)
            if (snapshot.items[i].isPhoto ||
                snapshot.items[i].isVideo ||
                snapshot.items[i].isAudio)
              i,
        ];
        expect(media, hasLength(3));
        expect(snapshot.previousMediaIndex, {
          media[1]: media[0],
          media[2]: media[1],
        });
        expect(snapshot.nextMediaIndex, {
          media[0]: media[1],
          media[1]: media[2],
        });
        expect(snapshot.previousMediaIndex[media.first], isNull);
        expect(snapshot.nextMediaIndex[media.last], isNull);
        expect(
          () => snapshot.previousMediaIndex.clear(),
          throwsUnsupportedError,
        );
        expect(() => snapshot.nextMediaIndex.clear(), throwsUnsupportedError);
      }
    });

    test('capture filters do not turn modified times or missing generic metadata into photo facts', () {
      final data = index([
        photo('image.jpg', modified: 10000),
        photo('notes.txt', modified: 10000),
      ]);
      final visible = data.filter(AlbumOptions(types: const {'*'}));
      expect(visible.items.every((item) => item.capturedAt == null), isTrue);
      final captured = data.filter(
        AlbumOptions(types: const {'*'}, dateField: 'captured', dateFrom: 1),
      );
      expect(captured.items, isEmpty);
      expect(captured.pendingMetadataCount, 1);
      expect(captured.unavailableMetadataCount, 1);
      expect(captured.metadataEntries.map((entry) => entry.name), [
        'image.jpg',
      ]);
      final modified = data.filter(
        AlbumOptions(types: const {'*'}, dateField: 'modified', dateFrom: 1),
      );
      expect(modified.matchedFileCount, 2);
      expect(modified.items.every((item) => item.capturedAt == null), isTrue);
    });

    test('type tokens round trip independently from old suffix filters', () {
      final original = AlbumOptions(
        types: const {' FOLDER ', 'FILE', ' JPG ', '.JPEG'},
      );
      expect(original.types, {'folder', 'file', '.jpg', '.jpeg'});
      final saved = AlbumOptions.fromJson(original.toJson());
      expect(saved.types, original.types);
      expect(saved.includeExtensions, isEmpty);
      expect(saved.copyWith(types: const {'*'}).types, {'*'});
      expect(saved.copyWith(types: const {}).types, isEmpty);
      expect(AlbumOptions.fromJson(const {}).types, isEmpty);
      expect(() => saved.types.add('.raw'), throwsUnsupportedError);
    });
  });

  test('one photo has many formats; videos and sidecars remain distinct', () {
    final listing = [
      for (final extension in ['jpg', 'jpeg', 'ARW', 'dng', 'tif'])
        photo('001.$extension'),
      photo('001.mov'),
      photo('001.xmp'),
      photo('001.edited.jpg'),
      photo('002.arw'),
      photo('001.jpg', parent: '/other'),
    ];
    final snapshot = index(listing).filter(AlbumOptions());
    expect(snapshot.items, hasLength(5));
    final group = snapshot.items.singleWhere(
      (item) => item.members.length == 5,
    );
    expect(group.preferred.name, '001.jpg');
    expect(group.allMembers, hasLength(5));
    expect(group.kind, MediaKind.image);
    expect(group.isGroup, isTrue);
    expect(snapshot.items.where((item) => item.isVideo), hasLength(1));
    expect(snapshot.matchedFileCount, 9);
    expect(snapshot.availableExtensions, containsAll(['.jpg', '.arw', '.mov']));
    expect(snapshot.availableExtensions, isNot(contains('.xmp')));
    expect(snapshot.indexById[group.id], snapshot.items.indexOf(group));
    expect(() => group.members.clear(), throwsUnsupportedError);
    expect(() => group.allMembers.clear(), throwsUnsupportedError);
    expect(() => snapshot.items.clear(), throwsUnsupportedError);
    expect(() => snapshot.indexById.clear(), throwsUnsupportedError);
  });

  test('exact suffix filters members before grouping with stable identity', () {
    final data = index(
      [photo('001.jpg'), photo('001.jpeg'), photo('001.arw'), photo('002.arw')],
      metadata: {
        '/trip/001.jpg': const AlbumFileMetadata(capturedAt: 100),
        '/trip/001.arw': const AlbumFileMetadata(capturedAt: 200),
      },
    );
    final all = data
        .filter(AlbumOptions())
        .items
        .singleWhere((item) => item.name == '001');
    final jpg = data.filter(AlbumOptions(includeExtensions: ['JPG']));
    expect(jpg.items, hasLength(1));
    expect(jpg.items.single.id, all.id);
    expect(jpg.items.single.members.map((e) => e.name), ['001.jpg']);
    expect(jpg.items.single.allMembers, hasLength(3));
    expect(jpg.items.single.preferred.name, '001.jpg');
    expect(jpg.matchedFileCount, 1);
    final raw = data.filter(AlbumOptions(includeExtensions: ['.ARW']));
    final rawGroup = raw.items.singleWhere((item) => item.id == all.id);
    expect(rawGroup.preferred.name, '001.arw');
    expect(rawGroup.capturedAt, all.capturedAt);
    final excluded = data.filter(
      AlbumOptions(
        includeExtensions: ['.jpg', '.arw'],
        excludeExtensions: ['jpg'],
      ),
    );
    expect(
      excluded.items.map((item) => item.preferred.name),
      unorderedEquals(['001.arw', '002.arw']),
    );
  });

  test('all file predicates must match the same group member', () {
    final data = index([
      photo('001.jpg', size: 50),
      photo('001.arw', size: 5000),
      photo('002.jpg', size: 5000),
    ]);
    final result = data.filter(
      AlbumOptions(includeExtensions: ['jpg'], minSize: 1000, query: '001'),
    );
    expect(result.items, isEmpty);
    final matching = data.filter(
      AlbumOptions(includeExtensions: ['jpg'], minSize: 1000),
    );
    expect(matching.items.single.preferred.name, '002.jpg');
  });

  test('case-sensitive stems, edited names and parent/source identity', () {
    final listing = [photo('A.JPG'), photo('a.arw'), photo('A.edit.jpg')];
    final sensitive = index(listing).filter(AlbumOptions());
    expect(sensitive.items, hasLength(3));
    final insensitive = index(
      listing,
      caseSensitive: false,
    ).filter(AlbumOptions());
    expect(insensitive.items, hasLength(2));
    expect(
      insensitive.items.singleWhere((item) => item.isGroup).members,
      hasLength(2),
    );
    expect(
      index([
        photo('A.JPG'),
      ], sourceId: 'one').filter(AlbumOptions()).items.single.id,
      isNot(
        index([
          photo('A.JPG'),
        ], sourceId: 'two').filter(AlbumOptions()).items.single.id,
      ),
    );
  });

  test(
    'unfold exposes every matching file once and keeps videos independent',
    () {
      final data = index([
        photo('001.jpg'), photo('001.jpeg'), photo('001.arw'), photo('001.mp4'),
        photo('001.jpg'), // duplicate source entry
      ]);
      final result = data.filter(
        AlbumOptions(groupPhotos: false, excludeExtensions: ['jpeg']),
      );
      expect(result.items, hasLength(3));
      expect(result.items.every((item) => item.members.length == 1), isTrue);
      expect(result.items.map((item) => item.id).toSet(), hasLength(3));
      expect(result.matchedFileCount, 3);
    },
  );

  test(
    'folders survive suffix filters; hidden files and audio are explicit',
    () {
      final data = index([
        const SourceEntry(
          name: 'folder',
          path: '/trip/folder',
          directory: true,
        ),
        const SourceEntry(
          name: '@eaDir',
          path: '/trip/@eaDir',
          directory: true,
        ),
        photo('.private.jpg'),
        photo('002.jpg', hidden: true),
        photo('001.jpg'),
        photo('song.flac'),
      ]);
      final result = data.filter(AlbumOptions(includeExtensions: ['arw']));
      expect(result.items.single.isDirectory, isTrue);
      expect(data.filter(AlbumOptions()).matchedFileCount, 1);
      expect(
        data
            .filter(AlbumOptions(hideHiddenFiles: false, includeAudio: true))
            .matchedFileCount,
        4,
      );
      final music = data.filter(
        AlbumOptions(kinds: [MediaKind.audio], showDirectories: false),
      );
      expect(music.items.single.isAudio, isTrue);
    },
  );

  test(
    'metadata filtering distinguishes unknown from zero and ignores mismatches',
    () {
      final data = index(
        [
          photo('a.jpg'),
          photo('b.jpg'),
          photo('c.jpg'),
          photo('movie.mp4'),
          photo('unknown.mp4'),
        ],
        metadata: {
          '/trip/a.jpg': const AlbumFileMetadata(
            capturedAt: 1000,
            width: 4000,
            height: 3000,
          ),
          '/trip/b.jpg': const AlbumFileMetadata(
            capturedAt: 2000,
            width: 2000,
            height: 3000,
          ),
          '/trip/movie.mp4': const AlbumFileMetadata(
            durationMilliseconds: 30000,
          ),
        },
      );
      final dimensions = data.filter(
        AlbumOptions(orientation: 'landscape', minWidth: 3000),
      );
      expect(dimensions.items.single.preferred.name, 'a.jpg');
      expect(dimensions.pendingMetadataCount, 1);
      final date = data.filter(
        AlbumOptions(
          dateField: 'captured',
          dateFrom: 1500,
          kinds: [MediaKind.image],
        ),
      );
      expect(date.items.single.preferred.name, 'b.jpg');
      expect(date.pendingMetadataCount, 1);
      final duration = data.filter(
        AlbumOptions(minDurationMilliseconds: 10000),
      );
      expect(duration.items.single.preferred.name, 'movie.mp4');
      expect(duration.pendingMetadataCount, 0);
      expect(duration.unavailableMetadataCount, 1);
      final none = data.filter(
        AlbumOptions(includeExtensions: ['arw'], minWidth: 100),
      );
      expect(none.pendingMetadataCount, 0);
    },
  );

  test('read photos without capture dates are known unknown, not pending', () {
    final data = index(
      [photo('read.jpg'), photo('unread.jpg')],
      metadata: {
        '/trip/read.jpg': const AlbumFileMetadata(width: 40, height: 30),
      },
    );
    final dated = data.filter(AlbumOptions(dateField: 'captured', dateFrom: 1));
    expect(dated.items, isEmpty);
    expect(dated.pendingMetadataCount, 1);
    expect(dated.metadataEntries.map((entry) => entry.name), ['unread.jpg']);
    final unknown = data.filter(
      AlbumOptions(dateField: 'captured', unknownDatesOnly: true),
    );
    expect(unknown.items.single.preferred.name, 'read.jpg');
    expect(unknown.pendingMetadataCount, 1);
    expect(unknown.unavailableMetadataCount, 0);
  });

  test(
    'audio and video capture metadata is unavailable instead of retryable',
    () {
      final result =
          index([photo('photo.jpg'), photo('clip.mp4'), photo('song.flac')])
              .filter(
                AlbumOptions(
                  dateField: 'captured',
                  dateFrom: 1,
                  includeAudio: true,
                ),
              );
      expect(result.items, isEmpty);
      expect(result.pendingMetadataCount, 1);
      expect(result.unavailableMetadataCount, 2);
      expect(result.metadataEntries.map((entry) => entry.name), ['photo.jpg']);
      final excluded = index([photo('clip.mp4')]).filter(
        AlbumOptions(
          dateField: 'captured',
          dateFrom: 1,
          includeExtensions: ['.jpg'],
        ),
      );
      expect(excluded.pendingMetadataCount, 0);
      expect(excluded.unavailableMetadataCount, 0);
    },
  );

  test(
    'date dividers follow chronological sort and its selected date field',
    () {
      final capture = DateTime(2026, 11, 4), modified = DateTime(2025, 3, 2);
      final data = index(
        [photo('a.jpg', modified: modified.millisecondsSinceEpoch)],
        metadata: {
          '/trip/a.jpg': AlbumFileMetadata(
            capturedAt: capture.millisecondsSinceEpoch,
          ),
        },
      );
      expect(
        data
            .filter(AlbumOptions(sortField: 'captured'))
            .wallSections
            .sections
            .single
            .day,
        DateTime(2026, 11, 4),
      );
      expect(
        data
            .filter(AlbumOptions(sortField: 'modified'))
            .wallSections
            .sections
            .single
            .day,
        DateTime(2025, 3, 2),
      );
      for (final sort in ['name', 'size', 'type']) {
        expect(
          data.filter(AlbumOptions(sortField: sort)).wallSections.headerCount,
          0,
        );
      }
    },
  );

  test(
    'sorting is natural and files without any timeline date remain last',
    () {
      final data = index(
        [
          photo('photo10.jpg'),
          photo('photo2.jpg'),
          photo('photo1.jpg', modified: 0),
        ],
        metadata: {
          '/trip/photo10.jpg': const AlbumFileMetadata(capturedAt: 100),
          '/trip/photo2.jpg': const AlbumFileMetadata(capturedAt: 200),
        },
      );
      expect(
        data
            .filter(AlbumOptions(sortField: 'name', descending: false))
            .items
            .map((item) => item.name),
        ['photo1', 'photo2', 'photo10'],
      );
      expect(AlbumOptions.fromJson(null).sortField, 'name');
      expect(AlbumOptions.fromJson(null).descending, isFalse);
      expect(data.filter(AlbumOptions()).items.map((item) => item.name), [
        'photo1',
        'photo2',
        'photo10',
      ]);
      expect(
        data
            .filter(AlbumOptions(sortField: 'captured', descending: true))
            .items
            .map((item) => item.name),
        ['photo2', 'photo10', 'photo1'],
      );
    },
  );

  test('photos and videos share each ascending and descending sort', () {
    final day = DateTime(2026, 11, 4);
    final entries = [
      const SourceEntry(name: 'folder', path: '/trip/folder', directory: true),
      for (var i = 1; i <= 4; i++)
        photo(
          'shot$i.${i.isOdd ? 'jpg' : 'mp4'}',
          modified: day.add(Duration(minutes: i)).millisecondsSinceEpoch,
          size: i * 100,
        ),
    ];
    final data = index(
      entries,
      metadata: {
        for (final entry in entries.where(
          (entry) => entry.name.endsWith('.jpg'),
        ))
          entry.path: AlbumFileMetadata(capturedAt: entry.modified),
      },
    );
    for (final field in ['name', 'modified', 'captured', 'size']) {
      for (final descending in [false, true]) {
        final snapshot = data.filter(
          AlbumOptions(sortField: field, descending: descending),
        );
        final sequence = descending ? [4, 3, 2, 1] : [1, 2, 3, 4];
        expect(snapshot.items.first.isDirectory, isTrue);
        expect(snapshot.items.skip(1).map((item) => item.preferred.name), [
          for (final i in sequence) 'shot$i.${i.isOdd ? 'jpg' : 'mp4'}',
        ], reason: '$field descending=$descending must interleave media');
        expect(
          snapshot.items
              .where((item) => item.isVideo)
              .every((item) => item.capturedAt == null),
          isTrue,
        );
      }
    }
  });

  test('capture timeline date runs include intervening videos using source dates', () {
    final first = DateTime(2026, 11, 4), second = DateTime(2026, 11, 5);
    final entries = [
      photo('a.jpg', modified: first.millisecondsSinceEpoch),
      photo(
        'b.mp4',
        modified: first.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
      ),
      photo('c.jpg', modified: second.millisecondsSinceEpoch),
      photo(
        'd.mov',
        modified: second.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
      ),
    ];
    final data = index(
      entries,
      metadata: {
        entries[0].path: AlbumFileMetadata(capturedAt: entries[0].modified),
        entries[2].path: AlbumFileMetadata(capturedAt: entries[2].modified),
      },
    );
    final snapshot = data.filter(
      AlbumOptions(sortField: 'captured', descending: false),
    );
    expect(snapshot.items.map((item) => item.preferred.name), [
      'a.jpg',
      'b.mp4',
      'c.jpg',
      'd.mov',
    ]);
    expect(snapshot.wallSections.headerCount, 2);
    expect(snapshot.wallSections.sections.map((section) => section.day), [
      first,
      second,
    ]);
    for (final section in snapshot.wallSections.sections) {
      expect(
        snapshot.items
            .sublist(section.itemStart, section.itemEnd)
            .map((item) => item.kind),
        [MediaKind.image, MediaKind.video],
      );
    }
    final capturedFilter = data.filter(
      AlbumOptions(dateFrom: first.millisecondsSinceEpoch),
    );
    expect(
      capturedFilter.items.every((item) => item.isPhoto),
      isTrue,
      reason:
          'Source modification time must never masquerade as captured metadata',
    );
    expect(capturedFilter.unavailableMetadataCount, 2);
  });

  test(
    'frozen chronology retains order and date runs while real facts update',
    () {
      final first = DateTime(2026, 11, 4),
          second = DateTime(2026, 11, 5),
          third = DateTime(2026, 11, 6);
      final entries = [
        photo('a.jpg', modified: first.millisecondsSinceEpoch),
        photo('b.mp4', modified: second.millisecondsSinceEpoch),
        photo('z.jpg', modified: 0),
      ];
      final options = AlbumOptions(sortField: 'captured', descending: false);
      final initial = index(entries).filter(options);
      final updatedIndex = index(
        entries,
        metadata: {
          entries[0].path: AlbumFileMetadata(
            capturedAt: third.millisecondsSinceEpoch,
          ),
          entries[1].path: AlbumFileMetadata(
            capturedAt: second.millisecondsSinceEpoch,
          ),
          entries[2].path: AlbumFileMetadata(
            capturedAt: first
                .subtract(const Duration(days: 1))
                .millisecondsSinceEpoch,
          ),
        },
      );
      final stable = updatedIndex.filter(
        options,
        timelineById: initial.timelineById,
      );
      expect(
        stable.items.map((item) => item.id),
        initial.items.map((item) => item.id),
      );
      expect(
        stable.wallSections.sections.map((section) => section.day),
        initial.wallSections.sections.map((section) => section.day),
      );
      expect(stable.timelineById, initial.timelineById);
      expect(stable.items.first.capturedAt, third.millisecondsSinceEpoch);
      expect(
        stable.items.last.capturedAt,
        first.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
      );
      expect(
        stable.timelineById[stable.items.last.id],
        isNull,
        reason: 'A frozen unknown date must not turn into a new date section',
      );
      expect(() => stable.timelineById.clear(), throwsUnsupportedError);
      final refreshed = updatedIndex.filter(options);
      expect(refreshed.items.map((item) => item.preferred.name), [
        'z.jpg',
        'b.mp4',
        'a.jpg',
      ]);
      expect(refreshed.timelineById, isNot(initial.timelineById));
    },
  );

  test(
    'default view is natural name ascending and saved choices are preserved',
    () {
      final data = index([
        photo('photo10.jpg', modified: 100),
        photo('photo2.mp4', modified: 300),
        photo('photo1.jpg', modified: 200),
      ]);
      for (final options in [
        AlbumOptions(),
        AlbumOptions.fromJson(null),
        AlbumOptions.fromJson(const {}),
        AlbumOptions.fromJson({'sortField': 'name'}),
        AlbumOptions.fromJson({'sortField': 'bad'}),
      ]) {
        expect(options.sortField, 'name');
        expect(options.descending, isFalse);
        final snapshot = data.filter(options);
        expect(snapshot.items.map((item) => item.preferred.name), [
          'photo1.jpg',
          'photo2.mp4',
          'photo10.jpg',
        ]);
        expect(snapshot.wallSections.headerCount, 0);
      }
      for (final field in ['name', 'modified', 'captured', 'size', 'type']) {
        for (final descending in [false, true]) {
          final restored = AlbumOptions.fromJson({
            'sortField': field,
            'descending': descending,
          });
          expect(restored.sortField, field);
          expect(restored.descending, descending);
        }
        expect(
          AlbumOptions.fromJson({'sortField': field}).descending,
          field != 'name',
        );
      }
    },
  );

  test(
    'saved options normalize suffixes, protect collections, clear bounds',
    () {
      final original = AlbumOptions(
        kinds: [MediaKind.image, MediaKind.raw],
        includeExtensions: ['JPG', '.ARW'],
        excludeExtensions: ['jpeg'],
        minSize: 20,
        dateFrom: 100,
        groupPhotos: false,
      );
      final loaded = AlbumOptions.fromJson(original.toJson());
      expect(loaded.toJson(), original.toJson());
      expect(loaded.copyWith(minSize: null, dateFrom: null).minSize, isNull);
      expect(loaded.copyWith(query: 'new').minSize, 20);
      expect(
        () => loaded.includeExtensions.add('.png'),
        throwsUnsupportedError,
      );
      expect(
        AlbumOptions.fromJson({'sortField': 'bad', 'minSize': 'bad'}).sortField,
        'name',
      );
      expect(mediaExtension('/photo.dir/001.JPG'), '.jpg');
      expect(mediaExtension('.hidden'), '');
      expect(isImageFile('001.NEF'), isTrue);
      expect(mediaKindOf('001.XMP'), MediaKind.sidecar);
    },
  );
}
