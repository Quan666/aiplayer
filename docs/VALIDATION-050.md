# 验证记录 · 0.5.0+6

本轮环境：Linux x86_64、Flutter 3.47.7 / Dart 3.13.5、Go 1.27.3、Android SDK / JDK 17，Android 11 / API30 x86_64 软件模拟器。未连接手机、电视或 NAS 实机，没有 Mac / Xcode 或 Windows 构建机。源码实现、模拟接口、模拟器与实机验收分别记录，不相互替代。

## 已完成的代码与回归

| 项目 | 本轮证据 |
| --- | --- |
| Flutter | 最终完整单元 / 组件测试 **186 项通过**；静态分析 `No issues found`。最终补充 SOAP UTF-8 Content-Length 断言后，9 项投屏测试再次通过。包含设置左右滑动、搜索换词重置位置、来源收藏 / 隐藏属性 / 目录排序、资料策略、系列历史、逐集进度、TMDB 类型隔离、投屏取消和 PiP 交接 |
| 真实播放器 | Linux / mpv 的 `player_test.dart` 完整通过：按下立即展示且抬指 / 播放重建不误隐藏、鼠标悬停后点击、完整隐藏间隔、画面三态轮询、右侧锁定、嵌套菜单、全屏往返及一次系统返回。原生方向恢复由页面统一负责，避免 vendor 被拦截的 Back 提前恢复竖屏。见 [播放器验证报告](../artifacts/player-verification-050.json) |
| 拖动截图 | 独立 `seek_preview_test.dart` 通过。真实烧录时间码验证 5 → 11 → 12 秒仅采用最新目标，预览 12 秒时主播放器仍停在 2 秒；空闲释放 / 重开、请求取消与关闭通过。[预览截图](../artifacts/player_seek_preview.png) |
| 进度封面 | 单元回归覆盖退出播放帧立即替换、旧任务不能覆盖新帧、近期记录优先于已满队列。退出时使用当前解码器截图，失败保留已有图片。未把封面功能当作所有容器均可截图的保证 |
| 来源 | 收藏只保存在本机，记录来源 ID 与相对目录；长按收藏、根目录入口、编辑保持来源身份、各目录独立排序、返回滚动位置和动态隐藏设置通过。真实隔离 Samba 的 SMB 3.1.1 列目录 / stat 验证隐藏属性，报告见 [SMB 隐藏属性](../artifacts/smb-hidden-runtime-050.json)；C / Android 三 ABI 结构大小检查通过 |
| 资料与历史 | 同系列只显示最新继续观看，各集记录独立；资料评分 / 总集数 / 季度 / 历史入口、可信同季缺集修复、人工更正保护、TMDB TV / movie 编号隔离通过。在线识别仅发送整理名称与数字季度 / 集数，测试检查无视频、路径或直链。Bangumi 公开名称搜索已检查；TMDB 使用本地受控响应，真实 Key 联调待完成 |
| DLNA | 9 项受控回归通过：SOAP 中文 / 参数、HEAD / Range、令牌与接收方 IP 隔离、源错误、迟到连接释放、取消 SetURI 后没有迟到 Play、最终 Stop、恢复位置确认。网络请求成功不等于实际定位成功，恢复失败冻结旧播放器的进度写入并提示重新打开。[协议与限制](CASTING.md) |
| iOS PiP | 5 项 Dart 通道回归通过：交接 / 失败恢复、退出记录、旧回调隔离、已关闭播放器不触碰 mpv、seek 未生效不覆盖记录。Swift AVPlayer / AVPictureInPictureController 源码已接入，但无 Xcode 编译和设备验证 |
| 同步服务 | `go test -race ./...` 通过；Docker 镜像构建及实际容器验收通过：认证、版本冲突、增量同步、公开 TMDB 资料字段往返、拒绝 API Key、重启持久化及非 root 身份。临时容器 / 卷自动清理 |

## 发布包与设备

Android 通用 / ARM64 APK 和 Linux tar.gz / deb 均已构建。四个安装产物及两个 Android 别名的 SHA256 全部核对。两种 APK 的证书与 versionCode 相同，ZIP CRC、清单、v1/v2/v3 签名及 64 位原生库 16KB 对齐通过；ARM64 小包只有 `arm64-v8a`。详见 `artifacts/build-android.json`、`build-android-arm64.json`、`build-linux.json`。

Android 11 / API30 模拟器已通过真实 PackageManager 解析（`packageInfo` 非 null）、从 0.4.0 原位升级及冷启动，原媒体 / 进度 / 已看记录和深色主题保留。见 [安装报告](../artifacts/android-api30-050-install.json) 及 `android_api30_050_upgrade_before.json` / `after.json`。系统 PiP 已通过真实触摸进入（`pinned`，桌面位于前台）、后台画面时间推进 58.934 秒、展开不重置进度及一次返回影视库。实际系统小窗按钮为展开 / 关闭 / 系统设置，未加入暂停或拖动 RemoteAction。五轮结束 / 暂停态触摸展示截图中四轮明确可见，一轮因软件模拟器截图延迟无法判定；没有宣称默认播放态精确五轮均通过。见 [Android 播放验收](../artifacts/android-api30-050-player-acceptance.json)。该 PiP 操作对应加固定 SOAP Content-Length 前的 0.5.0 构建；唯一后续源码改动为 DLNA 消息长度，最终 APK 已重新完成安装 / 解析 / 冷启动。

