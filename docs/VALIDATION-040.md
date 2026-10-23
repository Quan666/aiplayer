# 验证记录 · 0.4.0+5

验证环境为 Linux x86_64、Flutter 3.47.7 / Dart 3.13.5、Go 1.27.3、Android SDK 与 JDK 17。可用 Android 7 / API 24 x86_64 软件模拟器（4KB 页）；未连接 Android/iPhone/iPad 实机，也没有 Mac 或 Windows 构建机。以下将 0.4.0 本轮证据与 0.3.0 历史记录分开，工程文件存在不代表对应平台构建或设备验收通过。

## 0.4.0 本轮状态

| 项目 | 已执行范围与结果 |
| --- | --- |
| 单元 / 组件测试 | 149 项最终完整测试通过。包括原有来源、弹幕、同步、设置、主题与日志回归，以及本轮目录排序 / 返回状态、作品季度判定、外部打开解析、字幕解析 / AI 模拟接口、手势控件计时；大字体搜索栏、标签滑动与字幕设置重建也已修正后复核 |
| 静态分析 | 本轮收尾合并后 `flutter analyze` 为 No issues found |
| 播放操作定向测试 | `player_input_test.dart` + `playback_resume_test.dart` 共 9 项通过。覆盖拖动 / 弹层的嵌套保持、完整隐藏间隔重新计时、快捷键、方向元数据、旧 Android 系统栏恢复、已播完与短视频续播边界 |
| 真实播放器集成 | `integration_test/player_test.dart` 在 Linux mpv 通过：30 秒 H.264/AAC MKV、ASS、实际音量 / 倍速 / 软解 / 字幕及音频偏移属性、暂停定位 12 秒、SQLite 续播、播放时钟与页面通知分离、解码错误恢复及持续失败提示。新 UI 验证浅色库进入暗色播放器、全屏往返、一次系统返回直接回库、播放中设置菜单保持超过隐藏间隔、嵌套设置退出后控件仍显示、自定义快捷键生效。最终关闭屏障与白色文字修正版再次运行通过；移除播放器后等待原生解码器与系统显示清理，避免旧状态覆盖新播放页 |
| 真实字幕与截图集成 | `integration_test/subtitle_tools_test.dart` 在独立 Linux 进程通过：自动选中同名繁体 ASS，排除其它集数字幕；繁体转简体后检查 mpv 实际 `sub-text`，恢复原文、提取 MKV 内嵌文本轨、取消转换；对比含字幕 / 不含字幕的真实 JPEG 像素，确认 libass 输出进入截图。另关闭系统字体 provider 和附件字体，验证打包字体单独渲染中文 SRT / ASS；随后恢复字体附件，内嵌 ASS 仍正常。修复了变量字体内部 family 名称不一致导致 Android 无法匹配后备字体的问题；见 [无系统字体回退的截图](../artifacts/subtitles_chinese_fallback.jpg)。见 [简体 ASS 截图](../artifacts/subtitles_chinese_simplified.jpg)。Android API24 已通过系统 Downloads 对话框保存 JPEG，确认截图保留中文 ASS，见 [保存的截图](../artifacts/android_api24_040_saved_ass_screenshot.jpg)；Apple 保存流程尚未实测 |
| 字幕网络与格式测试 | 29 项字幕定向测试包含在最终全套中通过，覆盖文本解析、OpenCC、AI 分批请求 / 返回校验 / 取消等；使用本地模拟响应，未调用真实在线 API Key |
| 本轮截图 | [播放器](../artifacts/player_glass.png)、[播放设置](../artifacts/player_settings.png)、[原生画面与弹幕](../artifacts/playback.png) 来自真实运行。最终白色文字修正版播放器截图已更新，两主题截图库集成 1 项通过并重新生成手机 / 桌面界面图；资料仅为临时测试数据 |
| 进度封面 | 本轮 2 项真实封面集成通过，验证播放进度对应帧、有界本地缓存和重新打开；`artifacts/library_thumbnail.png` 为实际导入视频的封面与进度，未使用在线海报替代帧截图 |
| Android release 构建 | 0.4.0+5 通用及 ARM64 APK 构建通过；通用含 arm64-v8a / armeabi-v7a / x86_64，ARM64 小包只含 arm64-v8a。ZIP CRC、清单、v1/v2/v3 签名、相同证书和 versionCode、64 位库 16KB 对齐均由打包脚本校验。详见 artifacts/build-android.json 与 build-android-arm64.json |
| Android 模拟器 | API24 x86_64 软件模拟器已验证 0.4.0 原位升级、冷启动、保留 0.3.0 资料与偏好；`getPackageArchiveInfo` 非 null。真实临时 `content://` 授权下，VIEW / SEND 冷热打开均显示视频帧；全屏连续替换只有一个 MainActivity，一次返回回库。4 秒延迟的旧请求被取消，撤销原文件授权并删除提供者文件后，持久副本仍可冷启动重播。手动来源扫描、所有共享浏览、实际 SMB 3.1.1 视频播放与展开搜索通过。最终字体修复包在同目录中英 SRT 同时存在时自动选择并显示中文，也显示 MKV 内嵌中文 ASS，通过系统对话框保存含字幕 JPEG；再次通过全屏 SEND 热替换、单 Activity 与一次返回检查；详见 [安装与操作报告](../artifacts/android-install-check-040.json) |
| Linux release 构建 | 最终正常应用 release、tar.gz / deb 构建通过；解压后使用独立资料目录、不设置 LD_LIBRARY_PATH / JAVA_HOME 显示首帧。通过 launch.sh 传入 file:// URI，实际打开 30 秒 MKV、渲染 ASS，最终字体修复包再次播放并截图，SQLite 记录 9.708 / 30.021 秒。见 artifacts/linux_release.png、linux_external_open.png；.desktop 包含视频 MIME 入口，未更改宿主默认应用 |
| Apple / Windows | 未编译。新增 Apple 文档类型、Scene / AppDelegate 打开回调与安全作用域读取、Windows 可选“打开方式”注册均为源码实现，需目标系统构建和验证 |

