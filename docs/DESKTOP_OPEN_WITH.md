# 从桌面打开视频

Linux `.deb` 安装桌面入口，声明 MP4、MKV、WebM、AVI、MOV、M4V、TS、FLV、WMV 文件类型。文件管理器的「打开方式」可选择映库。入口使用 `aiplayer %U` 传递文件路径或文件 URI；GTK runner 已将参数交给 Dart。压缩包可直接运行 `./launch.sh "/path/视频.mkv"`，如需桌面入口应将 `Exec`、`TryExec` 改为解压后可执行文件的绝对路径，再由用户安装入口。

Windows 解压包带 `register-open-with.ps1`。在包目录运行 `powershell -File .\register-open-with.ps1`，可将应用加入当前用户的「打开方式」候选；如系统执行策略不允许，请按本机管理规则处理，也可直接在打开方式中浏览选择 `aiplayer.exe`。脚本不需要管理员权限，不设置默认播放器，不修改受保护的 `UserChoice`；`-WhatIf` 可先查看意图，`-Remove` 移除本脚本登记的候选项。移动应用目录后需要重新执行脚本。Windows runner 已将命令行参数交给 Dart。

本轮在 Linux 检查桌面入口及参数转发；Windows 登记脚本尚待 Windows 实机验证。

实现依据：[Desktop Entry Specification](https://xdg.pages.freedesktop.org/xdg-specs/desktop-entry/latest-single/) 的 `Exec`／`MimeType`，[Microsoft 应用注册](https://learn.microsoft.com/en-us/windows/win32/shell/app-registration) 的 `SupportedTypes` 与 `OpenWithProgids`。
