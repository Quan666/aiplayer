# 验证记录

## 2026-10-23：桌面窗口、快捷键与弹幕开播

- 桌面默认内容区统一为 1280×720（16:9），按屏幕可用空间等比缩小并居中；修正 macOS 的 800×600 默认值和 Windows 将标题栏算进视频尺寸的问题。Linux 在 1920×1080、1366×768、800×600 及两种标题栏组合下验证内容比例，原生 `-Wall -Werror` 检查通过；macOS XIB 通过 XML 校验。
- 桌面快捷键先于控件焦点处理，进度滑块不会吞掉上下音量键。新增 J 前进 89 秒、Shift+J 后退 89 秒、K 播放 / 暂停，保留已有自定义映射；文本编辑和弹层继续使用自己的按键，长按空格不会误激活当前按钮。全屏鼠标移动通过播放器范围内的全局指针监听唤醒控件。各端手动截图按钮替换为弹幕入口，移除截图导出流程。
- 弹幕配置和识别与视频来源准备并行；首批弹幕先通知显示，再编码和写入缓存。旧匹配或唯一搜索结果的弹幕下载返回 404 时重新匹配一次，跳过已失败 ID；损坏缓存重新获取，404 刷新退避 5 分钟并保留已有弹幕。正在重新匹配时不刷新旧集数，关闭再开启弹幕可恢复被取消的首次加载。超过 1 秒的请求记录搜索 / 匹配 / 下载耗时，日志不含 Token 或完整请求地址。
- 全量 `flutter test --no-pub`：673 项通过、2 项跳过；后续快捷键、偏好、启动生命周期、弹幕接口 / 加载 / JSON 共 50 项定向回归通过。`flutter analyze --no-pub` 无问题，`git diff --check` 通过。
- Linux `integration_test/player_test.dart` 3 项全部通过；补充长按空格保护后，真实播放主用例再次通过。覆盖真实 MKV 解码、字幕、弹幕按钮、焦点下的方向键与 J / Shift+J / K / 空格、全屏鼠标唤醒、应用内连续外部打开、进度保存和横屏安全区域。运行环境为 Xvfb / 软件图形；本轮未构建发布安装包，Windows / macOS 原生编译与实机验收仍待对应系统完成。未使用真实弹幕服务 Token 联调，不能把全部 404 或等待时间归因于单一服务端问题。

## 2026-10-23：桌面端滚动与轮播优化

- Windows、macOS、Linux 与移动端共用识别后海报落盘、按显示尺寸解码、作品资料缓存和按压 / 悬停子树复用。桌面端也默认关闭实时背景模糊，保留渐变、边框和圆角。
- 新增共享滚动活动范围：连续滚轮事件合并为一次活动，停止约 120ms 后才启动未缓存图片的加载 / 解码和影视库数据刷新；触控板、嵌套滚动及仍按住的拖动保持活动。每个范围共用一个计时器，图片不再分别轮询，活动变化不重建整个卡片树。
- 继续观看的左右箭头只在可用状态改变时重建；滚动范围变化只更新箭头，避免重建轮播。回归覆盖滚轮方向、首尾边界、窗口缩放、历史增删和三种桌面平台的滚轮 / 悬停输入。
- `flutter test --no-pub`：653 项通过、2 项跳过；随后补充父子滚动范围的活动组合，相关 55 项定向回归通过；最终 `flutter analyze --no-pub` 无问题。测试运行于 Linux，桌面平台主题与输入变体不等同于 Windows / macOS 原生运行或实机帧率测量。

## 2026-10-23：播放期间的周期进度保存与同步

- 保留每 10 秒保存周期；磁盘数据库的进度写入、已看标记和播放期上传在独立 isolate 执行。截图仍只在暂停、后台、退出事件按需生成。播放期同步不拉取资料或推进下载游标，退出后正常同步补齐配置、来源和图片。
- 保存先捕获位置，再串行写入；退出等待最后的进度落盘。上传确认与冲突处理保留等待期间的新进度，包括向后拖动。SQLite 临时忙状态在后台有界重试，失败仍保留待同步记录。
- 数据库按变更范围维护计数，进度和同步心跳不会使媒体、位置、设置缓存失效；其它连接同时修改资料仍正常失效。静默播放同步不广播隐藏页面刷新。
- 定向单元 / 组件回归 **133 项通过**：播放生命周期 15 项、磁盘进度存储 7 项、真实磁盘与本机 HTTP 上传 6 项、同步与播放器通知 53 项、存储 / 加密 / 缓存 / 历史 52 项。锁竞争测试由主 isolate 的计时器释放写锁，验证等待期间事件循环仍响应；另覆盖网络及写锁等待取消、事务回滚、旧确认与新定位并发。
- Linux 原生 `real MKV decode, libass, seeking, overlay and persistent progress` 集成 **1 项通过**，覆盖真实解码、字幕、拖动和持久化进度。相关 Dart 文件静态分析与 `git diff --check` 通过。
- 原生集成运行于 Xvfb / 软件图形环境；本轮没有 Android / iOS / macOS / Windows 实机帧时间测量，不能据此保证用户设备的所有卡顿均已消失。

## 2026-10-23：移动端滚动与识别后海报缓存

- 海报墙继续使用惰性 Sliver 网格，继续观看使用横向惰性列表。滑动期间合并后台资料、封面和同步通知，嵌套滚动全部结束后再刷新；切换标签时保留待刷新状态。按压缩放只更新变换，复用海报和文字子树。
- 海报在普通识别、AI 识别、人工匹配及目录识别成功后异步缓存，不依赖卡片可见；沿用同 URL 去重、最多 4 路下载和长期磁盘保存。真实本地 HTTP 测试验证未显示卡片也会下载、失败不阻塞识别、重启断网后仍命中。
- 图片结果到达时再次检查滚动速度和可见范围，避免下载开始后进入快速滑动仍立即解码。已有内存图片继续复用；移动端默认关闭控件与导航的实时背景模糊，保留渐变、边框和圆角。
- 来源信息卡按媒体、位置和进度版本复用作品及最近观看结果；普通封面更新不再遍历整部作品。分集标题迟到时仍会更新翻译完整性。全量回归同时暴露并修复了后台同步取消后遗留的延迟计时器。
- `flutter test --no-pub`：620 项通过、2 项跳过；`flutter analyze --no-pub` 无问题，`git diff --check` 通过。未构建新安装包，未进行 Android / iOS 真机帧率测量，不能据此保证所有设备不再掉帧。

