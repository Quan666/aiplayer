// With scripts/smb_fixture.sh running:
// LD_LIBRARY_PATH=/tmp/aiplayer-smb-050-native dart
// --packages=client/.dart_tool/package_config.json scripts/smb_hidden_diagnostics.dart
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer_smb/aiplayer_smb.dart';

Future<void> main() async {
  final source = await SmbConnection.connect(
    host: '127.0.0.1:1445',
    share: 'video',
    user: Platform.environment['USER'] ?? 'root',
    password: 'aiplayer-fixture-password',
  );
  try {
    final entries = await source.list('');
    final hidden = entries.singleWhere((entry) => entry['name'] == '隐藏属性.mkv');
    final visible = entries.singleWhere((entry) => entry['name'] == '中文视频.mkv');
    final stat = await source.stat('隐藏属性.mkv');
    if (hidden['hidden'] != true ||
        stat['hidden'] != true ||
        visible['hidden'] == true) {
      throw StateError(
        'SMB hidden attributes did not survive native/Dart mapping',
      );
    }
    final result = {
      'dialect': smbDialectLabel(source.dialect),
      'nativeEntrySizeCheck': true,
      'hiddenAttributeFromList': hidden['hidden'],
      'hiddenAttributeFromStat': stat['hidden'],
      'ordinaryFileVisible': visible['hidden'] == false,
    };
    await File('artifacts/smb-hidden-runtime-050.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(result));
    print(jsonEncode(result));
  } finally {
    await source.close();
  }
}
