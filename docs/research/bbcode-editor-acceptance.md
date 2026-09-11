# BBCode 编辑器兼容与验收

语法基准：[Discuz! X3.5 与百合会标签调查](discuz-x35-editor-tags.md)。源码是提交、撤销和本地草稿的唯一真值；预览不是服务端授权结果。未修改的大小写、空白、别名及参数保持原样。

## 标签矩阵

所有行均有源码往返夹具。`ForumComposerDocumentTests.everyDocumentTagIsRecognizedAndLossless` 覆盖 47 个标签／参数案例；损坏、交叉嵌套、未知标签和超深输入另有保留测试。

| 标签 | 原生预览 | 编辑入口 | 能力与保留规则 |
| --- | --- | --- | --- |
| `b/i/u/s`、`strong/em/strike` | 字重、斜体、下划线、删除线 | 选区工具、后续输入格式 | 遵守 BBCode 能力；别名不主动规范化 |
| `font/size` | 字体回退；传统字号、px、pt 分开 | 字体／字号属性面板 | 字体不存在不改源码 |
| `color/backcolor` | 主题适配的文字／底色 | 色板、自定义颜色值 | 保留原始颜色拼写 |
| `sup/sub` | 上下标 | 格式菜单 | 空选区上下标互斥 |
| `align/p/indent/lineh` | 对齐、缩进、像素行高、倍率 | 段落菜单／参数面板 | 段落命令扩展到整段；单位不互换 |
| `list/[*]` | 有序、无序、嵌套编号 | 回车、退格、增减缩进、列表菜单 | 取消列表只删除选中项目标记 |
| `hr/quote/blockquote` | 分割线、引用 | 段落菜单 | 引用内文继续直接编辑 |
| `table/tr/td` | 网格、背景、跨行跨列、宽度 | 表格面板：行列、单元格、矩形合并、拆分 | 简写未编辑原样保存；结构修改只转换当前表格 |
| `ruby` | 注音与正文 | 注音／内容面板 | 保留嵌套内容源码 |
| `collapse` | 标题、默认开合、展开内容 | 标题、开合、嵌套内容面板 | 关闭预览不删除内容 |
| `hide/free` | 作者内容与条件标记 | 积分、期限、回复条件／内容面板 | 不模拟读者权限 |
| `code` | 原文等宽内容 | 纯文本代码面板 | 不解析代码中的标签 |
| `float/fly` | 方向标记／静态内容 | 方向／内容面板 | 不执行动画，不承诺 CSS 环绕 |
| `url/email` | 链接文字 | 地址、文案、独立取消链接 | 只由明确点击打开安全协议；危险地址原样保留 |
| `img/attach/attachimg` | 鉴权图片／附件占位、尺寸 | URL 或附件 ID、尺寸面板、已有上传流程 | 元数据缺失不猜下载 URL；未确认粘贴不上传 |
| 站点表情 | 既有表情目录图片 | 既有表情选择器 | `smileyoff` 时展示源码 |
| `audio/media/flash/swf` | 媒体类型、地址、尺寸占位 | 参数与地址面板 | 从不自动播放、执行 Flash 或启动外部应用 |
| `qq` | 联系标记 | 号码面板 | 从不自动启动外部应用 |
| `password` | 遮蔽属性 | 帖子密码面板 | 不替换选中正文；列表与纯文本预览遮蔽值 |
| `postbg` | 白名单资源图片 | 站点背景选择器 | 无可信白名单则不提供新增；未知原值保留 |
| `page/index/[#…]` | 分页／目录静态内容 | 高级菜单、目录内容／项目参数 | 只在确认主帖上下文时允许新增 |
| `begin` | 静态图片资源／占位 | 地址、尺寸、效果、秒数 | 只允许主帖新增；不执行脚本或 SWF |
| `groupid/i=s` | 系统标记占位 | 仅源码模式 | 无普通插入按钮，不把 `i=s` 变成斜体 |
| 未知／损坏／超过 64 层 | 字面源码 | 源码模式 | 不自动修复或丢弃 |
| `bbcodeoff` | 全部字面源码 | 表单选项 | 与编辑器源码开关独立 |

## 自动化证据

