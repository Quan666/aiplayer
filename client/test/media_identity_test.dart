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

  test('mixed and fully encoded release filenames retain their episode', () {
    const title = '世界最强的魔女，就此开始';
    const fileName = '$title - E04 [ANi] [繁体].mp4';
    for (final name in [
      fileName,
      '$title%20-%20E04%20[ANi]%20[繁体].mp4',
      Uri.encodeComponent(fileName),
    ]) {
      final parsed = parseReleaseName('2026-10/$title/$name');
      expect([parsed.anime, parsed.season, parsed.episode], [title, '', '4']);
      expect(parsed.matchName, '$title S01E04');
    }
  });

  test('percent decoding is single pass and preserves invalid sequences', () {
    const cases = {
      '命运100%?%20-%20E04.mp4': '命运100%?',
      '命运%25%20-%20E04.mp4': '命运%',
      '命运%2520%20-%20E04.mp4': '命运%20',
      '命运%ZZ%20-%20E04.mp4': '命运%ZZ',
      '命运%E4%20-%20E04.mp4': '命运%E4',
      '命运%FF%20-%20E04.mp4': '命运%FF',
      '命运%ED%A0%80%20-%20E04.mp4': '命运%ED%A0%80',
      '命运%E4%B8%96%E7%95%8C%20-%20E04.mp4': '命运世界',
    };
    for (final entry in cases.entries) {
      final parsed = parseReleaseName(entry.key);
      expect(parsed.anime, entry.value, reason: entry.key);
      expect(parsed.episode, '4', reason: entry.key);
    }
  });

  test('episode separators are removed without trimming authored hyphens', () {
    const cases = {
      '某作品 - E04.mp4': '某作品',
      '某作品 - S02E04.mp4': '某作品',
      '某作品 - OVA1.mp4': '某作品',
      '前-后 - E04.mp4': '前-后',
      '前 - 后 - E04.mp4': '前 - 后',
      '作品- E04.mp4': '作品-',
      '作品- - E04.mp4': '作品-',
      '作品 -- E04.mp4': '作品 --',
      '作品 - 结局.mp4': '作品 - 结局',
    };
    for (final entry in cases.entries) {
      expect(parseReleaseName(entry.key).anime, entry.value, reason: entry.key);
    }
  });

  test('exact names left by the previous release parser are repaired', () {
    const title = '世界最强的魔女，就此开始';
    const encodedFile = '$title%20-%20E04%20[ANi]%20[繁体].mp4';
    const plainFile = '$title - E04 [ANi] [繁体].mp4';
    for (final (fileName, oldSeries) in [
      (encodedFile, '$title%20-%20E04%20[ANi]%20'),
      (plainFile, '$title -'),
      (Uri.encodeComponent(plainFile), '$title -'),
    ]) {
      final repaired = mediaRecordIdentity({
        'fileName': fileName,
        'series': oldSeries,
      });
      expect([repaired.anime, repaired.episode], [title, '4']);
      final savedEpisode = mediaRecordIdentity({
        'fileName': fileName,
        'series': oldSeries,
        'season': '2',
        'episode': '7',
      });
      expect(
        [savedEpisode.anime, savedEpisode.season, savedEpisode.episode],
        [title, '2', '7'],
      );
      for (final manualTitle in ['人工作品名', '$title 手动修正 -']) {
        expect(
          mediaRecordIdentity({
            'fileName': fileName,
            'series': manualTitle,
          }).anime,
          manualTitle,
        );
      }
      expect(
        mediaRecordIdentity({
          'fileName': fileName,
          'series': oldSeries,
          'metadataTitle': '识别或人工指定的标题 -',
        }).anime,
        '识别或人工指定的标题 -',
      );
    }
    // A similar-looking saved title is not repaired without file evidence.
    expect(
      mediaRecordIdentity({
        'fileName': '$title E04.mp4',
        'series': '$title -',
      }).anime,
      '$title -',
    );
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
      for (final legacyInput in [
        ['catalog-v5', null, 'conservative', ''],
        ['catalog-v6', 2, null, 'conservative', ''],
      ]) {
        final legacyContext = sha256
            .convert(utf8.encode(jsonEncode(legacyInput)))
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
      }
    } finally {
      store.dispose();
    }
  });
}
