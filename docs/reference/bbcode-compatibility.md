# Discuz 与 BBCode 兼容性参考

本页区分四件事：**保留源码、提供编辑控件、在原生编辑器预览、服务端允许并渲染**。有按钮不代表当前用户有权提交，有预览不代表发布后按相同样式显示，识别标签也不代表资源能播放。

客户端行为以当前源码为准，主要入口是 [标签与文档模型](../../Sources/YamiboXCore/Forum/Domain/ForumComposerDocument.swift)、[参数解析](../../Sources/YamiboXCore/Forum/Domain/ForumComposerAttributes.swift)、[服务端能力解析](../../Sources/YamiboXCore/Forum/Data/Composer/ForumComposerContextParser.swift)及 [原生预览](../../Sources/YamiboXUI/Features/Forum/Composer/ForumBBCodeTextCodec.swift)。实现边界见 [论坛编辑器设计](../architecture/forum-editor.md)。

## 语法来源与适用边界

Discuz 语法依据沿用 2026-09-11 的调查：官方 `v3.5` 分支固定提交 `ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7`，提交日期 2026-04-27，版本文件标记为 `X3.5 / Development`。这是可追溯的语法基准，不是百合会服务器精确版本，也不是“最新版本”证明。

- [原生 BBCode 解析](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/function/function_discuzcode.php)定义基础渲染及参数规则。
- [编辑器模板](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/template/default/forum/post_editor_body.htm)与 [编辑器命令](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/static/js/editor.js)说明入口和插入形式。
- [论坛提交模型](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/class/model/model_forum_post.php)与 [附件处理](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/function/function_attachment.php)说明上传图片规范化及权限边界。
- [主帖处理](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/module/forum/forum_viewthread.php)说明分页、目录和起始动画；[安装预置](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/install/data/install_data.sql)说明自定义代码默认配置。

