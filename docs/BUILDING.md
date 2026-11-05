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

## 校验与整理

Android 打包脚本必须通过最低 API、准确 ABI 集合、核心原生库、PGS、ZIP CRC、16 KB 对齐、v1/v2/v3 签名与固定证书检查后才复制到 `artifacts/`。三个 Android 目标分别保留 `build-android.json` / `build-android-arm64.json` / `build-android-legacy.json`，以及对应的 `SHA256SUMS-*`；它们是校验记录，不是额外安装包。macOS `--app-only` 只生成 ZIP，由脚本检查签名和双架构。

整理已有产物时先校验，再恢复上述标准名称及配套记录；这不等同于重新编译当前源码。只有用户要求复用旧构建时才使用底层 `--skip-build`，报告中说明复用范围。兼容 shell 入口不接受 `--skip-build`，确需恢复现有兼容产物时使用兼容副本内的 `scripts/package.py android --android-legacy --skip-build --no-android-alias --output-dir <根仓库>/artifacts`。

旧的 `tv-*`、固定名称 `*-release.apk` 等重复安装包先核对后移到 `.local-build/artifact-archive/`，不要继续作为下载入口。清理时只移动确认属于旧安装包的文件，不删除日志、签名、缓存或用户文件。不要在安装包缺失时创建空文件、假链接，或用重命名替代构建。

交付时说明类型、下载路径、版本、大小和实际验证范围。静态检查通过不等于 Android 6.0.1 / Android TV 真机安装、播放、遥控或功耗验证通过。
