# App 图标维护

桌面图标以 [AppIcon.icon](../../YamiboX/AppIcon.icon) 为分层源文件，用 Icon Composer 打开；“关于”页使用共享花形的 SceneKit 几何。两种渲染路径独立，不要求材质逐像素相同。

## 资产来源与构建入口

| 文件 | 用途 |
| --- | --- |
| [原始 PNG](../../YamiboX/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png) | 描摹输入；README 与发布源仍引用这张图 |
| [lily.svg](../../YamiboX/AppIcon.icon/Assets/lily.svg) | 从原始 PNG 提取的完整百合花轮廓，作为拆分基准，不直接加入桌面渲染组 |
| `AppIcon.icon/Assets/petal-*.svg`、`stamens.svg` | 六片花瓣与花蕊，保留 1024 × 1024 原坐标及镂空 |
| [icon.json](../../YamiboX/AppIcon.icon/icon.json) | 图层、顺序、背景和材质配置；由 Icon Composer 编辑 |
| [AboutIconGeometry.json](../../Sources/YamiboXUI/Resources/AboutIconGeometry.json) | 拆分脚本生成的 App 内路径与挤出厚度，通过 UI 的 `Bundle.module` 加载 |
| [AppIconPreview.imageset](../../YamiboX/Assets.xcassets/AppIconPreview.imageset) | 桌面图标导出的普通浅色/深色图片，作为 App 内备用正面 |
| [LaunchIcon.imageset](../../YamiboX/Assets.xcassets/LaunchIcon.imageset) | 独立启动画面素材，不由图标脚本更新 |

[Xcode 工程](../../YamiboX.xcodeproj/project.pbxproj)把 `.icon` 加入 Resources，三个配置的 `ASSETCATALOG_COMPILER_APPICON_NAME` 都是 `AppIcon`。不要只改 appiconset 或预览图片，遗漏实际桌面源文件。

现有花形来源是上述仓库 PNG，转换脚本不构成新的绘制来源，也不改变素材授权。替换外部图形时应保存来源、作者和适用许可，不从项目代码许可证推断第三方素材可自由使用；项目许可与上游致谢见 [LICENSE](../../LICENSE) 和 [README](../../README.md#许可与致谢)。

## 图层与 App 内渲染约束

背景为深棕色 `#521C0A`，前景代表色为米白 `#F4EDE4`。源资产不预绘圆角或玻璃覆盖层。Icon Composer 的组按前到后排列：花蕊、三片中层花瓣、三片后层花瓣。高光、阴影及折射由 `icon.json` 和系统渲染，不通过修改花形制造材质。

[AboutIconGeometry](../../Sources/YamiboXUI/Features/Settings/About/AboutIconGeometry.swift)校验 JSON 后构建偶奇填充的贝塞尔路径；[AboutInteractiveIcon](../../Sources/YamiboXUI/Features/Settings/About/AboutInteractiveIcon.swift)负责挤出、材质、灯光、旋转与减少动态效果。几何生成依据桌面组顺序反向生成后到前层，运行时不解析 SVG。

“关于”页固定展示默认棕底，深色界面不会切换实体背板。几何缺失时使用普通预览图片；[AboutView](../../Sources/YamiboXUI/Features/Settings/About/AboutView.swift)优先加载 `AppIconPreview` 的浅色外观。不要通过 `UIImage(named: "AppIcon")` 读取多组 `.icon` 栈，它不是普通 UIImage 资源。

## 按变更选择生成步骤

所有命令从仓库根目录执行。需要 Node.js；拆分脚本使用 `Array.toReversed()`，应使用支持它的运行时。描摹工具不属于 App 的 Package 依赖，只安装在临时目录。

```sh
npm install --prefix /tmp/yamibox-icon-tracing --no-save --ignore-scripts \
  potrace@2.1.8 pngjs@7.0.0 @resvg/resvg-js@2.6.2 \
  @xmldom/xmldom@0.9.12 svg-path-parser@1.1.0
```

| 变更 | 执行步骤 |
| --- | --- |
| 原始 PNG 改变 | 描摹，审核轮廓到图层映射，再拆分和导出预览 |
| 直接修改完整 `lily.svg` | 审核轮廓映射，再拆分和导出预览；不从旧 PNG 重新描摹覆盖修改 |
| Icon Composer 组顺序改变 | 拆分并重新生成 App 内几何，再导出预览 |
| 只调整桌面材质 | 仅导出预览，不重新描摹，也不修改 App 内实时材质 |
| App 内灯光、材质或交互改变 | 修改 UI 实现并验证“关于”页，不重新生成花形 |

```sh
NODE_PATH=/tmp/yamibox-icon-tracing/node_modules node scripts/trace-app-icon.cjs
NODE_PATH=/tmp/yamibox-icon-tracing/node_modules node scripts/split-app-icon.cjs
bash scripts/render-app-icon.sh
```

这些命令会写入源资产和生成资源，不是只读检查。运行前确认所需步骤，运行后检查差异：

- [描摹脚本](../../scripts/trace-app-icon.cjs)要求输入为 1024 × 1024 PNG；使用原图前景覆盖率进行 4 倍采样拟合。轮廓交并比低于 99.5% 或出现超出一像素边缘邻域的差异时拒绝写入 `lily.svg`。这是轮廓近似门槛，不是逐像素无损承诺。
- [拆分脚本](../../scripts/split-app-icon.cjs)解析 XML 和 SVG 路径，不重新拟合。现有映射要求 24 个子轮廓，并在 1024、2048 两种尺寸下检验重新组合后的 RGBA 完全一致。更换花形后必须人工审核映射，不能删除失败检查来强行生成。
- [预览脚本](../../scripts/render-app-icon.sh)调用当前 Xcode 的 `ictool`，以渲染代数 27 导出 `Default`、`Dark` 两张 1024 像素图片到 `AppIconPreview.imageset`。仅变更 `.icon` 后不会自动运行此脚本。

图层拆分或顺序改变后提交相应 SVG、`icon.json`、几何 JSON 和预览中实际变化的文件；不要无差别重写启动素材和原始 PNG。

## 预览与系统渲染检查

`ictool` 随当前 Xcode 的 Icon Composer 提供，使用前可通过 `--help` 核对参数。下面只向临时目录导出预览：

```sh
"$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool" \
  YamiboX/AppIcon.icon --export-image --output-file /tmp/yamibox-icon.png \
  --platform iOS --rendition Default --width 1024 --height 1024 --scale 1 \
  --design-generation 27
```

将 `Default` 换为 `Dark`、`TintedDark`、`ClearLight` 或 `ClearDark` 检查对应外观；`--design-generation 26` 用于检查前一代渲染。预览代数不是运行设备版本，也不能证明旧系统设备兼容。带圆角与高光的预览不得重新导入为前景素材。

图标改动的交互检查只安装签名 Local App，按[本地启动参数](../tests/launch-arguments.md)传入论坛地址。分别查看主屏幕图标和“关于”页：轮廓、细缝和花蕊应完整，浅色/深色外观不混淆桌面与 App 内材质，旋转后应回稳，减少动态效果被尊重。验证特定系统或设备时记录实际环境，不以 `ictool` 预览替代设备结果。
