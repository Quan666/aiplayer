# 构建与产物约定

AI 执行打包前先读本文件。默认只交付下面四类安装包，统一放在仓库根目录 `artifacts/`。不增加 TV 专用命名、TV ARM64 单独包、固定名称 APK 副本或默认 DMG。

| 类型 / 构建目标 | 安装包名称 | 系统与架构 |
| --- | --- | --- |
| 安卓通用 / `android` | `aiplayer-<版本>-android.apk` | Android 7.0+（API 24）；ARM32、ARM64、x86_64 |
| 安卓 ARM64 / `android-arm64` | `aiplayer-<版本>-android-arm64.apk` | Android 7.0+（API 24）；仅 ARM64 |
| 兼容版通用 / `android-legacy` | `aiplayer-<版本>-android-legacy.apk` | Android 6.0 / 6.0.1+（API 23）；ARM32、ARM64，不含 x86 |
| macOS / `macos` | `aiplayer-macos-unsigned.zip` | Apple Silicon、Intel 通用应用；ad-hoc 签名、未公证 |

`<版本>` 取 `client/pubspec.yaml` 中 `version` 的版本名部分，例如 `0.5.26+32` 对应文件名 `0.5.26`，包内构建号仍为 `32`。不因重新编译自行升级版本。macOS 保留现有 CI 的固定 ZIP 名称；每次构建覆盖同名产物。

电视按原生设备类型自动启用遥控模式。用户要求 TV 包或老电视安装包时，默认交付 `android-legacy`，不能把现代 APK 改名当成兼容版。用户未指定架构时不另行生成 TV ARM64 包。兼容版“通用”指双 ARM，不表示包含所有 CPU 架构。

## 快速执行

在仓库根目录执行，只构建用户要求的目标：

```bash
bash scripts/build_release.sh android
bash scripts/build_release.sh android-arm64
bash scripts/build_release.sh android-legacy
# 以下命令必须在 Mac 或 GitHub macOS runner 上运行：
bash scripts/build_release.sh macos
```

以上是四条独立命令，不要求每次全部执行。若要求全部 Android 包，按顺序执行前三条；不要并行操作同一个 Flutter 构建目录或兼容副本。本机 Linux 不能构建 macOS；需使用现有 **Actions → Build packages → target: macos**，不得将旧包或改名文件称作本次 macOS 构建。

快捷入口复用既有脚本：

- `android`：加载 `scripts/local_build_env.sh` 后执行 `python3 scripts/package.py android --no-android-alias`。
- `android-arm64`：`bash scripts/package_android_arm64.sh --no-android-alias`。
- `android-legacy`：`bash scripts/package_android_legacy.sh --no-android-alias`。
- `macos`：`bash scripts/package_macos.sh --app-only`，只交付一个 ZIP，不运行默认的 DMG 打包分支。

## 环境与兼容边界

Android 使用项目持久环境 `.local-build/`：Flutter / Android SDK 在 `sdk/`，依赖缓存在 `cache/`，临时目录为 `tmp/`。现代版使用 `sdk/flutter`；兼容版固定使用 `sdk/flutter-legacy` 中的 Flutter 3.32.8 / Dart 3.8.1 和 `compat/android6/` 的独立依赖锁，不能仅降低现代版的 `minSdk`。

兼容入口每次从当前源码准备 `.local-build/android6/source`，验证 API 23 双 ARM 原生库后再构建；不降级主线 `client/`。该副本会重建，不要在里面保存修改。详细配置见 [Android 6 兼容构建](../compat/android6/README.md)。

所有 Android 包沿用 `.local-build/signing/debug.keystore` 和 `signing/android-certificate.sha256` 的原证书。密钥缺失先恢复备份，禁止生成替代密钥。依赖按锁文件解析，不执行 `pub upgrade`，不跳过 Gradle 依赖校验。

macOS 使用现有 macOS 脚本和 CI 工具链，保留双架构、包权限、符号链接与签名检查。`unsigned` 表示没有开发者证书和公证，不表示完全没有签名。

## GitHub Actions

统一使用 **Actions → Build packages**；默认 `all` 生成上表四个安装包。
`android` 生成三个 Android 包，`android-legacy` 只生成 Android 6 兼容包，
`macos` 只生成 macOS ZIP。兼容配置 `compat/android6/**` 的变更也触发主流程。
PR 运行构建计划、打包回归和 macOS 构建，不接触 Android 签名密钥；完整 Android
构建在 push / 手动运行执行。标签必须匹配源码版本；发布 Android 时缺少 legacy
会阻止 Release，不能静默漏发。

现代 Android、兼容 Android、macOS 并行。Android 打包前调用独立的
**Build Android native** 工作流，按原生输入的 SHA-256 指纹查找依赖版本：
已存在时只检查版本，不启动原生编译；缺失时并行构建 API 24 的 ARM32 / ARM64 /
x86_64 和 API 23 的 ARM32 / ARM64，全部验证通过后发布，再继续应用打包。
也可单独手动运行原生工作流提前准备依赖。相同指纹的自动准备使用
`queue: max` 串行排队去重，不因第三个调用替换第二个等待任务。