## 2026-10-23：桌面端改为应用内播放

- 影视库、来源、外部打开统一进入主应用内的 `PlayerPage`。移除独立播放器入口、第二 Flutter 引擎、Linux 播放器子进程和多窗口管理；小窗只调整当前主窗口。
- 全屏复用主窗口，返回后恢复窗口状态；切集仍保留当前路由。原生关闭窗口和 macOS 退出应用等待播放页释放、进度截图落盘后再销毁引擎。
- 更新原生播放集成测试，覆盖主窗口全屏、Esc 两步返回、连续外部打开只保留一个播放器和临时播放清理。新增桌面主窗口通道及关闭时等待保存的组件测试。
- 本次编辑环境未提供 Flutter/Dart SDK 或桌面原生编译工具；尚未在此环境运行 Flutter 测试、构建或完成三端实机验收。GitHub Actions 的实际结果另行记录，不能沿用下方历史测试数量。
- 旧的 `linux_player_window_check.py` 多窗口验收脚本已移除。下方独立窗口的测试结果仅记录历史版本，不代表当前产品行为。


`artifacts/` 的过时文件已按要求清理；下方历史记录中的旧安装包、日志、截图和报告链接不再提供，文字记录保留。未带版本号的构建报告与校验文件指向最新产物。

## 播放控件、切集与滚动体验 · 2026-10-22

