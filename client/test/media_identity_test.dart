import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/media_identity.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release titles retain authored brackets and punctuation', () {
    const titles = [
      '用【循环利息】强制收回借出的魔力',
      '用[循环利息]强制收回借出的魔力',
      '用［循环利息］强制收回借出的魔力',
      '【我推的孩子】',
      '[推しの子]',
      '86 (Eighty-Six)',
      'Dr. STONE',
      'Re：从零开始的异世界生活',
      'BanG Dream! It’s MyGO!!!!!',
      '命运：星 & 月 + 100%?',
    ];
    for (final title in titles) {
      final parsed = parseReleaseName('[Group] $title - 03 [1080p HEVC].mkv');
      expect(parsed.anime, title, reason: title);
      expect(parsed.episode, '3', reason: title);
    }
    expect(parseReleaseName('[86].mkv').anime, '[86]');
    expect(parseReleaseName('[86].mkv').episode, isEmpty);
    expect(parseReleaseName('标题 (特别版).mkv').anime, '标题 (特别版)');
  });

  test('release evidence still removes groups, formats and episode markers', () {
    const cases = {
      '［字幕组］ 用【循环利息】强制收回借出的魔力 ［03］［1080p］.mkv': ['用【循环利息】强制收回借出的魔力', '', '3'],
      '[Nekomoe kissaten&LoliHouse] LIAR GAME - 04 [WebRip 1080p HEVC-10bit AAC ASSx2].mkv':
          ['LIAR GAME', '', '4'],
      'Some.Show.S02E03.1080p.mkv': ['Some Show', '2', '3'],
      'Show.H.264.mkv': ['Show', '', ''],
      'Title (S02) E03.mkv': ['Title', '2', '3'],
      'Title [2nd Season] - 03.mkv': ['Title', '2', '3'],
      'Title OVA1.mkv': ['Title', '', 'O1'],
      '[ANi] 作品 - 03 [1080p].mkv': ['作品', '', '3'],
      '[Lilith-Raws] 作品 - 03 [1080p].mkv': ['作品', '', '3'],
      '[SubsPlease] 作品 - 03 [1080p].mkv': ['作品', '', '3'],
      '[字幕组][LoliHouse] 作品 - 03 [1080p].mkv': ['作品', '', '3'],
    };
    for (final entry in cases.entries) {
      final parsed = parseReleaseName(entry.key);
      expect(
        [parsed.anime, parsed.season, parsed.episode],
        entry.value,
        reason: entry.key,
      );
    }
  });

  test('catalogue titles do not pass through filename cleanup', () {
    for (final name in [
      'Fate/stay night [Unlimited Blade Works]',
      'Dr. STONE',
      '用【循环利息】强制收回借出的魔力',
      '100%? + 星 & 月',
    ]) {
      expect(subjectIdentity(name).anime, name);
      final saved = mediaRecordIdentity({
        'metadataTitle': name,
        'series': 'old parsed title',
        'fileName': 'Release.S02E03.mkv',
      });
      expect(saved.anime, name);
      expect(saved.season, '2');
      expect(saved.episode, '3');
    }
    expect(subjectIdentity('作品 第二季').season, '2');
    final folder = subjectIdentity('[组] 作品 第二季', releaseTags: true);
    expect(folder.anime, '作品');
    expect(folder.season, '2');
    final directory = directoryIdentity('/[组] 作品/S02/');
    expect(directory.anime, '作品');
    expect(directory.season, '2');
    final inlineDirectory = directoryIdentity('/[组] 作品 S02/');
    expect(inlineDirectory.anime, '作品');
    expect(inlineDirectory.season, '2');
    expect(subjectIdentity('Example II').season, '2');
    expect(
      subjectIdentity('Apollo 13', inferSeasonSuffix: false).anime,
      'Apollo 13',
    );
    expect(
      subjectIdentity('Example II', inferSeasonSuffix: false).anime,
      'Example II',
    );
  });

  test(
    'record identities keep saved fields and do not infer movie episodes',
    () {
      final record = mediaRecordIdentity({
        'metadataTitle': 'Title [Original]',
        'fileName': 'Release.S02E03.mkv',
        'season': 4,
        'episode': '12.5',
      });
      expect(
        [record.anime, record.season, record.episode],
        ['Title [Original]', '4', '12.5'],
      );
      final movie = mediaRecordIdentity({
        'metadataTitle': 'Apollo 13',
        'metadataType': 'movie',
        'fileName': 'Apollo 13.mkv',
      });
      expect(movie.anime, 'Apollo 13');
      expect(movie.episode, isEmpty);
      expect(movie.season, isEmpty);
    },
  );

  test(
    'legacy bracket loss is repaired without overriding folder or AI names',
    () {
      const title = '用【循环利息】强制收回借出的魔力';
      final repaired = mediaRecordIdentity({
        'series': '用 强制收回借出的魔力',
        'fileName': '[Group] $title - 03 [1080p].mkv',
        'episode': '3',
      });
      expect(repaired.anime, title);
      for (final fileName in [
        '03.mkv',
        '03 - subtitle.mkv',
        'Other - 03.mkv',
      ]) {
        final saved = mediaRecordIdentity({
          'series': '识别到的作品 [完整版]',
          'fileName': fileName,
          'season': '2',
          'episode': '3',
        });
        expect(saved.anime, '识别到的作品 [完整版]', reason: fileName);
        expect(saved.season, '2');
        expect(saved.episode, '3');
      }
      expect(
        mediaRecordIdentity({
          'series': '未分类',
          'fileName': '$title - 03.mkv',
        }).anime,
        title,
      );
    },
  );

  test(
    'directory evidence is shared without mixing different work seasons',
    () {
      const folder = ReleaseName('用【循环利息】强制收回借出的魔力', '2');
      for (final filename in ['03.mkv', 'EP03.mkv', '03 - subtitle.mkv']) {
        final parsed = releaseIdentity(filename, folder: folder);
        expect(
          [parsed.anime, parsed.season, parsed.episode],
          [folder.anime, '2', '3'],
        );
      }
      expect(
        releaseIdentity('${folder.anime} - 03.mkv', folder: folder).season,
        '2',
      );
      expect(releaseIdentity('Other - 03.mkv', folder: folder).season, isEmpty);
      expect(
        releaseIdentity('${folder.anime} S04E03.mkv', folder: folder).season,
        '4',
      );
    },
  );
  test('persisted previews from the old title parser are not reused', () {
    final store = AppStore(':memory:');
    try {
      final legacyContext = sha256
          .convert(
            utf8.encode(jsonEncode(['catalog-v5', null, 'conservative', ''])),
          )
          .toString();
      persistDirectoryPreview(
        store,
        'nas',
        '/Show',
        DirectoryPreview(
          collection: const DirectoryCollection(
            title: '用 强制收回借出的魔力',
            season: '',
            videos: [],
            identities: {},
          ),
          context: legacyContext,
          fingerprint: 'unchanged-files',
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          modified: 0,
        ),
      );
      expect(readDirectoryPreview(store, 'nas', '/Show'), isNotNull);
      expect(LibraryCatalog(store).directoryPreview('nas', '/Show'), isNull);
    } finally {
      store.dispose();
    }
  });
}
