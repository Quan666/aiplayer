import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/media_identity.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bare episodes inherit the full folder title and season', () {
    const title = '用【循环利息】强制收回借出的魔力';
    for (final path in [
      '/$title/S02/03.mkv',
      r'C:\' + title + r'\S02\03.mkv',
    ]) {
      final identity = sourceEntryIdentity(
        SourceEntry(name: '03.mkv', path: path),
      );
      expect(identity.anime, title, reason: path);
      expect(identity.season, '2', reason: path);
      expect(identity.episode, '3', reason: path);
    }
  });

  test('relative source roots can supply missing folder evidence', () {
    final identity = sourceEntryIdentity(
      const SourceEntry(name: '03 - 开始.mkv', path: '03 - 开始.mkv'),
      fallback: const ReleaseName('Who? [Re:Start]', '2'),
    );
    expect(identity.anime, 'Who? [Re:Start]');
    expect(identity.season, '2');
    expect(identity.episode, '3');
  });

  test('only matching filenames inherit the parent season', () {
    final same = sourceEntryIdentity(
      const SourceEntry(name: 'Show E03.mkv', path: '/Show/S02/Show E03.mkv'),
    );
    expect(same.anime, 'Show');
    expect(same.season, '2');
    expect(same.episode, '3');
    final different = sourceEntryIdentity(
      const SourceEntry(name: 'Other E03.mkv', path: '/Show/S02/Other E03.mkv'),
    );
    expect(different.anime, 'Other');
    expect(different.season, isEmpty);
    expect(different.episode, '3');
  });

  test('explicit file seasons win over directory and fallback seasons', () {
    final identity = sourceEntryIdentity(
      const SourceEntry(
        name: 'Show S03E04.mkv',
        path: '/Show/S02/Show S03E04.mkv',
      ),
      fallback: const ReleaseName('Fallback', '5'),
    );
    expect(identity.anime, 'Show');
    expect(identity.season, '3');
    expect(identity.episode, '4');
  });
}
