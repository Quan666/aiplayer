# Android 6 兼容版

为 Android 6.0 / 6.0.1（API 23）设备保留独立构建。安装包同时包含
`armeabi-v7a` 和 `arm64-v8a`，适用于运行 32 位或 64 位 Android 的 ARM
电视。CPU 型号不能替代系统 ABI 检查。

现代版仍使用原来的 Flutter 和依赖锁，最低 Android 7.0。兼容版从当前源码
生成独立副本，使用 Flutter 3.32.8 / Dart 3.8.1、自己的 Pub 和 Gradle 校验锁。
两者沿用同一应用 ID、版本号与签名；安装新版时可保留数据，切换前仍应备份。

本次构建和测试范围见 [验证记录](VALIDATION.md)。共用原生构建脚本新增 API
校验后，旧 Android 原生缓存会重建一次；现代版仍默认构建 API 24。

## 本机构建

Linux x86_64 上先按项目说明准备 Android SDK、NDK 28.2.13676358、Java 17
和原生编译工具，并恢复现有 `.local-build/signing/debug.keystore`。
不要生成新签名替代它。

将官方 Flutter 3.32.8 Linux SDK 解压到 `.local-build/sdk/flutter-legacy`。
归档地址和 SHA-256 见 [toolchain.json](toolchain.json)；解压前必须核对摘要。
以 root 解压时使用 `tar --no-same-owner`。也可用
`AIPLAYER_LEGACY_FLUTTER` 指定已安装 SDK 的 `bin/flutter`。

```sh
bash scripts/package_android_legacy.sh --no-android-alias
```

入口会构建 API 23 原生播放器、准备 `.local-build/android6/source` 副本、
严格解析兼容锁文件，再构建、校验并打包。主线 `client/` 不会被降级。
输出位于 `artifacts/`：

- `aiplayer-<版本>-android-legacy.apk`
- `build-android-legacy.json`
- `SHA256SUMS-android-legacy`

`--android-legacy` 是兼容副本内 `scripts/package.py` 的打包参数；从根工作区
构建请使用上面的 shell 入口。副本由脚本管理，每次重新准备会删除旧副本，
不要在其中保存手工修改。

## GitHub Actions

手动运行 **Actions → Build Android 6 compatibility → Run workflow**。
工作流分别执行两种 ARM 原生编译、无密钥 APK 构建、独立 runner 签名校验，
最后提供带 `android-legacy` 的 APK 下载。签名仍使用已有
`ANDROID_KEYSTORE_BASE64` secret。该工作流不会阻塞现代版自动构建，也不会
自动发布 Release。

## 维护与验证

`adapt_sources.py` 只在副本内转换旧 Dart 构造参数、Flutter 列表缓存、排序、
TickerMode 和二维码 API。保留惰性列表、有界缓存、向下排序索引和即时生命周期
通知。转换锚点变化或存在未适配的新 API 时停止构建，避免静默遗漏。

原生播放器继续使用当前固定源码版本，API 23 / API 24 的构建目录、指纹和
产物 metadata 独立；插件验证 API、源码锁、构建脚本和 JAR 摘要。
SQLite 继续使用项目维护的源码。兼容包仍检查双 ARM、API 23、原证书、
v1/v2/v3 签名、必要播放库、PGS 和 16 KB 对齐。

修改共享源码后，应重新准备副本、执行旧 SDK 静态分析和相关 Flutter 回归，
再严格构建 APK。更新依赖时，维护者可使用 `prepare_android_legacy.py --bootstrap`
生成候选锁；须从官方来源核对新增构件，审查差异后更新本目录的
`pubspec.lock` 和 `verification-metadata.xml`，最后不带写入校验参数重新构建。
不要将跳过依赖校验作为正常构建方式。

冻结旧 Flutter 工具链需要独立维护；不能将现代版引擎升级等同于兼容版已更新。
APK 的静态检查和桌面测试不代表电视真机验证。安装、硬解、声音、字幕、遥控、
后台暂停与恢复仍需 Android 6 设备验收；没有真机测量就不宣称帧率或续航改善。

电视开启并授权 ADB 后，可用以下命令记录系统版本、ABI 和实际安装结果；
它使用覆盖安装，不会主动卸载应用：

```sh
source scripts/local_build_env.sh
python3 scripts/android_install_check.py artifacts/aiplayer-0.5.26-android-legacy.apk --android-legacy --launch
```

后续版本请替换为对应的 APK 文件名。
