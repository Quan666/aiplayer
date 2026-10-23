# 映库客户端

Flutter + media_kit/mpv + SQLite。运行、四端构建、来源配置、同步和当前验收边界见 [根目录说明](../README.md)。

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

保留 pubspec.lock 使用已验证的依赖组合。SMB 插件位于 `../packages/aiplayer_smb`，不能只复制 client 而遗漏该目录。