- 文档、选区、无损局部修改：`ForumComposerDocumentTests`、`ForumComposerListTests`、`ForumComposerTableTests`、`ForumComposerContextTests`。
- TextKit 2、组合输入、撤销、剪贴板、属性、图片预览、上传锚点：`ForumBBCodeDocumentEditorTests`。
- 320／390／834 宽度、深浅色、大字体、附件像素与原生面板：`ForumBBCodeLayoutTests` 的截图附件；真实模态切换、面板取消与可访问性结构由 `ForumBBCodeEditorInteractionTests` 验证。
- GRDB 迁移、重启、账号隔离、资源、修订竞争、删除与清理：`ForumComposerDraftStoreTests`；保存失败、失效账号、离线重载、令牌更新、服务端冲突、提交不明、服务端草稿、延迟上传／导入：`ForumComposerDraftIntegrationTests`。
- BLOG、原有表单、确认发送与网络边界继续运行现有 `ForumComposerPresentationTests` 以及完整 `YamiboXTests` test plan，不以 `swift test` 代替项目验收。
- 网络写入使用测试替身；不对真实论坛发帖、保存服务端草稿或上传。退出账号保留本地草稿，应用清理删除草稿及本地资源，不删除服务端附件。

## 性能与发布门槛

固定夹具为 100,000 个 UTF-16 单元和 200 个复杂节点。`ForumComposerPerformanceTests` 记录首次解析＋投影与 50 次编辑 P95；`ForumBBCodeLayoutTests` 记录真实 `UITextView` 30 次输入 P95，并验证既有附件对象不重建。首次解析门槛 500 ms；50 ms 编辑门槛在 Release、关闭覆盖率条件下执行，Debug 数据仅作诊断。测试命令额外包含 `-configuration Release -enableCodeCoverage NO ENABLE_TESTABILITY=YES`，仅为现有 `@testable` 导入启用测试可见性，保留 `-O` 与 whole-module optimization，不修改发布配置。设备、系统与结果随测试附件留存。

尚未完成的验收不得宣称通过。项目整体测试、优化构建性能门槛与截图检查完成后，在下方记录具体结果；VoiceOver 可访问性树测试不等同于物理设备上的完整读屏人工验收。

## 本轮结果

验收日期：2026-09-11。主机为 Apple M5、24 GB 内存、macOS 27.0（26A428）；专用 iPhone 16 模拟器运行 iOS 27.0（24A5355p），Xcode 27（27A266a）。

| 检查 | 结果 |
| --- | --- |
| 完整 Debug `YamiboXTests` test plan | 执行 2,586 项：2,572 通过、4 失败、10 跳过；核心与进程内 UI 测试无失败。失败项定位、修复后均已定向补验通过，不将首次整轮记录伪称为全绿 |
| 定向交互补验 | 辅助功能服务首次启动超时、旧表单开关定位、全屏视图交接、剪贴板 PNG 表征读取均已处理；表格／隐藏取消、全屏往返、源码精确保留、长列表通过 |
| 最终 Release 编辑器检查 | 22 项通过，含 16 项真实 `UITextView` 单测、布局矩阵、3 项编辑器交互与性能；表格末格完整性修正后，主交互与布局矩阵再次通过 |
| 系统照片与文件流程 | 原先依赖专用环境而跳过的 3 项全部另行通过：照片取消与选择、文件取消后重选、确认后仅一次模拟上传及正文插入。TestHost 独立配置文件共享，不更改主 App 的文件共享设置 |
| 布局与可访问性 | 320／390／834 宽度、浅色常规字号与深色辅助功能大字号的正文、全屏、表格及隐藏面板截图通过；复杂块宽度、表格末格包含关系及可操作性有断言 |
| 剩余环境限制 | 7 项既有测试未执行：1 项需要签名／Keychain 环境，6 项错误详情展示测试需要额外展示宿主条件；不属于本轮新增编辑器测试 |

固定性能夹具的优化构建实测：

| 指标 | 实测 | 门槛 |
| --- | --- | --- |
| 首次解析＋投影 | 6.27 ms | ≤ 500 ms |
| 文档增量编辑＋投影 P95 | 0.66 ms | ≤ 50 ms |
| 真实 TextKit 2 输入 P95 | 15.11 ms | ≤ 50 ms |

关键运行标识为 `2026.09.11_13-54-02`（全量）、`14-16-54`（照片及回归）、`14-29-12`（Release 性能与交互）、`14-38-16`（最终表格布局）及 `14-49-13`（文件确认）。Xcode 会自动轮换旧结果包；本轮保留了 `/tmp/yamibox-bbcode-full-validation.log`、`/tmp/yamibox-bbcode-final-regressions.log`、`/tmp/yamibox-bbcode-release-validation2.log`、`/tmp/yamibox-bbcode-final-layout-files.log` 与 `/tmp/yamibox-bbcode-final-file-confirmation3.log`，最终交互截图位于 `/tmp/yamibox-bbcode-verified-interaction-attachments` 及 `/tmp/yamibox-bbcode-passing-interaction-attachments`。图片均来自合成测试素材；未向真实论坛执行任何写入。

可访问性验证包含标签、值、按钮操作与布局，但未进行真机 VoiceOver 连续读屏人工验收；本机无 iOS 18 模拟器运行时，iOS 18 兼容性由部署目标编译检查覆盖，不冒充实际运行结果。