SMB 另有 [枚举运行报告](../artifacts/smb-enumeration-runtime-040.json)：自动、签名、加密三种模式均协商 SMB 3.1.1 并列出共享。测试中发现旧 Samba RPC helper 引用已删除的配置，导致共享枚举超时；夹具现使用独立 ncalrpc 目录并只清理自身 helper。客户端增加 35 秒连接/请求时限、迟到连接释放及 worker 退出处理；模拟坏 RPC 服务时正确返回 0xC00000B5。新增 6 项 isolate 测试已通过。

本轮原生集成应分别运行：一次 Flutter 命令连续启动两个 Linux 集成入口时，第二个曾在 debug 连接阶段无法启动，尚未执行测试；以独立 Xvfb 进程重跑字幕集成后通过。这不属于已通过的在线服务或移动设备证据。

```bash
bash scripts/make_media_fixture.sh
cd client
flutter analyze
flutter test
xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 flutter test integration_test/player_test.dart -d linux
xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 flutter test integration_test/subtitle_tools_test.dart -d linux
# 集成使用测试入口，发布前必须重新构建正常应用。
flutter build linux --release
```

## 新增功能的验收边界

- 作品与目录识别采用保守规则：多个文件须具有一致作品和季度，Bangumi 仅在名称与季度明确吻合且唯一时采用。重名、缺少季度、混放、特别篇或剧场版不保证自动识别；保留普通文件浏览、直接播放与人工更正，不应用第一季海报代替不明确的后续季。
- 字幕支持同名外挂自动发现、简体中文优先、本地繁简转换、恢复原文及可选 AI 翻译。ASS 转换保留样式与时间轴；图片字幕不可文本转换。MKV 文本轨提取有有界读取及大小限制，不能承诺每个容器或每条内嵌轨可提取。
- 单文件授权不包含原目录权限。Android 分享 / 打开方式、iOS 文档打开及移动端单文件导入后，不能自动查找原目录的外挂字幕；应另选字幕，或从可列目录的已授权来源读取。移动端尚未实现 SAF / iOS 外部目录长期授权扫描。
- AI 翻译的 API 地址、Key、模型、目标语言和自定义要求已实现，首次发送前确认，仅发送字幕对白；Key 使用系统安全存储，不同步、不记录到日志。真实供应商模型列表、额度、翻译质量、超时 / 限流和在线错误尚未联调。
- Android 使用单任务入口让重复外部打开交给现有实例，避免多个播放器同时持有解码器；行为依据 [Android 任务与返回栈说明](https://developer.android.com/guide/components/activities/tasks-and-back-stack)。外部打开注册视频 `ACTION_VIEW` / `ACTION_SEND`，`content://` 按临时授权后台流式读取，不猜测文件系统路径。副本通过 `temporary` 标记交由 Dart 持久导入，原名称独立保留，再受限删除 native incoming 文件。模拟器已验证冷 / 热启动、全屏中连续分享、丢弃迟到旧请求及授权撤销后的副本重播；不代表各厂商文件管理器均已验证。
- Apple 文档声明包含标准视频与 MKV / WebM UTI，使用安全作用域访问与文件协调后导入。Windows 的当前用户注册脚本、Linux `.desktop` MIME 入口不修改系统默认应用；只有 Linux 的代码与脚本能在本机检查，Windows / Apple 运行行为待验收。
- 控件交互期间暂停隐藏计时，弹层退出重新开始完整间隔；返回一次离开播放器。Android 重力事件检查系统旋转锁并在后台停止监听；iOS 只跟随系统允许的窗口方向。真实触摸、旋转锁、快速横竖切换及不同厂商系统栏仍需设备验证。
- 动画遵循系统减少动画；上滑隐藏导航和 Android 高刷新率请求为内置行为，不再提供单独开关。局域网查找由用户在添加来源时启动，不在后台自动发现。模拟器 60Hz 和 Linux 软件渲染不能证明 90/120Hz 真机表现，也不能证明移动硬解。

## 0.3.0 历史证据

以下保留回归基线，不代表 0.4.0 对应最终包已重新通过。

| 项目 | 历史证据与范围 |
| --- | --- |
| 单元 / 静态分析 | 0.3.0 最终 99 项单元 / 组件测试通过；客户端和 SMB 插件静态分析通过。覆盖来源拆分 / 编辑 / 删除确认、目录内导航、日志脱敏、导入副本删除、封面队列、观看时间 / 百分比、局域网发现、设置与快捷键 |
| JSON 网络 | 持续分块超过无数据超时仍可完成；停滞超时、主动取消、重定向拒绝 |
| 原生 SMB | libsmb2 CMake 编译、隔离 Samba 账户认证、中文目录、stat、跨 1 MiB 及 5 GiB 偏移随机读取、文件末尾通过。错误密码 `0xC000006D`、共享不存在 `0xC00000CC` 映射到明确提示，见 `artifacts/source-smb-diagnostics.json` |
| Go 同步 / Docker | `go test -race` 与 Docker 构建 / `scripts/sync_smoke.py` 通过：认证、冲突、墓碑、字段限制、分页、并发、数据库重开、容器重启持久化、非 root 运行；临时容器与卷已清理。本轮服务端未因客户端 UI 改版而重新验收 |
| Android 0.3.0+4 | 通用与 ARM64 release 构建、Android 7+ 清单、三 ABI 的 7 个核心原生库、ZIP CRC、v1/v2/v3 签名及 64 位库 16KB 对齐校验通过；ARM64 小包仅含 `arm64-v8a`，两包证书与 versionCode 一致。API24 x86_64 模拟器 `getPackageArchiveInfo` 非 null、原位升级 / 冷启动、保留资料与偏好通过。导入 H.264、JPEG 帧封面及重启缓存、片尾重播、自动横屏、恢复系统栏与 WebDAV 错误日志均验证；见 [历史安装记录](../artifacts/android-install-check-030.json) |
| Linux 0.3.0 | 正常 release 及 tar.gz / deb 封装通过；解压后独立资料目录启动显示首帧，不设置 `LD_LIBRARY_PATH` / `JAVA_HOME`。构建环境 Ubuntu 24.04 x64，依赖 libmpv2、glibc ≥ 2.38 及包中列出的库，不是任意 Linux 发行版通用静态程序。当前同名截图已更新为 0.4.0，历史构建信息见 artifacts/verification-030.json |
| 视频封面 | 真实 mpv 截图与导入 → 480px 有界缓存 → 手机布局 → 重启离线复用两项集成通过；`artifacts/library_thumbnail.png` 展示真实帧、00:09 / 00:30 与 30%。Android 软件模拟器 PNG 缓存曾校验失败，改为后台原生缩放后 JPEG 编码，不依赖 Android 缺失的 lavfi scale；未同步图片缓存和路径 |
| 浅色 / 深色界面 | 生成两主题 × 手机 / 桌面 × 影视库 / 设置 / 来源共 12 张 Flutter 预览，资料仅为临时测试内容。这批历史截图不代表本轮新增菜单和功能已验收 |

局域网历史测试覆盖真实回环端口可达、模拟服务广播和取消，没有真实 NAS 的 mDNS / Bonjour 验收。WebDAV 仅发现主动广播的服务；SMB 端口探测限当前私有 IPv4 网段最多 254 个邻居，不探测公网、IPv6 或跨网段。

SMB 读取与可控断开重试独立验证，尚未将真实 NAS 断网恢复与所有 mpv 拖动场景组合验收。

## 安装错误与构建检查

用户报告安装阶段出现 `packageInfo is null`。历史原 0.1.1 通用 APK 的 ZIP / 清单 / v2 签名有效；标准 Android 7 模拟器的真实 `getPackageArchiveInfo` 非 null，安装 / 启动成功。0.3.0 延续原证书、加入 v1/v2/v3 校验，0.4.0 再次通过相同模拟器的 APK 解析、原位升级和冷启动，并保留原有资料。原手机错误没有复现，不能把签名变化认定为已经证明的根因修复；厂商兼容性仍需原手机的实际安装结果确认。

构建完成后可在授权设备上执行以下检查；示例命令本身不是已通过证据，保留数据、不卸载：

```bash
python3 scripts/validate_apk.py artifacts/aiplayer-0.4.0-android.apk --abi universal --expected-version 0.4.0+5
python3 scripts/android_install_check.py artifacts/aiplayer-0.4.0-android.apk --serial <设备ID> --archive-probe --launch
```

libsmb2 作为内部静态依赖构建，其开发头文件和 CMake 配置不再安装到宿主 `/usr/local`；CMake 安装验证仅打包 `libaiplayer_smb.so`。每次 release 打包需刷新正常应用的插件注册，避免遗留 `integration_test` 入口；记录实际构建产物、文件大小、证书与 SHA256。固定插件版本仍有旧 Kotlin Gradle 接入提示，升级 Flutter 前需处理相应迁移。

## SMB 复现

夹具使用隔离临时配置和密码数据库，仅监听 `127.0.0.1:1445`，不改系统共享；凭证仅供测试。安装 Samba 工具后执行：

```bash
# 终端一：创建测试账户可能需要管理员权限
bash scripts/smb_fixture.sh
# 终端二
cmake -S packages/aiplayer_smb/src -B /tmp/aiplayer-smb-build
cmake --build /tmp/aiplayer-smb-build
cd client
SMB_TEST_USER="$(id -un)" LD_LIBRARY_PATH=/tmp/aiplayer-smb-build dart run tool/smb_smoke.dart
```

完成后在终端一 Ctrl-C。匿名 SMB3 共享在本环境未通过，当前建议账户认证；Kerberos 未启用。

## 四端实机验收表

| 平台 | 0.4.0 构建 | 安装与设备 | 硬解 / 回退 | ASS / 字体 | SMB 拖动 |
| --- | --- | --- | --- | --- | --- |
| Android | 通用 / ARM64 release 通过 | API24 模拟器升级、冷热外部打开通过；真机待测 | 真机待测 | 模拟器中文 SRT、ASS / 字体附件与截图通过；真机待测 | 模拟器 SMB 3.1.1 浏览 / 播放通过；NAS 连续拖动待测 |
| iOS/iPadOS | 未执行 | 需 Mac / Xcode 和签名 | 待实测 | 待实测 | 待实测 |
| Windows | 未执行 | 需 Windows 构建机 | 待实测 | 待实测 | 待实测 |
| macOS | 未执行 | 需 Mac / Xcode | 待实测 | 待实测 | 待实测 |

设备记录应包括型号、系统、编码 / 位深 / 分辨率、诊断页实际解码器、音轨、ASS 定位与字体附件、外挂 SRT、字幕弹幕同屏、连续拖动、断网恢复、后台 / 返回 / 横竖屏、文件重新授权和外部冷 / 热打开。覆盖 MP4 / MKV、H.264 / HEVC、1080p / 4K、多音轨、H.264 10-bit 软件回退。

## 其余未验证项与限制

- 指定弹幕站点尚未使用真实 Token 联调；接口测试不能代替在线认证、实际返回及限流验收。
- Apple 原生媒体链接、CocoaPods、密钥环、Bonjour、安全作用域和本轮文档打开代码均未在 Xcode 编译；Windows 原生库和可选注册脚本未在 Windows 运行。
- 本地或外部授权文件复制导入会占用额外空间；SMB / WebDAV 播放无需复制完整视频。
- HTTP / WebDAV 支持 Basic 认证，重定向需填写最终地址；缺少文件大小不支持，无 Range 时不能保证随机定位。
- 多设备分别导入会产生不同媒体 ID，应先同步再关联本机文件；媒体 ID 加大小不能识别相同大小的不同剪辑。四端联动同步尚未实测，SQLite / API 测试已覆盖离线队列、冲突、增量与墓碑。
- 播放列表可手动切集，自动下一集和后台音频服务尚未实现；关闭后台暂停也不保证系统允许持续运行。HDR、杜比视界、音频直通、转码、投屏、下载管理、发送弹幕及 Emby / Jellyfin 不在首版范围。
- OpenCC 使用随包词典与 Apache-2.0 许可证，来源和校验见 `client/assets/opencc/source.json`，组件说明见 [第三方声明](../THIRD_PARTY_NOTICES.md)。这不代表完成了所有二进制依赖的公开分发许可证审计。

完成设备与在线验证后，才能将依赖组合标记为四端稳定基线。
