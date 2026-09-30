# App 图标

`YamiboX/AppIcon.icon` 是分层图标源文件，可直接用 Icon Composer 打开。

- 背景：原图深棕色的代表值 `#521C0A`，不预绘圆角或玻璃覆盖层。
- 原始矢量：`Assets/lily.svg`，从原始 PNG 自动描摹的完整百合花。它是拆分的基准，不直接加入渲染组。
- 前景：六个 `Assets/petal-*.svg` 花瓣和 `Assets/stamens.svg` 花蕊，直接拆出原始矢量中的子轮廓，使用原来的 1024 × 1024 坐标，不重新拟合、不缩放、不平移。
- 材质：由 Icon Composer / 系统施加高光、分层阴影和 iOS 27 轻微折射。前景不启用额外半透明或模糊，保留米白颜色和图案辨识度。

## 立体层次

Icon Composer 文档里的组按前到后排列，使用三个深度组（少于 Apple 的四组上限）：

1. `03 Stamens - front`：花蕊，整体受光，阴影不透明度 55%。
2. `02 Petals - middle`：左上、右上、下方花瓣，每片独立受光，阴影不透明度 40%。
3. `01 Petals - back`：顶部、左下、右下花瓣，每片独立受光，阴影不透明度 30%。

高光保持 Automatic；折射强度为 10%–15%、高度为 6%–8%，花蕊使用 12%/6%。这些是本图标的克制材质设置，不是 Apple 要求的固定值。背景独立于前景组，无须额外制作玻璃图片。

拆分保留花瓣内的细缝、花蕊周围所有微小轮廓，不增加可见重叠、不填平镂空，也不补绘隐藏形状。立体感来自原轮廓上的材质和三个组的空间层次，而不是改变花朵设计。若后续需要更强的透镜重叠效果，应另行确认是否允许调整内部遮挡关系。

iOS 27 使用新高光和折射渲染；早于 27 的系统忽略折射，仍可呈现分层高光与阴影。用 `--design-generation 26` 预览旧渲染，不代表已在旧版系统完成设备验证。

Xcode 工程把 `.icon` 加入资源构建，三个配置继续使用 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`。Xcode 为旧系统生成兼容静态图标。原有 `AppIcon.appiconset/AppIcon-1024.png` 保持不变，保留 README 和发布源的图片地址；启动画面素材也不变。

“关于”页的交互图标使用下面的独立立体几何，不把桌面图标的高光烘焙在正面贴图里。它始终展示默认棕底图标，不随 App 的深色模式切换到近黑底；主屏幕图标仍由系统按用户选择的外观渲染。普通图片资源 `AppIconPreview` 仅作为几何资源缺失时的备用正面，此处强制读取其默认外观。不要通过 `UIImage(named: "AppIcon")` 读取多组图标栈：iOS 27 的 UIKit 会抛出 `Need an imageRef` 异常。桌面仍由系统实时渲染 `.icon`。

## App 内交互图标

交互图标采用有光泽的 Blinn 材质，背板与正面花朵使用较集中的柔和高光，侧壁光泽略柔和。受限强度的纯灰白软箱反射、主光、补光与背部轮廓光随旋转产生反光和明暗变化；不修改现有棕色背板、乳白花朵和侧壁的 diffuse RGB，也不烘焙高光或改变原花形。镜面高光与环境反射独立控制，避免背板大面积泛白。

`AboutInteractiveIcon` 保留实体圆角基底，使用同一组原始贝塞尔路径建立六片花瓣和花蕊的七个 `SCNShape`：

- 后层花瓣挤出厚度 0.045，中层花瓣 0.09，花蕊 0.135（基底宽度为 2 个场景单位）。
- 各层从基底正面开始挤出，具有真实侧壁，不是悬浮图片；方向光产生实时遮挡阴影，侧壁使用略深的米色材质。
- 使用正交相机，使不同厚度的正面轮廓保持原来的比例和坐标。路径使用偶奇填充规则，保留镂空，不削蚀花瓣边缘。
- 点击图标任意部位均有中等触感反馈（强度 0.65），中心只震动、不旋转；点击左右边缘，第一次轻摆，第二次点击任一左右边缘沿对应方向转一周，再略微越过正面并阻尼回稳。转圈期间的点击不会叠加动作。
- 点击上下边缘只轻摆；从上下边缘开始垂直拖动可以翻动图标，松手回稳。中心区域的垂直手势仍交给页面滚动，水平拖动仍可旋转。
- 边缘按实际三维模型命中位置划分，中心为局部坐标绝对值均小于 0.55 的区域；点击上下边缘或拖动会重置两次点击的计数。减少动态效果关闭点击动画；切换亮暗外观不会改变实体背板的棕色。

运行拆分脚本时，同时生成 `Sources/YamiboXUI/Resources/AboutIconGeometry.json`。UI target 通过 `Bundle.module` 加载经过校验的结构化路径；运行时不解析 SVG，也不依赖 Icon Composer 私有 API。更改路径或组顺序后应重新生成资源并构建。桌面 Liquid Glass 与 App 内 SceneKit 是两种独立渲染：共享花形，但不声称材质效果逐像素相同。

## 重现矢量描摹

在仓库根目录运行，工具依赖仅装到临时目录，不加入 App 依赖：

```sh
npm install --prefix /tmp/yamibox-icon-tracing --no-save --ignore-scripts \
  potrace@2.1.8 pngjs@7.0.0 @resvg/resvg-js@2.6.2 \
  @xmldom/xmldom@0.9.12 svg-path-parser@1.1.0
