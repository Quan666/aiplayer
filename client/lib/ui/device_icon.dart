import 'package:flutter/material.dart';

/// New history records carry a platform; old records retain the platform in
/// their device name (for example "Pixel 8 · Android").
IconData playbackDeviceIcon({String platform = '', String name = ''}) {
  final value = (platform.isEmpty ? name : platform).toLowerCase();
  if (name.toLowerCase().contains('ipad')) return Icons.tablet_mac_rounded;
  if (value.contains('android')) return Icons.phone_android_rounded;
  if (value.contains('ipad') || value.contains('tablet')) {
    return Icons.tablet_mac_rounded;
  }
  if (value.contains('iphone') || value.contains('ios')) {
    return Icons.phone_iphone_rounded;
  }
  if (value.contains('mac')) return Icons.laptop_mac_rounded;
  if (value.contains('windows') || value.contains('linux')) {
    return Icons.computer_rounded;
  }
  return Icons.devices_other_rounded;
}
