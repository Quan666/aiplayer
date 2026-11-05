# 依赖与发布安全

## 构建边界

- GitHub Actions 使用官方仓库核对的完整提交 SHA。Docker 基础镜像固定的是包含 amd64 / arm64 的镜像索引 digest。
- Flutter 发布依赖使用已提交的 `client/pubspec.lock`，CI 执行 `flutter pub get --enforce-lockfile`。
- Android 提交官方 Gradle 9.3.1 Wrapper、JAR 校验值和分发 ZIP 校验值；`verification-metadata.xml` 校验 Maven 构件及其元数据，不配置全局信任例外。
- Kotlin Gradle Plugin 使用 2.4.21，覆盖 CVE-2026-53914 的修复。升级 AGP / Flutter 时仍需核对插件兼容性。
- Actions、Pub、Gradle、Go 和 Docker 依赖由维护者按需更新，更新时核对上游版本及摘要，并完成审查和验证。

## Android 原生播放器

`packages/media_kit_libs_android_video/native/sources.lock.json` 保存源码 URL、版本或提交、SHA-256 和本地补丁摘要。`scripts/build_android_native.py` 由独立原生工作流从这些源码构建原生库；编译工作只缓存每次重新校验的源码归档，不恢复源码树或安装前缀。应用构建复用本仓库按原生输入指纹命名的依赖 Release，校验 GitHub 托管资产的 SHA-256、来源指纹及 API / ABI / recipe 元数据，不接收任意编译缓存。

官方 media-kit Android v1.1.11 与 Darwin v0.7.3 的构建源码仍选择 FFmpeg 6.0，不能通过仅更新原生包版本号声称修复底层漏洞。Android 使用固定提交的 FFmpeg 6.1 维护分支及更新后的 TLS / XML / 字幕依赖；更新时必须复核上游安全修复，不能跟随可变分支。

正常发布分为三个隔离阶段：

1. 原生工作流仅在准确指纹的依赖版本缺失时从源码编译五套 API / ABI；独立发布作业验证全部 ZIP 后发布专用依赖预发布版本，不标记为 Latest，不覆盖已发布版本。
2. 无长期签名密钥、无仓库写权限的 runner 下载准确的预编译依赖，验证后构建 APK；缺失或损坏不允许回退到其他版本。
3. 新 runner 只运行仓库签名脚本和 Android SDK 工具；签名后立即删除密钥，再校验版本、ABI、PGS、16 KB 对齐和原有证书。

指纹包含源码锁、补丁、编译 / 校验 / 封装脚本、原生工作流和 toolchain 声明；普通应用或上传步骤变化不触发原生重编。宿主工具升级时维护 toolchain 的 `revision`，NDK 使用源码锁中的固定版本。来源清单记录构建提交、运行 ID 和工具链环境；这些记录用于追溯，不等同于独立第三方签名证明。依赖发布与读取信任同一仓库的维护者、GitHub Release API 和 runner。

签名作业不执行 Flutter、Gradle 或 APK 内代码。信任边界仍包括所构建的仓库提交、GitHub runner、编译器和 Android SDK 工具；源码锁定与作业隔离不能证明所有上游代码没有恶意行为。

## 其他原生下载

`packages/sqlite3_flutter_libs`、`packages/media_kit_libs_linux` 和 `packages/media_kit_libs_windows_video` 是保留上游许可证的本地补丁包，各包的 `UPSTREAM.md` 记录已核验的官方 Pub 归档。

共享 `packages/native_dependencies/verified_download.cmake` 对媒体依赖下载固定 SHA-256，启用 TLS 校验和超时；已缓存的归档同样校验，解压目录在配置时由可信归档重建。SQLite 3.52.0 已被上游撤回，本地插件改为所有平台直接编译同一份 SQLite 3.54.1 官方源码，使用 `sqlite-source.lock.json` 核对 SHA-256 和官方 SHA3-256。Go 驱动升级到 1.14.52，内置 SQLite 3.53.4。发布构建使用干净工作区，不恢复任意 CMake 编译输出缓存。