NODE_PATH=/tmp/yamibox-icon-tracing/node_modules node scripts/trace-app-icon.cjs
NODE_PATH=/tmp/yamibox-icon-tracing/node_modules node scripts/split-app-icon.cjs
bash scripts/render-app-icon.sh
```

脚本从原 PNG 的前景覆盖率提取轮廓，在 4 倍采样下拟合贝塞尔曲线，保留镂空，不删除细小轮廓。输出使用原图的代表性米白色 `#F4EDE4`，而不是复现 PNG 中的细微像素色差。

脚本会将 SVG 重新栅格化，与原图的半覆盖率轮廓比对；轮廓交并比低于 99.5%，或出现超出原边缘 1 像素邻域的差异时拒绝输出。当前交并比为 99.8247%，差异像素 567 个，全部在边缘邻域内。矢量拟合并非逐像素无损转换，这个数值不包含系统额外渲染的高光与阴影。

拆分脚本使用 XML 和 SVG 路径解析器，不重新描摹。它在 1024 和 2048 像素下将七个前景重新组合，与完整 `lily.svg` 的 RGBA 输出逐像素比对；任何差异都会拒绝生成。当前两种尺寸的差异均为零。更换原图后需要重新审核子轮廓与图层的对应关系，脚本不会自动猜测新花瓣的结构。

只在 Icon Composer 中调整桌面材质后，无须重新描摹；运行 `bash scripts/render-app-icon.sh` 同步两个备用预览即可。这不会改变交互图标的实时材质。导出的圆角只用于备用预览，不会重新导入作为前景。

## 查看系统渲染

```sh
"$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool" \
  YamiboX/AppIcon.icon --export-image --output-file /tmp/yamibox-icon.png \
  --platform iOS --rendition Default --width 1024 --height 1024 --scale 1 \
  --design-generation 27
```

将 `Default` 换为 `Dark`、`TintedDark`、`ClearLight` 或 `ClearDark` 可检查对应外观，将渲染代数改为 `26` 可检查兼容外观。这些输出是预览，不应作为带圆角和烘焙高光的前景素材重新导入。

参考：[Apple App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)、[Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)、[WWDC26 Icon Composer](https://developer.apple.com/videos/play/wwdc2026/8012/)。