依赖保存在本仓库 `native-android-<完整指纹>` 的专用预发布版本中，
不标记为 Latest，不占用 `v*` 应用版本；保留五个按 API / ABI 命名的依赖 ZIP。
每个 ZIP 只包含播放器 JAR、其元数据和来源清单。依赖版本不受 Actions
缓存过期影响，已发布版本不覆盖；草稿上传失败可重试，缺包不发布。
校验 API 失败或已发布版本损坏时直接报错，不能退回旧版依赖或在应用 runner
悄悄重编。发布 / 重试前必须拥有仓库 Contents 写权限；构建代码和 APK 签名
runner 不获得该写权限。

指纹包含原生源码锁、已锁定补丁、编译和校验脚本、依赖封装脚本、
原生工作流及 `native/toolchain.json`；修改 Dart、版本号、应用打包工作流或上传说明
不会使原生版本失效。NDK 在源码锁中固定，宿主 runner、Python、工具包集合、
并发和维护修订号在 toolchain 文件中声明；需要升级宿主编译工具时修改该声明或
增加 `revision`，不能假设同名 runner 的系统镜像永久不变。
来源清单记录生产提交、运行 ID、镜像版本、Python 和 NDK。

应用 runner 只下载对应 API 的预编译库，先对照 GitHub Releases API 的文件大小和
SHA-256，再校验来源指纹、仓库、源码锁、补丁、recipe、API、ABI、JAR 摘要。
所有需要的 ABI 通过后才交给 Gradle；插件继续逐次校验，提供库无效时拒绝构建。
SQLite 和 SMB 仍按应用构建编译，本次只拆分 Android FFmpeg / mpv 播放链。
现代通用、ARM64 顺序共用 Flutter / Gradle 工作区，避免竞争构建目录。
CI 先用 `pub get --enforce-lockfile` 检查依赖，再以相同目标参数执行
`flutter build apk --release --pub --config-only` 生成发布模式插件注册。
确认 `pubspec.lock` 内容未变后才以 `--no-pub` 正式编译，避免把
`integration_test` 等开发插件注册进 release。配置失败或锁文件变化立即停止。

CI 仍调用 `bash scripts/build_release.sh <目标>`：设置
`AIPLAYER_ANDROID_UNSIGNED=true` 时进入专用 CI 暂存分支，使用 runner 上的
Flutter / Android SDK。构建阶段拒绝接收签名密钥；原证书仅在独立、无依赖构建的
签名 runner 中恢复，用完删除，再做 APK 校验及上传。

原生工作流只缓存每次使用前重新哈希的源码压缩包，不恢复任意编译工作目录。
应用 Gradle 只缓存依赖下载及 wrapper，保留严格依赖校验；macOS 缓存 CocoaPods
下载和同依赖版本的锁文件，实际依赖锁写入任务摘要。首次依赖准备仍须完整原生
编译，提速效果需以真实 Actions 首次 / 复用运行测量。

原生依赖发布使用的 `internal-native-*` 临时产物由原生工作流清理；
签名前另临时传递最多两个 `internal-unsigned-*` 压缩产物。
签名消费结束后清理当前运行的中间产物（包括构建 / 签名失败路径），正常结束只留下
三个 APK 和一个 macOS ZIP；不上传依赖锁、日志和重复 APK。
如果任务被强制终止导致清理未完成，中间产物最多保留一天。
清理后需要重新构建时使用 **Re-run all jobs**，仅重跑签名会缺少已清理的输入。
每个成品直接下载原 APK / ZIP，任务摘要提供下载链接、系统、架构、大小、
SHA-256 和校验记录，不再新增说明文件下载项。

## 校验与整理

Android 打包脚本必须通过最低 API、准确 ABI 集合、核心原生库、PGS、ZIP CRC、16 KB 对齐、v1/v2/v3 签名与固定证书检查后才复制到 `artifacts/`。三个 Android 目标分别保留 `build-android.json` / `build-android-arm64.json` / `build-android-legacy.json`，以及对应的 `SHA256SUMS-*`；它们是校验记录，不是额外安装包。macOS `--app-only` 只生成 ZIP，由脚本检查签名和双架构。

兼容包额外拒绝 Android 6 不支持的 DEX 版本（含多 DEX），并以
`apksigner --min-sdk-version 23 --max-sdk-version 23` 单独验证旧系统使用的 v1
签名及证书。它仍不能替代目标电视的真实 PackageManager 安装结果；出现无法安装
时需获取具体 APK、系统 ABI、`adb install -r` 返回码及已有安装的版本 / 签名，
不能把通过静态校验直接写成“已修复安装”。

整理已有产物时先校验，再恢复上述标准名称及配套记录；这不等同于重新编译当前源码。只有用户要求复用旧构建时才使用底层 `--skip-build`，报告中说明复用范围。兼容 shell 入口不接受 `--skip-build`，确需恢复现有兼容产物时使用兼容副本内的 `scripts/package.py android --android-legacy --skip-build --no-android-alias --output-dir <根仓库>/artifacts`。

旧的 `tv-*`、固定名称 `*-release.apk` 等重复安装包先核对后移到 `.local-build/artifact-archive/`，不要继续作为下载入口。清理时只移动确认属于旧安装包的文件，不删除日志、签名、缓存或用户文件。不要在安装包缺失时创建空文件、假链接，或用重命名替代构建。

交付时说明类型、下载路径、版本、大小和实际验证范围。静态检查通过不等于 Android 6.0.1 / Android TV 真机安装、播放、遥控或功耗验证通过。