这些补丁提供下载完整性保护，不代表 Windows 旧 libmpv / ANGLE 或系统 libmpv 的所有漏洞已修复。系统媒体库还需通过操作系统更新维护。

## 更新和验证

修改依赖时先从上游正式来源核对版本及摘要，审查源码和构建脚本变化，再更新锁文件。不要以关闭校验、增加全局信任例外或直接接受失败日志中的新摘要来解决构建问题。

Android Maven 依赖发生正常变更后，可在受信任的干净环境重新生成候选元数据，审查差异并核对来源，随后不带写入参数重新构建：

```sh
cd client/android
./gradlew :app:dependencies --configuration releaseRuntimeClasspath --write-verification-metadata sha256
./gradlew :app:compileReleaseKotlin
```

原生源码、补丁及构建配方变化后，需要重新构建相应 ABI；不能沿用旧 JAR 的来源声明。验证包括构件摘要、ELF 依赖和对齐、必要解码器、真实 APK 打包，以及设备上的播放与字幕回归。

本地供应链回归入口：

```sh
python3 scripts/check_supply_chain.py
python3 -B -m unittest discover -s scripts/tests -p 'test_*.py'
```

下载测试使用临时本地 HTTPS 服务，需要允许绑定回环端口。

本轮验证记录（Linux 本机，工具版本与 Android / Verify CI 固定版本一致）：

- Android 原生四 ABI 均完成实际源码构建及独立 ELF 检查，包含 32 位 x86 无 TEXTREL、16 KB 对齐、PGS / JNI / MediaCodec 和准确的 mpv / FFmpeg 版本。
- 按 Actions 命令完成 arm64 和 universal Release APK 严格构建，最终构建不带 `--write-verification-metadata`。以一次性证书分别重签，SDK 的 ABI、PGS、16 KB、版本、v1 / v2 / v3 检查通过；APK 的原生 `.text` / `.rodata` 与当前源码配方 JAR 一致，各 ABI SQLite 的完整 source ID 为 3.54.1 的官方值。
- `flutter analyze --no-pub` 无问题。全套 Flutter 单元测试在新 SQLite 下通过 2057 项，跳过 15 项；打包与供应链脚本测试通过 69 项，跳过 3 项（Windows batch 和未启动的 SMB 信号夹具）。
- Linux 完整 Release 应用实际构建通过；包内 SQLite 为 3.54.1。PGS 两个原生集成场景及完整播放器主场景通过。
- 固定 digest 的服务端 Linux amd64 容器完成 `go mod verify`、`go test -race`，认证、版本冲突、增量同步与重启 / 重建持久化冒烟测试通过。

验证使用临时签名证书，未更换发布证书。以上是本地真实构建与回归结果，不等于已经在 GitHub 托管 runner 上执行了这次提交的工作流。

## 尚需平台验证

- 本机为 Linux，不能生成可信的 Apple `Podfile.lock`，也不能验证 Xcode / MSVC 构建。macOS CI 会导出实际解析出的锁文件；审查并提交该文件后，才能启用对应的 `pod install --deployment`。不得手写猜测解析结果。
- SQLite 的 Apple Pod / SwiftPM 改用本地 CSQLite 3.54.1 源码，避免回退系统旧 SQLite；iOS `file_picker` 的图片选择器及传递 Pod 仍需真实解析锁定。
- macOS / iOS 的旧原生播放器，以及暂停发布的 Windows 播放器，仍需独立升级底层媒体栈。下载校验与 Android 源码构建修复不覆盖这些平台。
- 本地交叉编译、SDK 检查和桌面回归不能替代 Android 真机播放、硬解、PiP、后台暂停和省电验证。未测量的范围不据此宣称性能或续航改善。
