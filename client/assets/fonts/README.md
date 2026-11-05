# Noto Sans SC

`NotoSansSC-Regular.ttf` 保留原有 100–900 可变字重范围，默认字重改为 400；字体名称及 `OS/2.usWeightClass` 也对应 Regular。原文件虽命名为 Regular，内部实际为 Noto Sans SC Thin，默认字重为 100。

Android 6 兼容版使用 Flutter 3.32.8。该版本不会自动把 `TextStyle.fontWeight` 应用到可变字体的 `wght` 轴，默认 Thin 轮廓会使小字号文字过细。默认字重修正不依赖运行时逐段文字处理，现代引擎仍可使用完整字重范围。[Flutter 字重行为变更](https://docs.flutter.dev/release/breaking-changes/font-weight-variation)

使用原有字体资源及 FontTools 4.60.1 离线重定位默认轴：

```bash
python3 -m fontTools.varLib.instancer original.ttf wght=100:400:900 \
  --update-name-table --no-recalc-timestamp --output NotoSansSC-Regular.ttf
```

- 原文件 SHA-256：`a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da`
- 修正后 SHA-256：`93758a0d713f3a4c7e40f8e20ecd72101d01c33566a3b571f5f520d2fc839e41`

继续遵守同目录 `OFL.txt`。字重修正不会改变 Android 系统为应用提供的渲染分辨率；电视端清晰度仍需在实际设备上验证。
