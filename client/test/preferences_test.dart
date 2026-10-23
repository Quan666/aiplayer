import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:aiplayer/data/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('damaged stored values fall back or clamp to usable controls', () {
    final preferences = AppPreferences({
      'autoPlay': 'false',
      'resumePlayback': null,
      'autoDiscover': 0,
      'aiMetadataEnabled': 'true',
      'playbackRate': double.nan,
      'volume': -100,
      'audioDelay': 500,
      'subtitleScale': double.infinity,
      'subtitlePosition': 1000,
      'danmuOpacity': -1,
      'danmuArea': 7,
      'refreshInterval': 12,
      'seekStepSeconds': '15',
      'videoFit': 'unknown',
      'subtitleLanguage': ['zh'],
      'subtitleColor': '#INVALID',
      'danmuBlockedWords': '字' * 4100,
      'shortcuts': 'broken',
    });
    expect(preferences.autoPlay, isTrue);
    expect(preferences.resumePlayback, isTrue);
    expect(preferences.autoDiscover, isFalse);
    expect(preferences.aiMetadataEnabled, isFalse);
    expect(preferences.playbackRate, 1);
    expect(preferences.volume, 0);
    expect(preferences.audioDelay, 10);
    expect(preferences.subtitleScale, 1);
    expect(preferences.subtitlePosition, 100);
    expect(preferences.danmuOpacity, .1);
    expect(preferences.danmuArea, 1);
    expect(preferences.refreshInterval, 30);
    expect(preferences.seekStepSeconds, 10);
    expect(preferences.videoFit, 'contain');
    expect(preferences.subtitleLanguage, 'zh-Hans');
    expect(preferences.subtitleColor, '#FFFFFF');
    expect(preferences.danmuBlockedWords.length, 4000);
    expect(preferences.shortcuts, AppPreferences.defaultShortcuts);
    expect(AppPreferences({'refreshInterval': 0}).refreshInterval, 0);
    expect(AppPreferences({'refreshInterval': 99999}).refreshInterval, 3600);
  });

  test('invalid writes fail instead of silently storing unusable settings', () {
    final preferences = AppPreferences({});
    for (final patch in <Map<String, dynamic>>[
      {'unknownOption': true},
      {'autoPlay': 1},
      {'aiMetadataEnabled': 'yes'},
      {'volume': '60'},
      {'volume': 101},
      {'playbackRate': .1},
      {'audioDelay': double.nan},
      {'danmuOpacity': double.infinity},
      {'refreshInterval': 15},
      {'videoFit': 'stretch'},
      {'subtitleColor': '#FF0000'},
      {'danmuBlockedWords': '字' * 4001},
      {'shortcuts': []},
      {
        'shortcuts': {'unknownAction': 'K'},
      },
      {
        'shortcuts': {'mute': 'Ctrl+Ctrl+K'},
      },
    ]) {
      expect(() => preferences.checkedPatch(patch), throwsArgumentError);
    }
    expect(preferences.volume, 100);
    expect(
      preferences.checkedPatch({'refreshInterval': 0})['refreshInterval'],
      0,
    );
    expect(
      preferences.checkedPatch({'refreshInterval': 3600})['refreshInterval'],
      3600,
    );
  });

  test(
    'shortcut combinations normalize modifiers and reject ambiguous input',
    () {
      expect(AppPreferences.normalizeShortcut('Shift+Ctrl+K'), 'Ctrl+Shift+K');
      expect(
        AppPreferences.normalizeShortcut('Meta+Alt+Shift+F12'),
        'Alt+Shift+Meta+F12',
      );
      expect(
        AppPreferences.normalizeShortcut('Ctrl+ArrowRight'),
        'Ctrl+ArrowRight',
      );
      expect(AppPreferences.normalizeShortcut('None'), 'None');
      for (final key in <Object?>[
        '',
        null,
        4,
        'k',
        'Ctrl',
        'Ctrl+None',
        'Ctrl+Ctrl+K',
        'Option+K',
        'Shift+Ctrl+',
        'F13',
        ' Ctrl+K',
      ]) {
        expect(AppPreferences.normalizeShortcut(key), isNull, reason: '$key');
      }
    },
  );

  test(
    'shortcut conflicts consider unchanged actions and allow atomic swaps',
    () {
      final preferences = AppPreferences({});
      expect(
        () => preferences.checkedPatch({
          'shortcuts': {'playPause': 'F'},
        }),
        throwsArgumentError,
      );
      expect(
        () => preferences.checkedPatch({
          'shortcuts': {'playPause': 'Ctrl+Shift+K', 'mute': 'Shift+Ctrl+K'},
        }),
        throwsArgumentError,
      );
      final patch = preferences.checkedPatch({
        'shortcuts': {
          'playPause': 'F',
          'fullscreen': 'Space',
          'mute': 'None',
          'danmaku': 'None',
        },
      });
      final shortcuts = patch['shortcuts'] as Map;
      expect(shortcuts['playPause'], 'F');
      expect(shortcuts['fullscreen'], 'Space');
      expect(shortcuts['mute'], 'None');
      expect(shortcuts['danmaku'], 'None');
      expect(shortcuts['seekForward'], 'ArrowRight');
      expect(preferences.shortcuts['playPause'], 'Space');
    },
  );

  test('old conflicting storage cannot bind one key to multiple actions', () {
    final preferences = AppPreferences({
      'shortcuts': {'playPause': 'X', 'mute': 'X', 'fullscreen': 'bad key'},
    });
    final shortcuts = preferences.shortcuts;
    final active = shortcuts.values.where((key) => key != 'None').toList();
    expect(active.toSet().length, active.length);
    expect(shortcuts['playPause'], 'X');
    expect(shortcuts['mute'], 'None');
    expect(shortcuts['fullscreen'], 'F');
    shortcuts['playPause'] = 'Z';
    expect(preferences.shortcuts['playPause'], 'X');
  });

  test(
    'preferences survive restart; reset preserves credentials, sources and library',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync(
        'aiplayer-preferences-',
      );
      final path = '${directory.path}/library.db';
      AppStore? store = AppStore(path);
      AppModel? model = AppModel(store, directory);
      try {
        await model.setSettings(
          {
            'danmuOrigin': 'https://danmu.example',
            'syncOrigin': 'https://sync.example',
          },
          danmuToken: 'danmu-secret',
          syncToken: 'sync-secret-longer-than-24-characters',
        );
        await model.saveSource({
          'id': 'nas',
          'kind': 'smb',
          'label': 'NAS',
          'host': '192.168.1.2',
          'share': 'media',
          'user': 'alice',
        }, 'source-secret');
        model.setThemeMode(ThemeMode.dark);
        var changes = 0;
        model.addListener(() => changes++);
        await model.updatePreferences({
          'autoDiscover': false,
          'aiMetadataEnabled': true,
          'playbackRate': 1.5,
          'volume': 65,
          'subtitleScale': 1.25,
          'shortcuts': {'playPause': 'Shift+Ctrl+K'},
        });
        expect(changes, 1);
        expect(store.pending, isEmpty);
        await expectLater(
          model.updatePreferences({'volume': 20, 'unknown': true}),
          throwsArgumentError,
        );
        expect(model.preferences.volume, 65);
        expect(changes, 1);
        store.save('media', 'film', {'title': 'Film', 'fileName': 'Film.mkv'});
        store.save('progress', 'film:version1', {
          'position': 125,
          'duration': 1440,
        });
        store.setLocal('location:film', {
          'source': 'nas',
          'path': 'Anime/Film.mkv',
        });
        final pendingBefore = store.pending
            .map((record) => record.toJson())
            .toList();

        model.dispose();
        model = null;
        store.dispose();
        store = AppStore(path);
        model = AppModel(store, directory);
        expect(model.preferences.autoDiscover, isFalse);
        expect(model.preferences.aiMetadataEnabled, isTrue);
        expect(model.preferences.playbackRate, 1.5);
        expect(model.preferences.volume, 65);
        expect(model.preferences.subtitleScale, 1.25);
        expect(model.preferences.shortcuts['playPause'], 'Ctrl+Shift+K');
        expect(model.themeMode, ThemeMode.dark);
        await model.resetPreferences();
        expect(model.preferences.autoDiscover, isFalse);
        expect(model.preferences.aiMetadataEnabled, isFalse);
        expect(model.preferences.playbackRate, 1);
        expect(model.preferences.volume, 100);
        expect(model.preferences.subtitleScale, 1);
        expect(model.preferences.shortcuts, AppPreferences.defaultShortcuts);
        expect(model.themeMode, ThemeMode.dark);
        expect(model.sources.single['id'], 'nas');
        expect(model.settings['danmuOrigin'], 'https://danmu.example');
        expect(model.settings['syncOrigin'], 'https://sync.example');
        expect(await model.secrets.read(key: 'danmuToken'), 'danmu-secret');
        expect(
          await model.secrets.read(key: 'syncToken'),
          'sync-secret-longer-than-24-characters',
        );
        expect(await model.secrets.read(key: 'source:nas'), 'source-secret');
        expect(store.get('media', 'film')?.data['title'], 'Film');
        expect(store.get('progress', 'film:version1')?.data['position'], 125);
        expect(store.local('location:film'), {
          'source': 'nas',
          'path': 'Anime/Film.mkv',
        });
        expect(
          store.pending.map((record) => record.toJson()).toList(),
          pendingBefore,
        );
      } finally {
        model?.dispose();
        store?.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );
}
