import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

List<SourceEntry> _files(String path, List<String> names) => [
  for (final name in names) SourceEntry(name: name, path: '$path/$name'),
];

void main() {
  for (final path in ['', '/S02', '/已改名文件夹']) {
    for (final reversed in [false, true]) {
      test(
        'first listing infers all episodes at "$path", reversed=$reversed',
        () {
          final files = _files(path, [
            '02.mkv',
            'Original Show S02E01.mkv',
            'S02E03.mkv',
            'Original Show E04.mkv',
            'trailer.mkv',
          ]);
          final group = identifyDirectory(
            path,
            reversed ? files.reversed.toList() : files,
          );
          expect(group?.title, 'Original Show');
          expect(group?.season, '2');
          expect(group?.videos, hasLength(4));
          expect(group?.episodeCount, 4);
          expect(
            group?.videos.map((entry) => group.identities[entry.path]?.episode),
            ['1', '2', '3', '4'],
          );
          expect(
            group?.identities.values.map((identity) => identity.season).toSet(),
            {'2'},
          );
        },
      );
    }
  }

  for (final (description, path, names) in [
    (
      'different works',
      '/renamed',
      ['Alpha S01E01.mkv', 'Beta E02.mkv', '03.mkv'],
    ),
    (
      'different named seasons',
      '/renamed',
      ['Alpha S01E01.mkv', 'Alpha S02E02.mkv', '03.mkv'],
    ),
    (
      'different title-less seasons',
      '/renamed',
      ['Alpha S01E01.mkv', 'S02E02.mkv', '03.mkv'],
    ),
    (
      'conflicting numeric folder season',
      '/Alpha/S01',
      ['Alpha S02E01.mkv', '02.mkv'],
    ),
    ('no series name at root', '', ['01.mkv', '02.mkv']),
  ]) {
    test('first listing rejects $description', () {
      expect(identifyDirectory(path, _files(path, names)), isNull);
    });
  }
}