历史调查还记录了站点编辑器的 `sup`、`sub`、`ruby`、`lineh` 和 `collapse` 入口，其中折叠语法有 [站方教程](https://bbs.yamibo.com/thread-549182-1-1.html)作为来源。本文没有重新访问生产论坛，也没有据历史按钮推断现在所有账号、版块或后台配置。

## 当前客户端矩阵

下面的“预览”只指原生 BBCode 编辑器和属性面板，不是论坛最终阅读页面。所有已知、未知或损坏源码均应在未修改时保留；矩阵不重复这一公共规则。编辑入口仍受当前编辑上下文约束。

| 标签或功能 | 原生编辑预览 | 编辑入口 | 服务端语法与限制 |
| --- | --- | --- | --- |
| `b`、`i`、`u`、`s` | 粗体、斜体、下划线、删除线 | 工具栏和文字格式菜单；支持后续输入格式 | 基准原生标签；`i=s` 另属系统标记 |
| `strong`、`em`、`strike`、`blockquote` | 分别按 `b`、`i`、`s`、`quote` 理解 | 不主动生成别名 | 客户端兼容别名，不据此承诺基准服务端同样识别 |
| `font`、`size` | 字体及大小；缺少字体时回退 | 字体、传统字号、px、pt 属性面板 | 传统字号 1–7 与带单位尺寸不同，不能把 `3` 当成 3px |
| `color`、`backcolor` | 主题适配的文字及底色 | 颜色面板 | 颜色名、十六进制及可解析的 rgb/rgba；`backcolor` 不是整帖背景 |
| `sup`、`sub` | 上下标 | 文字格式菜单 | 基准安装预置的自定义代码，默认未启用；实际站点配置决定支持 |
| `align`、`p`、`indent`、`lineh` | 对齐、段落缩进、行高 | 段落菜单及属性面板 | `align/p/indent` 属基准原生；`lineh` 为站点扩展，倍率不同于 `p` 像素行高 |
| `list`、`[*]` | 有序、无序及嵌套项目 | 列表菜单、回车、退格、缩进 | `list` 类型为无参数、`1`、`a`、`A`；`[*]` 不需闭合 |
| `hr`、`quote` | 分割线和可直接编辑的引用正文 | 插入及段落菜单 | `hr` 是单标签；基准 `quote` 不带作者参数 |
| `table`、`tr`、`td` | 网格、背景、宽度及合并单元格的简化预览 | 表格面板、行列操作、矩形合并与拆分 | 基准支持显式和竖线简写；移动版服务端装饰可能简化 |
| `ruby` | 注音与正文 | 注音、正文面板 | 站点扩展；参数为注音，正文为被注音文字 |
| `collapse` | 标题及默认开合；展开时显示正文 | 开合、标题及嵌套正文面板 | 插件语法，不是访问控制；插件不可用时可能显示源码 |
| `hide`、`free` | 作者输入内容及条件标记 | 回复、积分、期限和正文面板 | 基准原生；显示权由服务端决定，预览不模拟读者权限 |
| `code` | 等宽字面内容 | 代码正文面板 | 内部 BBCode 不递归解析；无基准语言参数 |
| `float`、`fly` | 方向及静态正文 | 方向或正文面板 | `float` 原生；`fly` 属默认未启用的预置代码；客户端不承诺 CSS 环绕或动画 |
| `url`、`email` | 链接文案 | 地址、文案及取消链接 | 原生语法；明确点击只打开客户端认可的 http/https/mailto，危险原地址仍保留 |
| `img` | 安全图片地址的图片或占位，尺寸受编辑区域约束 | 地址与宽高面板 | 原生；图片权限、地址可用性和服务端策略影响结果 |
| `attach`、`attachimg` | 已知元数据或本地上传图片；否则附件占位 | 附件 ID、附件选择及上传流程 | 正文是站内附件 ID，不是 URL；服务器可能将 `attachimg` 规范化为 `attach` |
| 站点表情 | 本地目录对应的图片 | 表情选择器 | 由站点表情代码配置决定；`smileyoff` 时保留字面代码 |
| `audio`、`media`、`flash`、`swf` | 类型、地址及尺寸占位 | 高级参数与正文面板 | 基准识别标签；客户端不自动播放、执行 Flash 或启动外部 App |
| `qq` | 联系标记 | 号码面板 | 基准自定义预置代码，仍依赖启用状态和用户组；不自动启动 QQ |
| `password` | “已设置密码”标记，遮蔽值 | 帖子密码面板 | 包裹密码值，作用于帖子访问；不是带密码参数的加密正文块 |
| `postbg` | 可信白名单图片或占位 | 站点背景选择器 | 基准白名单文件名，不是任意 URL；没有可信目录时不能新增，未知旧值保留 |
| `page`、`index`、`[#…]` | 分页标记和静态目录内容 | 高级菜单、目录内容及项目参数 | 主帖专用；移动版、归档及回复路径不保证相同展示 |
| `begin` | 静态图片或占位 | 地址、尺寸、效果及秒数面板 | 主帖专用起始动画语法；客户端不执行动画或 SWF |
| `groupid`、`i=s` | 系统标记占位 | 无普通插入/属性编辑入口；保留源码 | 服务端系统生成标记，不当作普通群组按钮或斜体 |
| 未知标签、损坏结构、达到深度上限 | 字面源码 | 源码模式 | 不猜插件规则，不自动修复或删除 |
| `bbcodeoff` | 正文以字面源码展示 | 表单选项 | 与编辑器源码开关独立，不代表删除标签 |

## 参数与往返要点

### 文字和段落

```text
[size=3]传统字号[/size]
[size=18px]像素尺寸[/size]
[size=12pt]印刷点尺寸[/size]
[p=30, 2, left]像素行高、em 首行缩进、对齐[/p]
[lineh=1.7]行高倍率[/lineh]
[list=1][*]第一项[*]第二项[/list]
```

`p` 必须保留参数间的逗号和空格，前三项依次为行高、首行缩进和 `left/center/right`，前两项可为 `null`。客户端没有原生 `justify` 对齐。字体回退、编辑主题配色或显示大小限制不应改写未编辑的源码。

客户端生成规范小写标签。已存在的别名和大小写不全篇规范化；只编辑正文时保留原始标签边界。无效参数降级为不透明源码，例如 `[quote=作者]` 不被当作已知引用面板可编辑节点。

### 表格

```text
[table=80%,#eeeeee]
[tr][td]项目[/td][td]内容[/td][/tr]
[tr][td=2,1]合并两列[/td][/tr]
[/table]
```

`table` 可带宽度和背景，`tr` 可带背景；`td` 可带宽度或跨列数、跨行数、可选宽度。竖线简写表格的 `\|` 表示字面竖线，`\n` 表示单元格内换行。

未修改的表格保持原文；表格面板真正修改内容或结构后，仅当前表格输出显式 `tr/td` 结构，不转换其他正文。表格模型最多处理 100 行/列的布局范围；面板预览只显示有限行数，不应把预览截断误认为数据丢失。

### 图片、附件与媒体

```text
[url=https://example.com/]链接文字[/url]
[img=640,480]https://example.com/image.png[/img]
[attachimg]12345[/attachimg]
[audio]https://example.com/audio.mp3[/audio]
[media=mp4,640,360]https://example.com/video.mp4[/media]
```

图片尺寸兼容 `640,480`、`640x480` 和竖线分隔，客户端正常生成逗号形式。媒体可以带类型与宽高；识别资源格式不等于可播放。视频按钮语法是 `media`，不能将其他论坛的 `[video]` 当作基准原生标签。

附件没有已知元数据时只显示占位，不以 ID 拼出猜测的下载地址。远程图片预览会经过当前图片管线和 referer，图片加载失败也不能删掉源码。照片和粘贴图片仍需上传确认，不因可视预览直接上传。

### 隐藏、密码及插件

```text
[hide]回复后可见正文[/hide]
[hide=100]积分条件正文[/hide]
[hide=d7,100]期限和积分条件正文[/hide]
[password]密码值[/password]
[ruby=かんじ]漢字[/ruby]
[collapse=0,补充说明]折叠正文[/collapse]
```

`hide=100` 是总积分阈值，不是支付金额或阅读权限等级；`d7` 以帖子时间计算期限，服务端全局配置或作者、版主例外也可能影响结果。`free` 指收费主题中的免费可见部分，不取消附件收费。

密码值在纯文本摘要与预览中遮蔽，但源码、提交和本地草稿仍保留该值，不能声称端到端加密。作者输入的隐藏正文可在编辑预览中出现，不意味着客户端获得了其他用户未授权内容的显示权。

`collapse=0,标题` 默认收起，`1` 默认展开；客户端开合只影响预览，不删除正文。嵌套面板禁止新建帖子级密码和背景，防止将整帖属性误作为段内属性。

### 主帖目录和系统代码

```text
[index]
[#1]第一节
[#2]第二节
*[#123,456]相关回复
[/index]
第一节正文
[page]
第二节正文
```

`[#2]` 是页号；`[#123,456]` 是 TID 与 PID；目录项目按行书写，最后一项后也保留换行。`page` 是同一主帖内容分隔，不是论坛楼层列表分页。客户端仅在明确主帖上下文允许新增主帖专用代码，未知目标不放开这些入口。

`postbg` 从受信任站点背景目录选择。`begin` 参数顺序为点击地址、宽、高、效果、停留秒数；可保留无参数形式，但原生编辑器只做静态展示，不能从服务端旧编辑提示推断现代播放能力。

## 编辑能力与服务端权限

`ForumComposerContext` 使用 `allowed/denied/unknown` 三态。解析依据是当前返回的表单、能力变量、明确按钮、附件元数据及背景白名单，不读取或执行任意服务端 JavaScript。

- 明确 `bbcode` 禁用会拒绝普通标签新增；图片和媒体能力分别参与判断。
- 未知能力不是明确许可：普通入口可能可编辑，但最终仍需服务端校验；不能把客户端存在菜单写成该用户组已获授权。
- 主帖专用代码、`groupid` 和缺少白名单的背景有额外约束，不以通用未知状态放行。
- 预置自定义代码、站点扩展和插件取决于后台配置。工具栏可见性不是完整白名单，无按钮也不能推出已禁用。

服务器支持矩阵必须用本地论坛上不同账号、版块及主帖/回复上下文验证，不能用编辑器预览或静态源码核对替代。生产站全部扩展需要管理员提供 `forum_bbcode` 配置、有效插件钩子及权限规则，本页不声称穷尽。

## 不应当作独立 BBCode 的功能

- Unicode emoji 是普通正文；站点表情使用配置代码，不是固定 `[smiley]`。
- `@用户名` 属提交处理，可能生成用户空间链接和通知，不是通用 `[at]` 标签。
- `attach://…`、ED2K 和自动识别 URL 属协议或预处理，不是对应的成对标签。
- 投票、主题类型、上传、草稿、撤销、去格式、全屏和字数统计属于表单或编辑行为。
- 基准原生路径没有通用 `[spoiler]`、`[center]`、`[strike]`、`[br]`、`[h1]`、`[ul]`、`[li]`；客户端别名或站点自定义同名代码应另行注明。

新增兼容能力时先明确它属于保留、预览、控件还是服务端提交，再更新本矩阵。核对和交互验证遵循 [Local App 启动参数](../tests/launch-arguments.md)，不使用历史报告中的已移除测试 target、临时日志或旧性能结果作为当前证据。
