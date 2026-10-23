import 'package:aiplayer/sources/directory_sort.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'hidden files, folders, server attributes and system entries are hidden by default',
    () {
      const entries = [
        SourceEntry(name: '.private', path: 'dot', directory: true),
        SourceEntry(name: 'private.mkv', path: 'attribute', hidden: true),
        SourceEntry(name: '@eaDir', path: 'nas', directory: true),
        SourceEntry(
          name: 'System Volume Information',
          path: 'system',
          directory: true,
        ),
        SourceEntry(name: 'Thumbs.db', path: 'thumbs'),
        SourceEntry(name: 'Episode.mkv', path: 'video'),
        SourceEntry(name: '字幕.ass', path: 'subtitle'),
      ];
      expect(const DirectorySort().apply(entries).map((entry) => entry.path), [
        'video',
      ]);
      expect(
        const DirectorySort().apply(entries, hideHiddenFiles: false),
        hasLength(6),
      );
      expect(
        const DirectorySort(
          showSubtitles: true,
        ).apply(entries, hideHiddenFiles: false),
        hasLength(7),
      );
    },
  );
  const entries = [
    SourceEntry(name: '第10集.mkv', path: '10', modified: 20, size: 30),
    SourceEntry(name: '第02集.mp4', path: '2', modified: 30, size: 20),
    SourceEntry(name: '第1集.mkv', path: '1', modified: 10, size: 10),
    SourceEntry(name: '第1集.ass', path: 's'),
    SourceEntry(name: '番外', path: 'folder', directory: true),
  ];
  test(
    'natural order keeps directories first and hides subtitles by default',
    () {
      expect(const DirectorySort().apply(entries).map((e) => e.path), [
        'folder',
        '1',
        '2',
        '10',
      ]);
      expect(
        naturalNameCompare('第99999999999999999999集', '第100000000000000000000集'),
        lessThan(0),
      );
    },
  );
  test(
    'directory preferences preserve sort field, direction and subtitle visibility',
    () {
      final value = DirectorySort.fromJson(
        const DirectorySort(
          field: 'modified',
          descending: true,
          showSubtitles: true,
        ).toJson(),
      );
      expect(value.apply(entries).map((e) => e.path), [
        'folder',
        '2',
        '10',
        '1',
        's',
      ]);
      expect(
        const DirectorySort(
          field: 'size',
          descending: true,
        ).apply(entries).map((e) => e.path),
        ['folder', '10', '2', '1'],
      );
      expect(DirectorySort.fromJson({'field': 'untrusted'}).field, 'name');
    },
  );

  test(
    'natural sorting preserves zero padding, case and huge episode numbers',
    () {
      const names = [
        'ep100000000000000000000.mkv',
        'ep99999999999999999999.mkv',
        'ep10.mkv',
        'ep2.mkv',
        'ep02.mkv',
        'Ep02.mkv',
        'ep0.mkv',
        'ep000.mkv',
      ];
      final files = [
        for (final name in names) SourceEntry(name: name, path: name),
      ];
      const expected = [
        'ep0.mkv',
        'ep000.mkv',
        'Ep02.mkv',
        'ep02.mkv',
        'ep2.mkv',
        'ep10.mkv',
        'ep99999999999999999999.mkv',
        'ep100000000000000000000.mkv',
      ];
      for (final field in ['name', 'type', 'size', 'modified']) {
        expect(
          DirectorySort(field: field).apply(files).map((e) => e.name),
          expected,
        );
        expect(
          DirectorySort(
            field: field,
            descending: true,
          ).apply(files).map((e) => e.name),
          expected.reversed,
        );
      }
      expect(files.map((e) => e.name), names);
    },
  );
}