Linux 发布使用已由 Android release 刷新的正常插件注册与锁定依赖；构建时跳过重复联网获取。最终 tar 解包后在独立资料 / D-Bus / Xvfb 下实际运行，不设置 `LD_LIBRARY_PATH` / `JAVA_HOME`。真实点击小窗使窗口从 1280×720 缩至 480×270，视频帧持续变化，退出恢复原尺寸；返回库记录 14.167 / 90.055 秒（16%）并显示新截图背景，中文 ASS 和控件无溢出。见 [Linux 发布包小窗报告](../artifacts/linux-pip-release-050.json)。Xvfb 没有窗口管理器，未验证置顶策略或声音。Linux 仍需包内列出的系统库，构建宿主 Ubuntu 24.04 / glibc 2.39，最低 glibc 2.38，不能当作任意发行版通用静态程序。

普通 Android 手机使用通用包（ARM32 / ARM64 / x86_64，Android 7.0+）；可选 ARM64 小包只包含 `arm64-v8a`。系统画中画需要 Android 8.0+ 和系统许可，不影响 Android 7 普通播放。

Apple / Windows 尚未构建。桌面小窗为可恢复的置顶窗口；iOS 以 AVPlayer 临时接管系统画中画，格式受系统解码能力限制，ASS / 弹幕 / mpv 手选音轨不会随播放器转入系统小窗。准备失败应恢复应用内播放，需在 Mac / 实机复核。

最终 Linux 发布包另通过了完整 DLNA UI 链路：选择设备前没有视频读取，选中后 HEAD 200、首段 / 中段 Range 206 且与原文件哈希一致；暂停、拖动至 3:00、音量 35、继续和停止均确认收到对应 SOAP。停止后旧临时地址关闭，本机恢复至远端位置并继续解码，返回库后的最新封面与保存进度一致。SOAP 逐条校验 UTF-8 字节长度。见 [最终发布包投屏报告](../artifacts/linux-dlna-release-050.json)。这是发布客户端连接本地受控接收器，未测试物理电视渲染。

## 复现

```bash
bash scripts/make_media_fixture.sh
cd client
flutter analyze
flutter test
xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 flutter test integration_test/player_test.dart -d linux
xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 flutter test integration_test/seek_preview_test.dart -d linux
# 每个原生集成独立运行；发布前重建正常应用入口
cd ..
python3 scripts/package.py android
python3 scripts/package.py android --android-abi arm64
python3 scripts/package.py linux
```

DLNA 模拟接收器复现见 [投屏说明](CASTING.md) 与 `scripts/dlna_fixture.py`。它验证控制和实际字节读取，不渲染 / 转码，不替代物理电视兼容性测试。

## 保留的验收边界

- 用户原手机的 `packageInfo is null` 未复现。旧版本在标准 Android 7 模拟器的实际 PackageManager 解析非 null，安装 / 原位升级成功；不能据此宣称已证明原手机错误根因。新版沿用原证书，安装时保留资料。
- 真实 Android / Apple 硬解、HEVC / 4K、H.264 10-bit 回退、HDR、音频直通、90 / 120Hz、旋转锁及真实 NAS 断网 / 连续拖动未完成组合实机验收。软件模拟器不证明这些能力。
- Apple / Windows 工程、系统凭证、文档授权、原生小窗及插件库需各自系统构建。四端同步联动未完成；本地队列 / API 冲突与墓碑已有测试。
- 指定弹幕站点的真实 Token、TMDB Key 及真实 AI 翻译供应商尚未联调。名称识别策略和受控接口测试不保证所有作品正确匹配；可关闭自动识别、人工更正，未知视频仍可播放。
- 文件复制导入占用本机空间。只授权单文件不能扫描其原目录的外挂字幕；可另选字幕或从可列目录的来源读取。移动外部目录长期授权扫描仍待实现。
- 投屏为 DLNA，不含 Chromecast / 系统 AirPlay，不转码，接收设备决定格式 / 字幕支持。用户主动选设备后才启动独立的临时局域网视频桥接；自动识别不会上传视频。
- 播放列表支持手动切集，自动下一集 / 后台音频服务尚未实现。图片字幕不能文本繁简转换或 AI 翻译。HDR、杜比视界、音频直通、转码、下载管理、发送弹幕、Emby / Jellyfin 不在当前范围。

[0.4.0 完整历史验证](VALIDATION-040.md) 保留了中文 SRT / ASS、字体、截图保存、Android 7 外部打开 / SMB、Linux 发布包与更早同步测试细节。历史证据不等于 0.5.0 每个平台 / 每项操作已重新通过；历史构建汇总见 `artifacts/verification-040.json`。
