import 'package:aiplayer/ui/device_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('history uses saved platforms and recognizes older device names', () {
    expect(
      playbackDeviceIcon(platform: 'android', name: '我的手机'),
      Icons.phone_android_rounded,
    );
    expect(
      playbackDeviceIcon(name: 'Pixel 9 · Android'),
      Icons.phone_android_rounded,
    );
    expect(
      playbackDeviceIcon(name: 'iPhone · iOS'),
      Icons.phone_iphone_rounded,
    );
    expect(
      playbackDeviceIcon(platform: 'ios', name: 'iPad Pro'),
      Icons.tablet_mac_rounded,
    );
    expect(
      playbackDeviceIcon(name: 'Mac mini · macOS'),
      Icons.laptop_mac_rounded,
    );
    expect(playbackDeviceIcon(platform: 'windows'), Icons.computer_rounded);
    expect(playbackDeviceIcon(name: '未知设备'), Icons.devices_other_rounded);
  });
}