- 手机端影视库顶部移除同步状态、其它状态文字、视频数量副标题及扫描进度条；继续观看不再创建滚动条，桌面滚动条只接收自身的横向滚动通知。宽屏侧栏支持折叠为图标并保存选择；导航按钮直接切页，已打开页面保留状态与滚动位置。
- 桌面鼠标移动唤醒播放控件，全屏隐藏控件时同时隐藏光标；控件以 200ms 淡出和轻微位移隐藏，隐藏后移出点击、焦点和语义树。多次点击的触摸保护仅用于移动端，恢复桌面设置、锁定等按钮的鼠标点击。播放器空白画面可拖动窗口；原生拖动接管前结束 Flutter 按下状态，避免拖动后失去悬停与下一次点击，这项已在 Linux 复现并通过复验。
- 退出时先隐藏原生窗口，再保存进度和清理解码器；清理期间的全屏恢复不得重新显示窗口。外部切换请求与播放列表共用切换流程，原生窗口关闭会取消尚未完成的开播。
- 开播保留已有封面，首帧判断同时检查有效纹理尺寸、缓冲状态和 mpv 的当前视频帧信息，再等待 Flutter 合成。切集保留暂停的上一视频纹理和同一个 Video 元素，待新画面就绪后释放，避免使用低清缩略图拉伸过渡。帧信息属性见 [mpv 官方手册](https://mpv.io/manual/stable/#properties-video-frame-info)。
- 已命中的海报文件路径同步复用，缩略图/海报使用相同尺寸的解码缓存键；快速滚动复用已有纹理，未缓存图片与视频预览延后到可见且滚动允许加载时处理。保持解码内存缓存的容量限制，磁盘缓存仍可跨启动复用；不会无限保留每张图片的解码内存。
- 同作品同季同集归并为一行，兼容 `02` / `2.0` 等编号形式；更多菜单可选择视频版本，各版本文件和进度仍保留。播放列表与自动下一集使用相同归并结果。速度、音轨、字幕、播放列表及通用选择面板优先居中当前项，并在首尾限制滚动范围。
- 观看记录保存系统平台，Android 使用手机图标；旧记录根据设备名称识别，未知设备使用通用图标。
- 完整单元 / 组件测试 **598 项通过**，[测试日志](../artifacts/player-experience-20261022/tests.log)；缓存复用与编号归并定向 **11 项通过**，[定向日志](../artifacts/player-experience-20261022/artwork-playlist.log)。静态分析无问题，[分析日志](../artifacts/player-experience-20261022/analyze.log)。
- 本地 → HTTP Range → 本地切换真实集成 **1 项通过**，断言旧 Video 元素保留、暂停和释放时机，并用鼠标点击设置及锁定按钮。本轮隔离环境首帧测得 1179 / 1727 / 496ms，仅记录观测值，不作为跨设备性能保证。[开播与切换日志](../artifacts/player-experience-20261022/startup.log)。
- Linux 真实播放器 / 字幕 / 进度 / 安全区集成 **2 项通过**，[播放器日志](../artifacts/player-experience-20261022/player.log)。Linux 发布构建通过，[构建日志](../artifacts/player-experience-20261022/linux-build.log)。独立 Xvfb + Openbox 窗口验收通过：两窗口无标题栏、背景拖动、拖动后首次鼠标点击暂停 / 恢复、全屏持续解码、光标隐藏 / 唤醒、Esc 恢复窗口再退出、其它窗口不受影响；关闭隐藏观测耗时 **167ms**，包含脚本发送按键的等待时间。[窗口结果](../artifacts/player-experience-20261022/result.json)。
- 本轮没有 Android / iOS 真机或 Windows / macOS 系统验证；这些平台的实际首帧、硬件解码与窗口行为仍需对应设备复验。

## 播放窗口、自动同步与本地媒体修复 · 2026-10-22

- 开播并行进行来源连接、原生设置和预览清理；大型字幕字体在影视库显示期间提前准备，以临时文件原子发布，支持多个播放引擎同时启动。关闭 mpv 磁盘缓存，保留内存预读，缓冲恢复等待改为 150ms；相关选项含义见 [mpv 官方手册](https://mpv.io/manual/stable/#options-cache-pause-wait)。这不会绕过真正的网络欠载或解码等待。
- 首帧判断排除 media_kit 桌面端的 1×1 占位纹理；真实输出就绪前保留已有观看封面。加载改为画面顶部细进度条，避开中央播放按钮；桌面控件首帧直接可见，加载期间不倒计时隐藏。
- 每个桌面窗口独立计数，关闭一个不会恢复后台预览去干扰其它播放器。Esc 先退出全屏，再关闭窗口；短暂桌面遮挡延迟确认，真正最小化仍按设置暂停，恢复窗口不强制播放。Windows 全屏移除多余边框重算。原生无标题栏、多窗口及全屏持续解码已在真实 X11 窗口验收；Windows/macOS 对应系统尚未实测。
- 同步默认按实际修改时间自动合并，删除及同时间修改有稳定排序，设置/来源/收藏逐项保留时间。服务新增修改时间和设备名称字段及旧 SQLite 库自动迁移，修复旧服务拒绝新客户端字段的问题。需部署新版服务，当前未部署。
- 本地视频及关联进度/封面不上传；外部打开不进入影视库或观看历史，包括投屏和 iOS 画中画。退出仅删除本次拥有的临时副本，已有导入文件与外部原件保留。全部视频支持单条或整组移除。继续观看支持鼠标滚轮、拖拽、滚动条和箭头，展开历史在宽屏采用网格，远端记录标明设备名称。
- 截图仍只在暂停/关闭等事件按需获取；有效封面不会因定时进度更新而被重新抽帧。
- 客户端完整回归 **584 项通过**；其后全屏遮挡/关闭保护等定向 **26 项通过**、字体并发与播放定向 **9 项通过**、来源预览 **4 项通过**。静态分析无问题，Go 全套及真实服务协议回归通过。Linux 原生 UI/字幕/进度集成 **2 项通过**，新增本地→HTTP Range→本地切换集成 **1 项通过**。
- Android 调试构建、Linux 发布构建完成。真实独立窗口脚本 `scripts/linux_player_window_check.py` 在隔离 Xvfb + Openbox 中检查窗口无标题栏、两个播放器并存、全屏时像素持续变化、连续两次 Esc、关闭一个不影响另一个，以及临时播放无历史。复现与日志见 [本轮产物](../artifacts/player-sync-fixes-20261022/)。
- 首帧耗时含字体、解码及虚拟显卡输出，不能等同于用户局域网实机速度；未连接用户的 NAS 或 Android/Apple/Windows 真机。本轮未发布或替换线上客户端、未部署同步服务。

## 0.5.14+20 · 播放与界面性能 · 2026-10-22

- HTTP / WebDAV 的 Range 转发运行在独立 isolate，视频字节不经过界面线程；开播复用已有文件探测结果。受控测试覆盖认证、中文路径、范围读取、HEAD、无效请求、挂起连接取消和退出释放；界面 isolate 阻塞 900ms 时，独立上游经桥接到消费者的 32KB 数据仍在界面恢复前完成传输。这不是用户网络或 Android 实机测速。
- 移除客户端及服务端的同步播放功能。进度每 10 秒及暂停、切后台、退出时保存和同步；暂停/退出截图同帧去重、单任务取帧、异步压缩写盘，不做定时截图或退出轮询。截图增量同步只准备相关来源、文件关联与图片，播放时延后全库配置应用；回归覆盖取消、重试、桌面关闭前保存及跨设备并发修改冲突。
- 播放器控件与视频分离更新，默认关闭视频上的实时模糊；按媒体 / 位置修订号缓存播放列表。2000 条媒体的测试在 100 次进度更新和切集查询中仅全读媒体及位置各一次，不逐项查询位置。开播先请求全屏，使用实际显示比例，并在系统旋转期间暂缓显示视频，避免中间视口的缩放跳变。
- 影视库分组、历史与来源索引缓存复用；扫描分批写盘并让出界面线程。封面不再启动预热或导入即提取，只在卡片可见时请求，页面被播放器覆盖或滚动时暂缓。预览启动计时器可取消，点播放无需等满 120ms；图片编码内存缓存有上限，磁盘缓存仍长期保留。
- [Flutter 全量日志](../artifacts/performance-0514/flutter-tests.log)：**567 项通过**。[Linux 原生播放](../artifacts/performance-0514/linux-player.log)：**2 项通过**，验证控件、拖动、字幕、弹幕、全屏、安全区及新的视频组件复用断言。Go 服务 `go test ./...` 通过，原同步播放接口的 GET / PUT / DELETE 均为 404。[静态分析](../artifacts/performance-0514/flutter-analyze.log)无错误或警告，仅 3 条既有测试风格 info。
- 已构建 [0.5.14 Android 通用 APK](../artifacts/performance-0514/aiplayer-0.5.14-android.apk)，135,301,586 字节、versionCode 20、API 24+，含 ARM32 / ARM64 / x86_64。[APK 校验](../artifacts/performance-0514/build-android.json)通过签名连续性、v1/v2/v3、ZIP CRC、原生库、PGS 解码器和 16KB 对齐检查；[构建日志](../artifacts/performance-0514/android-build.log)、[SHA256](../artifacts/performance-0514/SHA256SUMS-android)。
- 未连接 Android 真机或用户的 WebDAV 服务，不能据此确认其设备卡顿已消失；Apple / Windows 共享逻辑已修改，本轮未在这些系统构建或实测。未部署服务端或替换现有服务包。

## Android CI 证书误报修复 · 2026-10-22

- [GitHub Ubuntu 24.04 runner 镜像](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md) 包含 Build Tools 37.0.0，校验脚本会选择已安装的最高版本。用 Google 官方 SDK 37 验证同一个 0.5.13 ARM64 APK，证书行由 36.1 的 `Signer #1` 改为 `V3.0 Signer:`；指纹不变。旧脚本只能匹配前者，实际返回 `certificate_sha256: null`，导致打包误报证书变化。
- 校验器兼容新旧 signer 标签，严格验证完整 SHA-256，排除公钥和 Source Stamp 指纹；缺失、异常或多个不同证书分别报错。真正的证书不匹配会显示预期和实际的公开指纹。现有密钥、固定证书和 Gradle 签名配置均未修改。
- 同一现有发布 APK 通过 Build Tools 36.1 完整校验；通过 Build Tools 37 完整校验及 `package.py android --android-abi arm64 --skip-build` 打包。37 的压缩包来自 Google SDK 仓库，并已核对官方元数据校验值。测试产物位于临时目录，完成后删除，未覆盖发布产物。
- Python 打包回归 **23 项通过，1 项 Windows 专用测试跳过**。覆盖新旧输出、重复证书、损坏指纹、多个证书，以及通用 / ARM64 包在固定证书不匹配时不输出 APK。本轮没有重新编译 Android 应用或运行远程 Actions；Kotlin 迁移和文件监控提示不是本次打包失败原因。

## 0.5.13+19 · 播放器面板与分区三击 · 2026-10-22

- 提高播放器玻璃面板不透明度至约 62–80%，设置恢复原右下位置。音轨、速度与播放列表共用带 16px 内边距的选中行样式。
- 速度按钮移至设置、截图和列表旁，快捷设置移除速度入口；高级设置按播放、字幕、弹幕、诊断四类组织，不再重复音轨或速度入口。
- 三击左、中、右区域可独立配置动作，双击和三击共用可调整的跳转时间；默认左侧后退、右侧前进 89 秒，中间沿用原动作，已有自定义三击动作保留。
- 沿用用户此前不测试的要求，本轮仅格式化后直接打包，未运行单元 / 组件 / 集成测试或静态分析，未安装或进行实机验证；仅执行正常打包内置的产物校验。
- 已构建 [0.5.13 ARM64 APK](../artifacts/aiplayer-0.5.13-android-arm64.apk)：51,487,997 字节、versionCode 19、Android API 24+。清单、ZIP CRC、核心原生库、PGS 解码器、v1/v2/v3 签名和 16 KB 对齐检查通过；沿用现有证书，0.5.4 至 0.5.12 可覆盖升级。[构建日志](../artifacts/release-0513-arm64-build.log)、[APK 验证](../artifacts/build-android-arm64.json)、[校验文件](../artifacts/SHA256SUMS-android-arm64)。SHA256：`ede10e6ed0b727b6337104f9093f570548e90731137a3095c50be6716624a75d`。
- 已删除 0.5.12 版本 APK 与旧构建日志，释放 51,425,934 字节；`artifacts/` 保留本次 Android 产物及现用同步服务，共 8 个文件。本轮未构建其它平台发布包。

## 0.5.12+18 · UI 主题集中与 ARM64 发布 · 2026-10-22

- 全 UI 的颜色、文字和组件样式集中到 `client/lib/ui/theme/`，涵盖影视库、来源、设置、弹幕和播放器，便于统一调整与更换主题；已打开的弹层随主题更新并保留表单状态。
- 播放器设置等面板统一透明玻璃外观，播放速度和音轨改为与播放列表一致的按钮旁小弹窗。
- 本轮按用户要求直接打包，未运行单元 / 组件 / 集成测试或静态分析，未安装或进行实机验证；仅执行正常打包内置的产物校验。
- 已构建 [0.5.12 ARM64 APK](../artifacts/aiplayer-0.5.12-android-arm64.apk)：51,422,467 字节、versionCode 18、Android API 24+。清单、ZIP CRC、核心原生库、PGS 解码器、v1/v2/v3 签名和 16 KB 对齐检查通过；沿用现有证书，0.5.4 至 0.5.11 可覆盖升级。[构建日志](../artifacts/release-0512-arm64-build.log)、[APK 验证](../artifacts/build-android-arm64.json)、[校验文件](../artifacts/SHA256SUMS-android-arm64)。SHA256：`20eb3bb43ab0a99045c664c04f71cf59e88296d8b94e241dd6fbd5613b3813e8`。
- 删除 269 个过时产物文件，释放 1,638,907,101 字节；保留本次两份 APK、构建日志与校验记录，以及仍在使用的同步服务二进制、0.5.3 服务包和校验文件，共 8 个文件。本轮未构建其它平台发布包。

## GitHub Actions 原生构建修复 · 2026-10-22

- 五个平台的打包任务全部合入 `packages.yml`，删除独立的 `macos.yml`。自动构建和手动 `target` 选择共用一个打包工作流。
- Apple SMB 配置不再声明私有 `sys/_iovec.h` 可用，使用已启用的公开 `sys/uio.h`；补齐 CocoaPods 直接编译时缺少的 `_U_` 定义。错误码头文件改为 textual，避免 Clang 在解析 `smb2.h` 期间导入同一模块造成重复声明。
- Linux 和 Windows 的 CMake 缺文件报错原因相同：移除对未跟踪的 `libsmb2.pc.in` 的重复配置，保留已有的 `cmake/libsmb2.pc.cmake` 生成流程。默认 CMake 最低版本从 3.5 提至 3.10，与插件入口一致，解决旧版本兼容性的弃用警告。新增回归只复制 Git 跟踪源码后配置并构建 SMB 原生库，防止本地忽略文件掩盖 CI 缺文件问题。
- `python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -v`：**15 项通过，1 项 Windows 原生批处理测试在 Linux 跳过**。包含 iOS/macOS 全部 110 个 C 包装源文件的 Clang 模块语法编译及 SMB 原生库 Release 构建；actionlint 1.7.12 和 `git diff --check` 通过。Verify 在这些测试前安装 Clang/CMake。
- 本轮验证环境为 Linux，没有执行 Windows 或 Xcode 的完整应用构建，也没有重新运行 Flutter 功能测试。修复后的平台构建结果需同步到 GitHub 后运行新的 Actions 确认。

## 0.5.11+17 · 自动下一集与双击 / 三击动作 · 2026-10-22

- 新增播完自动下一集，沿用手动切集的播放列表顺序并保留全屏状态；自动打开的下一集从头开始播放，最后一集不循环。「设置 → 播放」和播放器快捷设置均提供自动下一集开关。
- 移动端默认双击暂停 / 继续，三击从当前位置向前跳 89 秒。双击与三击分别支持前跳、后跳、跳到指定位置、暂停 / 继续、切换全屏或禁用；在「设置 → 播放」的手势设置中用分钟和秒配置跳转时间。
- 本轮按用户要求直接打包，未运行单元 / 组件 / 集成测试或静态分析，未安装或进行实机验证；以上为本轮功能变更说明，不代表已通过功能测试。
- 已构建 [0.5.11 ARM64 APK](../artifacts/aiplayer-0.5.11-android-arm64.apk)：51,356,936 字节、versionCode 17、Android API 24+。正常打包自带的清单、ZIP CRC、核心原生库、PGS 解码器、v1/v2/v3 签名和 16 KB 对齐检查通过；沿用现有证书，0.5.4 至 0.5.10 可覆盖升级。[构建日志](../artifacts/release-0511-arm64-build.log)、[APK 验证](../artifacts/build-android-arm64.json)、[校验文件](../artifacts/SHA256SUMS-android-arm64)。SHA256：`eeb9294d310015acf8aabf0fecb733ca8689bf5ad50c4465815de25e41335d41`。本轮未构建通用 APK 或其它平台发布包。

## 0.5.10+16 · 弹幕刷新连续性 · 2026-10-22

- 修复自动刷新收到增删改后重新分配全部轨道，导致屏幕上弹幕换行或消失的问题。正在显示的弹幕保留原文字、轨道、开始时间与时长，直到自然退出；新快照只重新安排后续弹幕，不补播新增的历史内容。空快照仍允许当前弹幕显示完，并在结束后停止动画。
- 拖动、切集、时间偏移及布局 / 筛选调整使用最新完整快照重建。回退原生位置晚于 seek 命令且期间发生刷新时也能恢复历史弹幕；正常插值时钟小幅校正不会重建布局。
- 此前修复阶段 **61 项定向单元 / 组件测试通过**，包括 8 项画面测试，检查刷新前后像素一致、空响应后继续运动并自然结束、拖动与刷新交错、切换会话清理，以及原有画中画 / 投屏恢复回归。[测试日志](../artifacts/danmaku-refresh-tests.log)。该阶段变更代码与测试静态检查无问题。[分析日志](../artifacts/danmaku-refresh-analyze.log)。本轮按用户要求直接打包，不重跑测试或静态分析。
- 已构建 [0.5.10 ARM64 APK](../artifacts/aiplayer-0.5.10-android-arm64.apk)：51,291,313 字节、versionCode 16、Android API 24+。正常打包自带的清单、ZIP CRC、核心原生库、PGS 解码器、v1/v2/v3 签名和 16 KB 对齐检查通过；沿用现有证书，0.5.4 至 0.5.9 可覆盖升级。[构建日志](../artifacts/release-0510-arm64-build.log)、[APK 验证](../artifacts/build-android-arm64.json)、[校验文件](../artifacts/SHA256SUMS-android-arm64)。SHA256：`4e64821d3a805436b2aadb3624294c1eaecfad9792d5dc42934578b4844aada3`。
- 本轮未构建通用 APK 或其它平台发布包，未安装或进行 Android 真机、真实弹幕服务联调。

## 0.5.9+15 · Android PGS 图片字幕修复与历史移除 · 2026-10-22

- 实际问题影片含 4 条 `hdmv_pgs_subtitle` 内嵌字幕，无外挂字幕。旧 Android APK 使用的 libmpv `v1.1.7 default` 关闭全部解码器后采用白名单，遗漏 `pgssub`；因此能发现轨道，却不能解码图片。[诊断记录](../artifacts/release-059-pgs-diagnosis.json)。
- Android 改为仓库内固定的 `media_kit_libs_android_video` 插件，下载官方 `v1.1.8 full` 原生库并核对 SHA-256。四 ABI 均已验证包含实际定义的 `ff_pgssub_decoder`，64 位库保持 16 KB 对齐。构建不再依赖修改 Pub 缓存；[依赖说明](../packages/media_kit_libs_android_video/README.md)。
- 修复 `Japanese-CHS[NEST]` / `Japanese-CHT[NEST]` 等括号标签的简繁识别。图片字幕继续原生显示，自动繁简转换跳过图片轨，字幕面板禁用不适用的文字转换按钮并说明原因。
- 继续观看卡片和观看历史列表支持长按 →「移除这条观看记录」。只移除所选文件当前版本的进度，写入空数据的同步删除记录；同作品其它集数、视频文件、来源、影视资料和已看标记保留。同作品还有历史时显示最近一条剩余记录，历史全部移除后显示空态；取消菜单不会播放或删除。
- 观看历史及关联资料回归 **17 项通过**，包含两个长按入口、精确删除、空态、取消、保留文件和其它集数、跨设备应用删除标记；未连接线上同步服务实测。[历史测试日志](../artifacts/release-059-history-tests.log)。
- 字幕单元测试 **21 项通过**，覆盖语言标签、轨道格式、文字转换和 MKV 有界读取。[单元日志](../artifacts/release-059-subtitle-tests.log)。Linux 真实播放器回归 **5 项通过**：ASS/SRT 1 项、纯合成双轨 PGS 2 项、实际影片简体 PGS 样本 2 项。验证暂停显示、拖动、切轨、关闭恢复和自动转换不误触发；实际字幕样本封装到合成背景视频中，重复轨道用于简繁偏好切换，并未验证影片繁体轨的实际字形。[文字字幕日志](../artifacts/release-059-subtitle-text-native.log)、[合成 PGS 日志](../artifacts/release-059-pgs-native.log)、[实际样本日志](../artifacts/release-059-pgs-actual-native.log)。
- APK 校验新增逐 ABI 的 PGS 解码器符号检查，拒绝只有格式名称或未定义符号的库；旧 APK 按预期失败，新 full 库通过。Python 打包与签名检查 **10 项通过**，其中 4 项覆盖解码器检查。[打包测试](../artifacts/release-059-packaging-tests.log)。静态分析无错误或警告，保留 5 条既有风格 info。[分析日志](../artifacts/release-059-analyze.log)。
- 已构建含上述两项改动的 [0.5.9 ARM64 APK](../artifacts/aiplayer-0.5.9-android-arm64.apk)：51,291,314 字节、versionCode 15、Android API 24+。PGS 解码器、ZIP CRC、核心原生库、v1/v2/v3 签名、16 KB 对齐和 SHA256 通过，证书与 0.5.8 一致，可覆盖升级。[构建日志](../artifacts/release-059-arm64-build.log)、[APK 验证](../artifacts/build-android-arm64.json)、[签名连续性](../artifacts/release-059-signing-continuity.json)。最终变更文件静态分析仅有 1 条既有风格 info。[最终分析](../artifacts/release-059-final-analyze.log)。本轮未构建通用 APK 或其它平台发布包。
- 当前未连接 Android 真机，原生图片渲染测试在 Linux 运行；Android 包内解码器、签名及对齐已验证，仍需用户设备安装播放确认。

## 0.5.8+14 · 批量后台识别、底部面板与长期缓存 · 2026-10-22

- 移除来源长按菜单重复的 AI 入口，保留手动识别面板内的 AI 按钮；移除联合搜索说明。识别改为随内容收缩的底部面板，长列表滚动并避让键盘；批量候选可切换到具体视频，人工选取只作用于该视频。
- AI 文件名每批最多 20 个、解析并发最多 2 路；按作品 / 季度 / 类型 / 年份 / 是否分集分组，最多并行查询 3 个作品组。相同作品的各集共用搜索、官方详情及候选确认缓存，保留独立集号。受控测试验证请求次数与并发上限，未对真实 AI 供应商测量耗时。
- 普通识别、自动 AI 回退、手动 AI 和候选应用交给应用级任务管理；关闭面板或切页后继续，可从任务按钮重开或取消。未完成任务在本机持久保存，重启后按记录修订号恢复，避免覆盖手动更正。后台执行不保证操作系统强杀或挂起后继续联网。
- 成功搜索、作品身份、详情、季度、集名、目录、弹幕及海报不再按时间或总容量自动淘汰，翻译与视频规格缓存继续长期保留；浏览视频封面也取消 256 条淘汰。空结果与失败可重试，身份 / 配置变化仍使不适配结果失效。详情请求合并且独立取消，晚到的取消结果不写缓存。持久缓存 **46 项回归通过**，含真实磁盘重开离线复用与旧容量上限后的海报保留。[缓存日志](../artifacts/release-058-persistent-cache-tests.log)。
- 全量 Flutter 单元 / 组件测试 **392 项通过**。[全量日志](../artifacts/release-058-tests.log)。最终面板高度收紧后 **23 项 UI 回归通过**，含手机键盘、大字体、后台继续、重开、取消与逐视频候选范围。[UI 日志](../artifacts/metadata-bottom-sheet-widget.log)。静态分析无错误或警告，保留 5 条既有风格 info。[分析日志](../artifacts/release-058-analyze.log)。
- Linux 真实 Flutter 渲染 **1 项通过**，使用假目录资料生成[底部面板截图](../artifacts/metadata-bottom-sheet.png)及[模拟 300px 键盘占位截图](../artifacts/metadata-bottom-sheet-keyboard-inset.png)；后者不是真实手机系统键盘。检查后面板随 3 条候选收缩至约 420 逻辑像素，无固定大块留白。[原生日志](../artifacts/metadata-bottom-sheet-native.log)。本轮未在用户手机实机复验。

- 已构建 [0.5.8 ARM64 APK](../artifacts/aiplayer-0.5.8-android-arm64.apk)：47,539,084 字节、versionCode 14、Android API 24+。ZIP CRC、核心原生库、v1/v2/v3 签名、16KB 对齐和 SHA256 通过，证书与 0.5.7 一致。[构建日志](../artifacts/release-058-arm64-build.log)、[APK 验证](../artifacts/build-android-arm64.json)、[签名连续性](../artifacts/release-058-signing-continuity.json)。本轮未构建通用 APK、Linux 发布包、Apple / Windows 版本。

## 0.5.7+13 · 双源资料搜索、AI 文件名识别与视频规格 · 2026-10-22

- 默认同时搜索 Bangumi、TMDB 剧集及电影，按来源 / 类型 / ID 去重，跨源核对名称、季度和年份；来源失败相互隔离。移除设置和手动弹窗的资料来源选择，未配置 TMDB 凭证时仍可使用 Bangumi。
- 新增默认关闭的「AI 自动识别信息」：普通识别失败后解析文件名、多语言作品名、类型、季度和集数，联合搜索后只从真实候选中确认；低置信度、歧义、季度冲突或过宽候选保留手动选择。来源菜单和匹配弹窗提供手动「AI 自动识别」。仅发送 basename 与候选资料，不发送视频或播放地址。
- 17 项 AI 编排回归覆盖开关关闭、普通识别优先、逐文件独立集数、未确认不写入、手动更正与配置变化后的迟到结果、取消、错误季度及迟到集名保护。AI 响应使用受控替身，未联调真实供应商。
- 单视频和列表显示已识别作品名、季度和集数；默认省略未知多季数或只有一季作品的第 1 季，保留特别篇与后续季度。文件规格按视频版本缓存在本机，播放后补全实测容器、编码和宽高；码率有实测值时显示约数，未知则省略。未探测的视频只显示可知格式 / 大小，文件名清晰度标为「文件名标注」。
- Linux 真实 mpv 集成 2 项通过，实际验证 Matroska、H.264、640×360、时长和文件大小缓存；未对码率非空作实机断言，码率正值保存及未知省略由单元测试覆盖。[集成输出手工转录](../artifacts/release-057-player-native.log)。未在用户手机实机复验。
- 全量 Flutter 单元 / 组件测试 **361 项通过**；最后的手动弹窗状态修订后，AI 工作流与联合搜索 **28 项复验通过**。[全量日志](../artifacts/release-057-tests.log)、[定向日志](../artifacts/release-057-ai-final.log)。静态检查无错误或警告，保留 6 条既有代码风格 info。[分析日志](../artifacts/release-057-analyze.log)。

- 已构建 [0.5.7 ARM64 APK](../artifacts/aiplayer-0.5.7-android-arm64.apk)：47,473,314 字节、versionCode 13、Android API 24+。ZIP CRC、核心原生库、v1/v2/v3 签名、16KB 对齐和 SHA256 通过，证书与 0.5.6 一致。[构建日志](../artifacts/release-057-arm64-build.log)、[APK 验证](../artifacts/build-android-arm64.json)、[签名连续性](../artifacts/release-057-signing-continuity.json)。本轮未构建通用 APK、Linux 发布包、Apple / Windows 版本。

## 0.5.6+12 · 全面屏与详情修订、海报缓存和共享排序 · 2026-10-22

- 复现截图中播放列表的多余留白：弹窗布局已避让安全区，Flutter `ListTile` 内部 `SafeArea` 又叠加单侧刘海；新增回归在旧实现得到 67px 左距，修复后 16px。播放器顶部、进度条、底部菜单与锁定按钮统一使用左右较大安全区留出对称边距，避免重复横向避让。
- Linux 真实 mpv / Flutter 模拟左右刘海的集成通过：安全区 59/24px 及镜像 24/59px 时，控件左右均为 75px，播放列表文字距框 16px，主要按钮可点击。[原生日志](../artifacts/release-056-player-safe-area-native.log)、[布局截图](../artifacts/player-safe-area-right.png)、[组件回归](../artifacts/release-056-player-safe-area-widget.log)。未在用户手机实机复验。
- 设置保存成功统一使用圆角小气泡、2 秒消失且替换旧提示；浅 / 深色关闭开关增加可见轨道、滑块和轮廓。标题翻译移到简介翻译右侧，窄屏换行；移除字幕、标题、简介翻译确认弹窗；识别作品后的来源详情隐藏重复目录名，目录菜单保留完整路径。
- 海报改为本机持久缓存，影视库、来源、收藏和详情共用；真实本地 HTTP 测试验证同 URL 合并请求、最大 4 路并发、重启离线命中、无效内容不入缓存、容量淘汰及失败释放。截图和缓存不上传。
- 排序菜单新增「应用到所有文件夹」，本地与远程目录、影视库作品详情共用；已有目录更新，新目录继承，单目录之后仍可覆盖，字幕显隐保留。真实磁盘重启与 A/B 作品详情继承测试通过。
- 复现继续观看横向列表读到外层纵向滚动位置，导致回到顶部后跳至最右。为横向列表提供独立 PageStorageKey；初始位置与用户手动横滑位置两种场景均保持正确。
- 全量 Flutter 单元 / 组件测试 **314 项通过**。[测试日志](../artifacts/release-056-tests.log)。静态检查无错误或警告，保留 6 条既有代码风格 info。[分析日志](../artifacts/release-056-analyze.log)。真实 AI 供应商未联调。
- 构建 [0.5.6 ARM64 APK](../artifacts/aiplayer-0.5.6-android-arm64.apk)：47,342,084 字节、versionCode 12、Android API 24+。ZIP CRC、核心原生库、v1/v2/v3 签名、16KB 对齐和 SHA256 通过，证书与 0.5.5 一致。[构建日志](../artifacts/release-056-arm64-build.log)、[APK 验证](../artifacts/build-android-arm64.json)、[签名连续性](../artifacts/release-056-signing-continuity.json)。本轮未构建通用 APK、Linux 发布包、Apple / Windows 版本。

## 0.5.5+11 · 拖动预览、标题翻译与设置整理 · 2026-10-22

- 修复持续拖动反复废弃取帧和界面仅接受完全匹配位置所导致的转圈。独立解码按队列显示完成帧并追上最新位置，单次超时进入不可用状态，失败退避、反向拖回已缓存位置、慢释放后的新拖动、取消与迟到结果均有回归。
- 完整 Flutter 单元 / 组件测试 **302 项通过**，包含新增标题批量响应校验、取消、缓存与原文切换，以及设置搜索、独立保存和紧凑布局。[全量日志](../artifacts/release-055-tests.log)。全工程静态检查无错误 / 警告，保留 6 条既有代码风格 info。[分析日志](../artifacts/release-055-analyze.log)。
- Linux 真实 mpv 播放器回归通过：预览截图、播放列表文字距左边框不超过 20px、控件稳定、全屏、快捷键与立即退出。[播放器日志](../artifacts/release-055-player-test.log)、[预览画面](../artifacts/player_seek_preview.png)。
- 独立预览集成 **2 项通过**：持续 2 秒、每 50ms 更新目标期间生成 9 张不同帧，最终目标正确且未定位前台播放器；非本地适配器经真实 RangeBridge 读取、空闲回收、重开及取帧中关闭通过。[预览日志](../artifacts/release-055-seek-integration.log)。这是本地受控来源，不代表用户 NAS 与所有手机均已验收。
- 标题翻译使用现有 AI 配置，详情页支持作品名和已有单集标题批量翻译、取消及原文切换；译文仅作本机显示缓存，不改匹配或文件名。影视库、来源详情与播放器共用显示。AI 测试使用受控响应，未调用真实供应商。
- 设置收敛为常规、播放、字幕、弹幕、AI 翻译、同步、关于七类；手势 / 快捷键归入播放，弹幕连接归入弹幕，日志从关于进入；移除空卡片与重复声明，弹幕 / 同步配置独立保存。
- 已构建 [0.5.5 ARM64 release APK](../artifacts/aiplayer-0.5.5-android-arm64.apk)：47,341,960 字节、versionCode 11、Android API 24+。ZIP CRC、核心原生库、v1/v2/v3 签名、16KB 对齐与 SHA256 通过；证书与 0.5.4 一致。[构建日志](../artifacts/release-055-arm64-build.log)、[APK 验证](../artifacts/build-android-arm64.json)、[签名连续性](../artifacts/release-055-signing-continuity.json)。本轮未重新执行 Android 实机安装，未构建通用 APK、Linux 发布包或 Apple / Windows 版本。

## 0.5.4+10 · 字幕展开修复、弹幕预设与 ARM64 发布 · 2026-10-21

- 已复现「字幕翻译要求」展开时报 `type 'bool' is not a subtype of type 'double?'`：ExpansionTile 的展开状态与内部 TextField 的滚动位置共用 PageStorage 标识。给输入框独立标识并明确展开宽度后，横屏 / 竖屏、1.6 倍字体、长文本、反复收起展开及保存测试通过。
- 从用户指定的 `openlist-enhancer/src/data/danmaku-filter-preset.json` 完整导入 2251 个关键词、1 条正则，逐项核对一致。内置预设默认开启，可单独关闭；自定义屏蔽词保持独立。关键词采用带失败链接的字典树，避免大批弹幕逐词扫描；1 万条本机样本约 29 ms（Dart 测试环境结果，不代表手机帧耗时）。[预设校验](../artifacts/release-054-preset-validation.json)。
- 33 项定向回归测试通过；关键词匹配优化后，4 项过滤测试再次通过，其中新增 1000 组确定性样本与朴素字符串匹配对照。[定向测试](../artifacts/release-054-targeted-tests.log)、[过滤测试](../artifacts/release-054-filter-tests.log)。相关文件静态检查无问题；全工程检查另有 6 条既有代码风格提示，无编译错误。[相关静态检查](../artifacts/release-054-changed-analyze.log)、[过滤静态检查](../artifacts/release-054-filter-analyze.log)、[全工程检查](../artifacts/release-054-analyze.log)。本轮未重新运行实机或模拟器集成测试。
- 原 `/tmp/aiplayer-sdk`、`/tmp/aiplayer-cache` 已不存在，常见本机位置及备份目录未找到旧签名密钥。按用户确认生成新签名并保存至项目 `.local-build/signing/debug.keystore`，权限 0600；APK 证书指纹已与该密钥核对一致，并确认与旧版签名不同。旧版需先同步或备份数据，再卸载安装。SDK、依赖缓存及临时工作目录均固定在项目 `.local-build/`；后续运行 `bash scripts/package_android_arm64.sh`，密钥缺失会停止，不会自动更换签名。
- 仅构建 [0.5.4 ARM64 APK](../artifacts/aiplayer-0.5.4-android-arm64.apk)，47,342,261 字节，versionCode 10，只有 `arm64-v8a`，最低 Android API 24。ZIP CRC、重复条目、核心原生库、v1/v2/v3 签名、16KB 对齐及 SHA256 全部通过。[构建日志](../artifacts/release-054-arm64-build.log)、[验证报告](../artifacts/build-android-arm64.json)、[校验文件](../artifacts/SHA256SUMS-android-arm64)。Telegram 交付目录仅复制这一份 APK，不含密钥或其他架构。

## 0.5.2+8 · Android release 打包 · 2026-10-22

本轮仅将版本更新为 `0.5.2+8` 并按 `scripts/package.py android` 生成 Android 通用 release APK，功能代码与下方播放器修订一致，沿用原签名。发布产物：[0.5.2 通用 APK](../artifacts/aiplayer-0.5.2-android.apk)、[构建与 APK 验证记录](../artifacts/build-android.json)、[SHA256 校验文件](../artifacts/SHA256SUMS-android)。已核对版本、三个 ABI、ZIP CRC、v1/v2/v3 签名、16KB 对齐及 SHA256；证书指纹与旧发布版一致。发布构建使用原有 `XDG_CONFIG_HOME=/tmp/aiplayer-cache/config` 签名环境。本轮未重新运行 229 项 Flutter 测试或 Android / Linux 集成测试，未重新构建 ARM64 小包与 Linux 包；下方保留此前实际验证结果。

## 历史记录 · 0.5.1+7 播放器与资料界面追加验证 · 2026-10-22

这轮源码保留版本号 `0.5.1+7`。播放器全屏不再创建额外路由，切集保留原生窗口；提示气泡独立刷新，控件节点保持稳定。影视库与来源共用资料头部及作品集数统计，支持长按主动识别/手动搜索、简介翻译。下面为该轮实际执行结果。

- 全量 Flutter 单元/组件测试 **229 项通过**，`flutter analyze --no-pub` 无问题。[测试日志](../artifacts/player-ui-tests-20261022.log)、[静态检查](../artifacts/player-ui-analyze-20261022.log)。
- Linux 真实 mpv 集成通过：画面适配及提示气泡显隐不重建工具栏、不重新播放入场动画；按钮分组位置、播放列表锚定弹窗和暗色主题、全屏往返、嵌套设置、键盘及即时返回。实际画面：[播放器](../artifacts/player_glass.png)、[播放器设置](../artifacts/player_settings.png)、[日志](../artifacts/player-ui-linux-20261022.log)。
- Android 11/API30 模拟器通过：默认横屏全屏；全屏按钮往返保留 Video 状态和视频方向；下一集、上一集保留同一个 PlayerPage，方向变化记录中未出现竖屏；竖视频切换为竖屏；一次返回离开播放器。[日志](../artifacts/player-ui-android-20261022.log)。
- 资料回归覆盖同目录未播放集数补齐、跨入口统计、重复编码去重计集、不同作品身份隔离、人工匹配保护、自动识别关闭后主动识别、已移除源文件不被自动重新收录，以及来源文件夹/本地与远程视频长按搜索入口。
- AI 回归使用受控服务响应，覆盖模型加载/搜索/选择、服务切换取消旧请求、安全保存、简介最小请求与取消、缓存和原文切换。手机/电视实机、真实 AI 服务、iOS/Windows 原生画面未在本轮验收。
- 已生成 [Android 通用测试包](../artifacts/aiplayer-0.5.1-player-ui-android.apk)，保留 `0.5.1+7` 版本号。后续发布核对发现该中间包使用了另一份本机证书，0.5.2 已恢复旧发布版签名；该中间包不再作为发布入口。三个 ABI、ZIP CRC、v1/v2/v3 签名和 16KB 对齐全部通过；同一 Android 11 模拟器已原位安装成功并冷启动（[安装日志](../artifacts/player-ui-install-20261022.log)）。[验证报告](../artifacts/player-ui-apk-validation-20261022.json)、[SHA256](../artifacts/player-ui-20261022.sha256)。此前 Linux 发布压缩包未重新打包。

Android 方向回归复现（需已连接设备，`ffmpeg` 在 PATH 中）：

```bash
python3 scripts/make_orientation_fixture.py
cd client
flutter test --no-pub integration_test/player_orientation_test.dart -d <Android设备ID> \
  --dart-define-from-file=/tmp/aiplayer-orientation-fixture/defines.json
```

## 历史记录 · 0.5.0+6

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

### Cross-platform performance regression checks

The Flutter paths shared by Android, iOS, macOS, Windows and Linux now defer
library repair until after the first frame, reuse prepared SQLite statements,
ignore unchanged local writes, cache preferences by settings revision, and use
indexed local-key prefix queries. Scans reuse metadata donors until an external
edit changes the media revision and persist bindings/automatic queues per batch.
Directory snapshots retain their sort result across unrelated notifications.

Artwork downloads share an HTTP connection pool with four active requests;
each timeout only aborts its own request. In-memory path/failure maps are bounded
without evicting successful disk artwork. Large JSON responses and large comment
normalization/cache serialization run in isolates. Unchanged comment refreshes
skip serialization and disk writes. Quiet synchronization pauses in the
background; automatic metadata tasks pause between groups while backgrounded or
playing, preserve completed work, and allow explicit manual tasks to proceed.

Run the focused regressions with the repository's pinned Flutter SDK:

```sh
cd client
flutter test test/store_performance_test.dart test/store_revision_test.dart \
  test/scan_performance_test.dart test/source_settings_scroll_performance_test.dart \
  test/poster_cache_test.dart test/json_work_test.dart test/danmu_test.dart \
  test/app_model_realtime_test.dart test/metadata_background_tasks_test.dart \
  test/metadata_history_test.dart
```

These checks assert event-loop responsiveness, connection reuse, bounded work,
cache invalidation, rollback and lifecycle correctness instead of unreliable
wall-clock speed thresholds. Device-level cold-start time, frame percentiles,
peak memory and battery use still require profile/release measurements on real
Android/iOS devices and desktop hardware; no percentage speedup is claimed.
