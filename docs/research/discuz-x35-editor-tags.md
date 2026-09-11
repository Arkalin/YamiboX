# Discuz! X3.5 编辑器标签调查

核查日期：2026-09-11。

## 范围与结论

这里的“标签”指论坛发帖正文使用的 Discuz! 代码（BBCode），不是主题关键词，也不是任意 HTML 标签。

核查依据：Discuz! 官方镜像 `v3.5` 分支，提交 `ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7`（2026-04-27）；以及百合会当前桌面端发帖页面、参数弹窗、站方教程。该 Git 分支的版本文件标记为 `X3.5 / Development`，不将其冒充某个 Release 安装包或百合会服务器的精确源码版本。

- 必须分开理解：原生解析标签、发帖流程专用标签、后台配置的自定义标签、插件标签。
- 工具栏不是完整白名单。后台可以启用标签而不展示按钮；不同用户组、版块、主帖/回复也可能有不同能力。
- 本文覆盖已核查 X3.5 原生论坛编辑/解析路径的标签，以及截图对应的百合会可见扩展。不能据此断言百合会后台没有其他未展示标签。
- 在线核查仅打开页面和参数弹窗，未填写正文、发帖、上传附件或保存草稿。下列原生行为主要由源码确认，并非逐项发布测试。

原生正文入口：[function_discuzcode.php](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/function/function_discuzcode.php)。工具栏和条件：[post_editor_body.htm](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/template/default/forum/post_editor_body.htm)。

## 一、原生文字与排版

表中“文本”“地址”等为需要替换的占位内容。建议生成小写标签，保留配对与嵌套关系。

| 功能 | 标签与示例 | 参数或注意事项 |
| --- | --- | --- |
| 粗体 | `[b]文本[/b]` | 原生 |
| 斜体 | `[i]文本[/i]` | 原生；另有系统状态样式 `[i=s]文本[/i]`，不宜作为普通斜体生成 |
| 下划线 | `[u]文本[/u]` | 原生 |
| 删除线 | `[s]文本[/s]` | 原生已经支持；不必依赖自定义代码 |
| 字体 | `[font=宋体]文本[/font]` | 字体名；实际呈现依赖设备可用字体 |
| 字号 | `[size=3]文本[/size]`、`[size=18px]文本[/size]` | 支持传统字号及 `px` / `pt`；工具栏提供 1 至 7，不能把无单位 `3` 当成 3px |
| 文字颜色 | `[color=#336699]文本[/color]` | 颜色名、十六进制、`rgb(...)`、`rgba(...)` |
| 文字背景色 | `[backcolor=#ffff00]文本[/backcolor]` | 与整帖背景 `postbg` 不同 |
| 对齐 | `[align=center]文本[/align]` | `left`、`center`、`right`；没有原生 `justify` 分支 |
| 段落排版 | `[p=30, 2, left]文本[/p]` | 参数依次为行高 px、首行缩进 em、对齐；前两项也接受 `null`；源码要求逗号后的空格 |
| 块缩进 | `[indent]文本[/indent]` | 与首行缩进、左右浮动不同；基础工具栏没有对应独立按钮 |
| 左右浮动 | `[float=left]内容[/float]` | `left`、`right`，常用于图文环绕 |
| 无序列表 | `[list][*]甲[*]乙[/list]` | `[*]` 是列表项标记，无闭合标签 |
| 有序列表 | `[list=1][*]甲[*]乙[/list]` | 类型支持 `1`、`a`、`A` |
| 分隔线 | `[hr]` | 单标签，无 `[/hr]`；图案分隔线由编辑器插入图片，不是新的标签 |

