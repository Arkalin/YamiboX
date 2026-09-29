# App 图标

`YamiboX/AppIcon.icon` 是分层图标源文件，可直接用 Icon Composer 打开。

- 背景：原图深棕色的代表值 `#521C0A`，不预绘圆角或玻璃覆盖层。
- 前景：`Assets/lily.svg`，从原始 PNG 自动描摹的完整百合花，使用原来的 1024 × 1024 坐标，不缩放、不平移、不重新设计花瓣或花蕊。
- 材质：由 Icon Composer / 系统施加高光和轻微阴影。前景不启用额外半透明，保留图案辨识度。

花朵作为一个完整前景层保留，避免人为拆分改变原图的镂空和遮挡关系。背景加一个前景层已经满足分层方案，无须额外制作玻璃图片。

Xcode 工程把 `.icon` 加入资源构建，三个配置继续使用 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`。Xcode 为旧系统生成兼容静态图标。原有 `AppIcon.appiconset/AppIcon-1024.png` 保持不变，保留 README 和发布源的图片地址；启动画面素材也不变。

## 重现矢量描摹

在仓库根目录运行，工具依赖仅装到临时目录，不加入 App 依赖：

```sh
npm install --prefix /tmp/yamibox-icon-tracing --no-save --ignore-scripts \
  potrace@2.1.8 pngjs@7.0.0 @resvg/resvg-js@2.6.2
NODE_PATH=/tmp/yamibox-icon-tracing/node_modules node scripts/trace-app-icon.cjs
```

脚本从原 PNG 的前景覆盖率提取轮廓，在 4 倍采样下拟合贝塞尔曲线，保留镂空，不删除细小轮廓。输出使用原图的代表性米白色 `#F4EDE4`，而不是复现 PNG 中的细微像素色差。

脚本会将 SVG 重新栅格化，与原图的半覆盖率轮廓比对；轮廓交并比低于 99.5%，或出现超出原边缘 1 像素邻域的差异时拒绝输出。当前交并比为 99.8247%，差异像素 567 个，全部在边缘邻域内。矢量拟合并非逐像素无损转换，这个数值不包含系统额外渲染的高光与阴影。

## 查看系统渲染

```sh
"$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool" \
  YamiboX/AppIcon.icon --export-image --output-file /tmp/yamibox-icon.png \
  --platform iOS --rendition Default --width 1024 --height 1024 --scale 1
```

将 `Default` 换为 `Dark` 或 `TintedDark` 可检查对应外观。这些输出是预览，不应作为带圆角和烘焙高光的前景素材重新导入。

参考：[Apple App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)、[Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)。
