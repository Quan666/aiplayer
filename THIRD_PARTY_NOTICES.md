# 第三方组件

- Flutter：BSD-3-Clause；客户端 SDK 固定为 3.47.7。
- media_kit：MIT；使用其发布的 mpv / FFmpeg 原生构建。分发这些二进制时须保留其随包许可证与对应源码信息；不能将包的 MIT 许可证视为底层所有组件的许可证。
- libsmb2：LGPL-2.1-or-later，源码以 `57fea04fd29403e3978000179339c8e13ce46b5c` 为基线，包含共享枚举时保留 SMB 错误状态的本地修正，位于 `packages/aiplayer_smb/src/vendor/libsmb2`，许可证随上游源码保留。FFI 桥接仅提供读取操作，关闭了 Kerberos、DCE/RPC、QUIC 和 RDMA 可选组件。
- Noto Sans SC：SIL Open Font License 1.1，字体及许可证位于 `client/assets/fonts`。
- OpenCC 1.1.9：Apache License 2.0。繁简转换使用上游 `ver.1.1.9`（提交 `556ed22496d650bd0b13b6c163be9814637970ae`）的 `TSCharacters.txt` / `TSPhrases.txt` 字典，来源 [BYVoid/OpenCC](https://github.com/BYVoid/OpenCC)。原始许可证、词典及来源校验信息位于 `client/assets/opencc`，未修改词典内容。
- SQLite 与 Go SQLite 驱动：见依赖锁定文件及对应上游许可证。
- danmu_api 请求、名称识别、匹配、缓存及刷新行为参照本机 `openlist-enhancer` 插件；Dart 实现不依赖浏览器扩展环境。
- 弹幕屏蔽预设完整导入用户指定的 `openlist-enhancer/src/data/danmaku-filter-preset.json`（2026-10-12，2251 个关键词、1 条正则），原始来源为用户提供的 `FilterSettings.xml`。来源校验值保存在 `client/lib/danmaku/filter_preset.dart`；预设默认启用，可独立关闭，自定义屏蔽词另行保留。

本项目目前按自用工程交付。公开分发前应按实际打包产物整理完整组件清单、对应许可证和源码提供方式。

## TMDB metadata attribution

Optional TV/movie metadata uses The Movie Database API. This product uses the TMDB API but is not endorsed or certified by TMDB. User-provided API credentials are stored only in device secure storage.

The approved TMDB logo in `client/assets/branding/tmdb.png` is rasterized, preserving its original colors and aspect ratio, from the [official primary short blue logo](https://www.themoviedb.org/assets/2/v4/logos/v2/blue_square_2-d537fb228cf3ded904ef09b136fe3fec72548ebc1fea3fbbd1ad9e36364db38b.svg). TMDB retains its trademarks. See [TMDB attribution requirements](https://developer.themoviedb.org/docs/faq) and [logos and attribution](https://www.themoviedb.org/about/logos-attribution).