依据：[原生替换规则](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/function/function_discuzcode.php#L146)、[编辑器命令与自动排版](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/static/js/editor.js#L736)。

## 二、表格

| 标签 | 支持形式 | 说明 |
| --- | --- | --- |
| `table` | `[table]...[/table]`、`[table=80%]...[/table]`、`[table=80%,#eeeeee]...[/table]` | 可设宽度和背景色 |
| `tr` | `[tr]...[/tr]`、`[tr=#eeeeee]...[/tr]` | 行，可设行背景色 |
| `td` | `[td]...[/td]`、`[td=120]...[/td]` | 单元格，可设宽度，包括百分比 |
| `td` 合并 | `[td=2,3]...[/td]`、`[td=2,3,120]...[/td]` | 依次为跨列数、跨行数、可选宽度 |

```text
[table=80%,#eeeeee]
[tr][td]项目[/td][td]内容[/td][/tr]
[tr][td]示例[/td][td]正文[/td][/tr]
[/table]
```

另有简写表格：`[table]` 内不含 `[/tr]` / `[/td]` 时，可用换行分行、`|` 分列；`\|` 表示字面竖线，`\n` 表示单元格内换行。显式表格解析中，宽度百分比上限为 98%，超过 560 的像素宽度会转为 98%；不应把这些规则简单套用到所有简写情况。移动端的表格装饰会被简化。

依据：[parsetable / parsetrtd](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/function/function_discuzcode.php#L438)。

## 三、链接、图片、附件与媒体

| 功能 | 标签与示例 | 注意事项 |
| --- | --- | --- |
| 超链接 | `[url]https://example.com/[/url]`、`[url=https://example.com/]文字[/url]` | 支持地址本身或自定义文案；特定协议另受服务端规则限制 |
| 邮件 | `[email]name@example.com[/email]`、`[email=name@example.com]联系[/email]` | 原生支持，没有独立按钮；链接按钮也可生成 `mailto:` URL |
| 外链图片 | `[img]图片地址[/img]` | 图像代码和图片显示权限可影响结果 |
| 指定图片尺寸 | `[img=640,480]图片地址[/img]` | 兼容 `640x480`；源码正则也接受竖线分隔，但不建议主动生成非标准形式 |
| 附件 | `[attach]12345[/attach]` | 数字为站内附件 ID，不是 URL；解析还涉及权限和附件元数据 |
| 上传图片 | `[attachimg]12345[/attachimg]` | 编辑器输入形式；发帖模型会规范化成 `[attach]` 存储，编辑时可能再转回 |
| 音频 | `[audio]音频地址[/audio]` | 兼容 `[audio=1]`，但当前核查分支调用相同解析器，不据此承诺自动播放 |
| 音视频 | `[media=mp4,640,360]媒体地址[/media]` | 类型、宽、高；类型可由扩展名推断，站点视频链接可能使用 `x`；宽高也支持百分比或 `auto` |
| Flash | `[flash]地址[/flash]`、`[flash=640,480]地址[/flash]` | 旧格式；识别标签不等于当前浏览器能够播放该资源 |
| 旧 SWF 标记 | `[swf]地址[/swf]` | 原生仍识别，但生成图标和链接，不等同于嵌入播放器 |

“视频”按钮插入的是 `[media=...]`，不是原生 `[video]`。媒体能否真正播放还取决于站点媒体解析器、资源地址、浏览器和编解码支持。没有媒体权限时，相关标签可能退化成链接。不同移动版入口还会使用不同媒体处理分支。

依据：[编辑器插入逻辑](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/static/js/editor.js#L1269)、[媒体与图片解析](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/function/function_discuzcode.php)、[附件规范化](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/class/model/model_forum_post.php#L101)、[附件渲染](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/function/function_attachment.php)。

## 四、引用与访问条件

| 功能 | 标签与示例 | 含义 |
| --- | --- | --- |
| 引用 | `[quote]引用内容[/quote]` | 原生是无参数形式，不应默认支持其他论坛的 `[quote=作者]` |
| 代码块 | `[code]原样代码[/code]` | 内容按代码展示；不是 Markdown 围栏，也没有原生语言参数 |
| 免费区域 | `[free]免费内容[/free]` | 用于收费主题内的免费可见部分；不是取消附件收费 |
| 回复可见 | `[hide]隐藏内容[/hide]` | 由服务端结合主题、登录用户等判断 |
| 积分可见 | `[hide=100]隐藏内容[/hide]` | 总积分阈值，不是支付 100 积分，也不是阅读权限等级 |
| 到期取消隐藏 | `[hide=d7]隐藏内容[/hide]` | 7 天内仍按回复可见处理，超过期限后解除隐藏 |
| 到期或积分条件 | `[hide=d7,100]隐藏内容[/hide]` | 到期前需满足积分阈值，到期后解除隐藏 |
| 帖子密码 | `[password]密码[/password]` | 这里包的是密码值；作用于该帖内容，不是 `[password=密码]保密段落[/password]` |

隐藏期限以帖子时间为基础，站点全局 `hideexpiration` 也可能提前解除隐藏。版主、作者等存在规则例外。自建客户端不应靠本地折叠界面模拟这些访问控制，更不应将服务器未授权返回的内容视为可显示内容。密码代码是访问控制标记，不等于对正文进行端到端加密。

依据：[隐藏与密码处理](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/function/function_discuzcode.php)、[免费内容提取](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/function/function_post.php#L640)。

## 五、帖子级与系统标签

| 功能 | 标签与示例 | 范围 |
| --- | --- | --- |
| 帖内分页 | `[page]` | 分隔同一主帖的内容；不是楼层列表分页；单标签 |
| 目录 | `[index]...[/index]` | 主帖目录容器，节点按行编写 |
| 目录页节点 | `[#2]第二节` | 跳转到 `[page]` 划分的第 2 页；无闭合标签 |
| 目录帖子节点 | `[#123,456]关联回复` | 参数为主题 TID、帖子 PID；行首 `*` 表示目录缩进 |
| 整帖背景 | `[postbg]背景文件名[/postbg]` | 从站点 `postimg` 缓存中的背景白名单匹配，不是任意图片 URL |
| 起始动画 | `[begin=链接地址,900,500,2,5]图片或SWF地址[/begin]` | 参数依次为点击链接、宽、高、效果、停留秒数；兼容无参数 `[begin]地址[/begin]` |
| 群组来源 | `[groupid=123]群组名[/groupid]` | 系统生成的来源标记，主帖路径处理；不是通常需要提供的编辑按钮 |

目录示例，注意每个节点及末尾节点之后的换行：

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

`page`、`index`、`begin` 在移动端、归档模式、回复楼层中有删除或不展示的处理，不能假设与桌面主帖一致。`begin` 的效果值为 0 无特效、1 展开闭合、2 淡入淡出；宽 400 至 1024、高 300 至 640，默认停留 5 秒。编辑器提示声称支持 FLV，但本次核查的 `parsebegin()` 分支仅明确处理 JPG/JPEG/GIF/PNG/SWF，不能照抄提示认定 FLV 起始动画可用。

依据：[主帖专用处理](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/module/forum/forum_viewthread.php#L1226)、[parseindex / parsebegin](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/module/forum/forum_viewthread.php#L1640)、[群组来源处理](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/function/function_discuzcode.php#L314)。

## 六、官方附带的自定义代码预置

这些存放在 `forum_bbcode`，不属于 `function_discuzcode.php` 写死的基础标签。后台可改名、替换规则、启用状态、按钮和用户组权限。

| 标签 | 示例 | 核查分支的安装预置状态 |
| --- | --- | --- |
| 上标 | `x[sup]2[/sup]` | `available=0`，预置但默认未启用 |
| 下标 | `H[sub]2[/sub]O` | `available=0`，预置但默认未启用 |
| 横向滚动 | `[fly]滚动文字[/fly]` | `available=0`；旧式 marquee 展示 |
| QQ 联系入口 | `[qq]123456[/qq]` | `available=2`，启用并展示按钮，但仍受用户组权限约束 |

后台 `available=1` 表示启用但不展示按钮，`2` 表示同时展示；因此“截图看不见”不能直接推导为“服务端不支持”。

依据：[安装预置](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/install/data/install_data.sql#L857)、[解析缓存](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/function/cache/cache_bbcodes.php)、[按钮缓存](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/function/cache/cache_bbcodes_display.php)。

## 七、百合会截图对应扩展

在当前账号可见的[动漫区发帖编辑器](https://bbs.yamibo.com/forum.php?mod=post&action=newthread&fid=5)核对到如下按钮。与用户截图右侧的图标及排列一致。

| 功能 | 语法 | 在线核查证据 |
| --- | --- | --- |
| 上标 | `[sup]文本[/sup]` | `e_cst1_sup`，一参数自定义代码；官方也有预置 |
| 下标 | `[sub]文本[/sub]` | `e_cst1_sub`，一参数自定义代码；官方也有预置 |
| 注音 | `[ruby=注音]文字[/ruby]` | `e_cst2_ruby`；弹窗先要求注音，再要求被注音文字 |
| 删除线按钮 | `[s]文本[/s]` | `e_cst1_s`；按钮经自定义代码机制展示，但 `s` 本身已属原生标签 |
| 行距 | `[lineh=1.7]文本[/lineh]` | `e_cst2_lineh`；弹窗提示默认 1.7；不是原生 `p` 的像素行高参数 |
| 折叠面板 | `[collapse=0,标题]内容[/collapse]` | 插件按钮 `e_collapse`；站方教程截图明确展示语法；0 对应默认收缩，界面另提供默认展开选项 1 |

`ruby`、`lineh` 的参数顺序依据现场弹窗和官方 `cst2` 序列化规则；未读取百合会后台替换模板，因此没有把具体生成的 HTML/CSS、复杂嵌套上限、特殊字符转义声称为已验证。

折叠面板可以放文字、链接、图片并嵌套。它是展示功能，不是 `hide` 的回复/积分访问控制。站方于 2024-08-30 的教程明确说明这是安装的插件，并提醒插件失效时内容会回到代码状态。来源：[百合会折叠功能使用教程](https://bbs.yamibo.com/thread-549182-1-1.html)。

```text
[ruby=かんじ]漢字[/ruby]
[lineh=1.7]第一行
第二行[/lineh]
[collapse=0,剧透内容]
这里是折叠正文。
[attachimg]12345[/attachimg]
[/collapse]
```

没有在本次工具栏核查中看到 `fly`、`qq`，但未核查后台，不能据此认定它们已禁用。

## 八、不是独立成对标签的功能

| 功能 | 实际形式 |
| --- | --- |
| 表情 | 表情代码由站点表情配置决定，例如默认表情可能使用 `:)` 等，扩展表情可能使用 `{:...:}`；不能枚举成一个固定 `[smiley]` 标签 |
| Unicode Emoji | 普通 Unicode 正文，不是 BBCode |
| `@朋友` | 输入 `@用户名` 并以空白分隔；发帖流程解析用户后生成 `[url=home.php?mod=space&uid=...]@用户名[/url]`，通知受权限和数量限制；不是通用 `[at]` 标签 |
| 附件协议 | `attach://12345`、`attach://12345.mp3` 等，受 `allowattachurl` 及附件类型规则控制；不是成对标签 |
| ED2K 链接 | `ed2k://.../` 有专门识别，不是 `[ed2k]` |
| 自动识别网址/图片 | 编辑器选项与预处理，通常生成 `url` / `img`，不是新标签 |
| 从 Word 粘贴 | 清理/转换粘贴内容，沿用已有格式标签 |
| 下载远程图片 | 附件抓取动作，不是 `[download]` 标签 |
| 自动排版 | 生成/调整现有段落结构，纯文本路径可生成 `[p=30, 2, left]` |
| 撤销、重做、去格式、取消链接 | 编辑操作，不生成专用标签 |
| 全屏、常用/高级、编辑框大小 | 编辑器显示状态 |
| 保存数据、恢复数据、字数检查 | 编辑器草稿/辅助操作 |
| 纯文本开关 | 切换源码编辑与所见即所得；不等同于“禁用 Discuz! 代码”选项 |
| 发起投票 | 主题类型和表单数据，不是 `[poll]` 正文标签 |

依据：[编辑器命令](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/static/js/editor.js)、[BBCode/HTML 转换](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/static/js/bbcode.js)、[@用户发帖流程](https://github.com/DiscuzTeam/DiscuzX/blob/ccf55748e13c1a5497c08d6eb7b7f29b65a6d2a7/upload/source/class/extend/extend_thread_allowat.php)。

## 九、完整性边界

未在上述 X3.5 原生论坛路径发现通用 `[video]`、`[spoiler]`、`[center]`、`[left]`、`[right]`、`[strike]`、`[br]`、`[h1]`、`[ul]`、`[ol]`、`[li]` 标签，不能套用其他论坛或 HTML 的名字；站点自行定义同名代码则另论。

`payto` 仍出现在摘要清理、审核和 QQ Connect 的旧代码中，但本次没有找到对应的原生正文渲染器或编辑器生成路径，因此不将它列为可用支付标签。代码中出现一个标签名，不等于当前版本支持该功能。

要得到“百合会全部用户组、全部版块、包括无按钮扩展”的绝对完整清单，还需要站点管理员提供 `forum_bbcode` 配置、有效插件的 `discuzcode` 钩子和版块/用户组权限。仅公开源码、截图和普通发帖页面无法证明这一部分的完备性。

若用于客户端兼容，建议分别记录“能保存原文”“能预览”“有编辑控件”“服务端允许并正确显示”，不要将四者混为一个支持标记。尤其对 `hide`、`password`、媒体、插件和未知标签，应保留原文并遵守服务端结果，避免编辑一次就丢失内容。
