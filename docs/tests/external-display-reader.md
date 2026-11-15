# 外屏阅读验证记录

环境：Xcode 27.2、iOS 27.0。只使用签名的 `YamiboX-Local` 和本地论坛。启动规则见[测试 App 启动参数](launch-arguments.md)。小说样本为 `296`（含本地章节和评论），漫画样本为 `299`（含 36 页实际图片）。iPhone 15 Pro 与 iPad Air 11 英寸 (M4) 为专用模拟器；外屏由模拟器 TVOut 模拟连接。此记录不代表有线实机、锁屏或显示延迟验收。

## 接管显示器开关回归

在 iPad Air 11 英寸 (M4) 的 iOS 27.0 模拟器上使用签名本地测试 App 和 1280×720 TVOut：

- 旧配置缺少开关字段时显示为开启，原快捷动作「书签」仍有效。关闭后快捷按钮设置隐藏，冷启动后仍关闭；重新开启后仍显示原快捷动作。
- 保持 TVOut 连接，关闭状态下分别冷启动进入小说 `1355` 和漫画 `1356`，正文均留在本机，TVOut 未出现专用阅读画面。
- 漫画接管期间从设备端阅读设置关闭开关：两层设置面板均可正常保留和关闭，TVOut 不再显示正文；返回本机后仍在第 2 话第 1/2 页，章节、图片索引和保存时间不变。
- 保持连接重新开启：面板打开时不抢占；关闭面板后，无需触摸正文或重新连接，外屏重新显示漫画，设备恢复触控板。分别覆盖在同一外屏设置面板内关开、以及已回到本机正文后再开启。

证据：`/tmp/yamibox-display-takeover-evidence/`。未实测有线真机、AirPlay 或 iOS 18–26 的外屏行为。

同一模拟器的触控板灵敏度回归：旧配置显示 100%，拖到 50% 后关开接管及冷启动均保留。对 TVOut 执行相同的 80 点单指横向拖动，光标在 50% 和 200% 时分别移动约 63 和 253 像素。证据：`/tmp/yamibox-trackpad-sensitivity-evidence/`。

## 按分辨率切换阅读设置

在 iPad Air 11 英寸 (M4) 的 iOS 27.0 模拟器上，使用签名 `YamiboX-Local`、本地论坛和两种 TVOut 分辨率验证：

- 从未包含外屏配置的本机设置启动。1280×720 和 1920×1080 首次接管均分别继承本机的小说和漫画设置。本机漫画亮度为 100%；将 720p 改为 95% 并重新打开设置，仍显示 95%，1080p 初次使用仍为 100%。
- 在 1080p 外屏设置面板把漫画亮度调到 90%，不确认即断开 TVOut：设备面板及草稿仍保留。确认后只有 1080p 保存为 90%；720p 和本机保持原值。设备回到漫画 `1356` 第 2 话第 1/2 页，断线前后的数据库位置记录一致。两种阅读设置面板均不显示配置归属标记。
- 在 720p 外屏将小说 `1355` 字号调为 120%，并关闭论坛格式的粗体。断开后本机字号仍是 100%，粗体为关闭；在本机重新开启粗体、再接回 720p，外屏字号仍是 120%，粗体同步开启。两个外屏配置均不保存论坛格式。外屏重排和断开后，小说仍在第 2 话，文字锚点、偏移 480 和保存时间均未改变。
- 保持 720p TVOut 连接，从小说设置的外设行为关闭接管：设备面板保留，关闭面板后回到本机 100% 字号。重新开启接管并冷启动后，720p 恢复 120% 字号，小说位置仍不变。

证据：`/tmp/yamibox-display-profiles-evidence/`。未实测物理显示器、AirPlay 或 iOS 18–26。

## 四区控制验收清单

- iPhone 竖屏及 iPad 横竖屏下，上方均为触控板，底部三个按钮可分别点按；检查大字号、安全区和从触控板滑入按钮区域时不误触。iPhone 沿用 App 只支持竖屏的配置。
- 在「外设行为 → 显示器」检查五个选项（不含设置）和评论默认值；改选后无需重连，重启仍保留选择。
- 小说和漫画正文的左右按钮沿用现有翻页或步进滚动；打开设备面板后隐藏触控板和外屏光标，不再向正文发送翻页指令。
- 「菜单」切换外屏工具栏显隐；目录、书签、喜欢和评论快捷按钮在设备上打开目标。用外屏光标从工具栏打开目录、评论、下载、设置，长按漫画打开图片操作；任何面板和后续子页都不显示在外屏。
- 设备面板打开时外屏继续显示阅读页。用设备滚动评论、打开右上角原生菜单、更改设置或点选章节。关闭子页应保留父面板和未提交的草稿；选章或确认设置后外屏按新位置或参数显示；关闭最外层后才恢复触控板。
- 面板打开时退后台，验证外屏遮蔽；回前台仍停留在原设备面板，外屏继续阅读。面板期间断线应保留设备草稿，关闭后回到本机阅读。
- 分别按三个按钮立即隐藏光标；上方再次落点时光标在原位恢复。手指留在触控板上按按钮，再抬手时不得补发手势。断线后设备恢复原阅读位置。

浮动面板统一移到设备后的 TVOut 回归：iPhone 的小说评论和屏蔽设置只在设备上显示；小说确认字号后外屏重排；漫画在设备目录选章后外屏跳转，原生图片查看器关闭后返回图片操作。iPad 打开书签时退后台，外屏遮蔽；回前台后设备仍停在书签，外屏恢复同一跨页。

设置单独移到设备端时的历史回归（iPhone 模拟器 TVOut）：漫画外设行为、小说取消字体导入与论坛格式可各自关闭，父层草稿仍在。当时设备打开阅读设置期间外屏遮蔽。

阅读设置移到设备端之前的 TVOut 验证记录（当时有六个快捷项）：

- iPhone：小说分页、评论列表上下滚动、从对话子页整体关闭评论、工具栏快捷键关闭目录并显示工具栏。设备端评论输入期间外屏遮蔽，不接受翻页。
- iPad：横竖屏布局、漫画纵向步进和右至左双页翻页、断线保留阅读位置且重连后按钮可继续使用。
- 设置与输入：六项设置、重启保留、设备侧设置即时生效、快捷键根据实际选中的列表分页切换或关闭。三个按钮均立即隐藏光标，触摸上方原位恢复；跨区滑动和同时按键未误触发额外动作。

未覆盖真机外屏、辅助功能大字号和全部快捷动作与面板的组合。

以下为四区控制加入前的外屏验证记录。

## 会话基线

签名构建日志：`/tmp/yamibox-external-stage1.log`、`/tmp/yamibox-external-stage1b.log`。

| 场景 | 结果 | 证据 |
| --- | --- | --- |
| 小说分页、字号重排、退出再打开 | 翻到下一页后修改字号，没有重启阅读器；退出到论坛，再打开恢复到同一章节和文字位置 | `/tmp/yamibox-external-display-stage1-evidence/novel-paged-*` |
| 小说纵向滚动与重排 | 从第 4/35 页重排到第 4/36 页；关闭后仍从第 4/36 页恢复 | `/tmp/yamibox-external-display-stage1b-evidence/novel-normal-*` |
| 漫画分页、纵向滚动、缩放 | 分页第 2 页捏合后仍是第 2 页；重开与切滚动模式保留图片位置。后续分页 4→5，切滚动后前进到第 7 页，重开仍是第 7 页 | `/tmp/yamibox-external-display-stage1-evidence/manga-paged-*`、`/tmp/yamibox-external-display-stage1b-evidence/manga-stage1b-*` |
| 漫画视口和外设处理器 | iPhone 外屏双指纵向滚动，拔线恢复本机，切分页后翻到 2/36，关闭并从书架在同进程恢复。完整进度记录前后逐字节相同；一次性签名诊断仅记录处理器栈大小，切屏、拔线、关闭与再打开均先降为 0 再升为 1，未出现重复注册 | `/tmp/yamibox-external-reader-handler-qa/evidence/` |
| 小说与漫画预览 | 从喜欢的锚点进入预览，移动阅读位置并关闭；前、中、后正式进度记录、时间戳和恢复路由快照相同。测试沙盒没有对应收藏条目，未独立比对收藏最近阅读 | 两次会话证据中的 `*-preview-*.txt` 及 `*-preview-reader-*` |
| 小说外屏预览 | 从原生「我的 → 喜欢 → 小说摘录 → 跳转原文」进入明确标有「不会记录阅读进度」的预览。保持连接用双指从外屏 5/6 到 7/8，再遥控关闭回喜欢列表，外屏全黑。正式进度和浏览记录逐字节相同，未创建窗口恢复路由；无对应收藏条目，未独立比对收藏最近阅读字段 | `/tmp/yamibox-external-display-iphone-final-evidence/preview-final-*` |

## 连接与生命周期

| 场景 | 结果 | 证据 |
| --- | --- | --- |
| iPhone iOS 27 accessory：阅读中接入 | TVOut 1920×1080 显示小说，设备仅显示「当前设备作为触控板」 | `/tmp/yamibox-external-display-stage2-evidence/iphone-novel-TVOut-*` |
| iPhone 先连接、再打开漫画 | 论坛与详情页不启动专用外显；进入漫画后自动接管。另测保持连接冷启动，1280×720 外屏使用双页，拔线恢复手机单页与同一图（第 18/36 页） | 同目录 `iphone-forum-TVOut-device-settled.png`、`iphone-TVOut-manga-detail*`、`iphone-manga-TVOut-auto-settled*`；`/tmp/yamibox-external-display-iphone-final-evidence/final-auth-manga-{tvout-cold-settled,after-unplug}*` |
| iPhone 小说保持连接冷启动 | 初次布局与外屏接管曾竞争，设备可读但需要重连。等待设备先完成初次布局后复测，无触摸、无重连，自动接管到第 2 章的 23/24 页 | `/tmp/yamibox-external-display-iphone-final-evidence/stable-cold-start-*` |
| iPad 宽外屏和重连 | 1920×1080 独立双页，保留比例和留白；本机第 3/4 页接管后拔线仍是第 3/4 页 | 同目录 `ipad-manga-reconnect-*` |
| 拥有者离开前台及后台断线 | iPhone 退到系统主屏幕后外屏全黑；回到同一进程恢复原画面；再次退后台后断开，返回本机漫画第 7/36 页 | 同目录 `iphone-manga-TVOut-{home,resume,detached-in-background}*` |
| 小说纵向迁移与分辨率改变 | 早期构建一度回到章首；加入初始视口位置抑制后不再回章首。一次热插拔为偏移 394→403（同一段落，约一行），1920→1280 再拔线前后偏移均为 403 | `/tmp/yamibox-external-display-stage3b-evidence/novel-vertical-*`、`novel-{before-resize,after-resize-unplug}-db.txt` |
| 小说分页快速往返后保存 | 外屏双指快速往返同一章，已保存偏移 286→571→286；再快速往返一次后拔线回本机，退出到论坛。返回、拔线、退出这三次读取的完整语义锚点一致。没有人为延迟数据库，不能证明已命中写入竞争的精确时序 | `/tmp/yamibox-external-display-iphone-final-evidence/save-order-final-*` |
| 旧写入在新页定位后才完成 | 一次性签名 Local 构建在实际保存适配器前延迟 1.5 秒；旧保存暂停时已完成下一次双指翻页，日志显示旧写入晚于新页渲染、随后提交更新。拔线前后最终章节语义偏移 1194 和保存时间戳逐字节相同 | `/tmp/yamibox-external-display-fallback-evidence/late-write-*` |
| 外屏关闭阅读 | 早期构建曾在拆除宿主时崩溃，随后曾在 TVOut 留下最后一帧。改为先遮黑、停输入再关会话；iPad 外屏点 × 后设备回论坛、进程不变，TVOut 持续全黑 | `/tmp/yamibox-external-display-stable-evidence/ipad-stable-remote-close-{device,tv,tv-dwell}*` |
| 原帖返回后重新接管 | 早期构建回到同一小说但要重新插线。保留同一外屏连接、移除阅读视口后复测：光标打开原帖时设备显示原生帖子、外屏全黑；从设备切回小说时自动接管、恢复触控板，前后外屏读页截图字节一致 | 同目录 `ipad-stable-{novel-tv-rendered,original-tv-neutral,novel-tv-returned}*`、`frames.sha256`、`scene-log.txt` |
| iPad 两个阅读窗口切换焦点 | 小说最后一次操作后取得外屏；切至本机漫画窗口时外屏全黑、不换书；回小说窗口恢复原小说。早期构建会把漫画换上外屏 | `/tmp/yamibox-external-display-stage5b-evidence/ipad-stage5b-{novel-owner-display,manga-focus-display,novel-return-display}*` |
| iPad 系统销毁拥有者窗口 | 通过系统窗口菜单「关闭」销毁小说窗口，而非从切换器强退进程；回到同一进程的漫画窗口，仍是第 4/36 页，本机焦点未让漫画自动上屏，外屏保持全黑 | `/tmp/yamibox-external-display-final-evidence/ipad-final-system-{window-exit-log,close-survivor}*` |
| 模拟器短时重连与准备中断开 | 模拟器可能在插入或改尺寸时断开旧 accessory 再接入。实际观察到本机视口短暂恢复、随后再次接管；早期构建在一次有效重连时仍显示旧失败提示，新的接管会清理该提示。首次热插拔没有系统 scene 的情况仍可在本机读；尚未人为复现 `UIWindow` 创建失败 | `/tmp/yamibox-external-display-stage2-evidence/iphone-novel-TVOut-resized-*` 与第 4 阶段 `manga-TVOut-diagnostic.txt` |
| 准备超时、准备期间拔线、迟到帧 | 一次性签名 Local 诊断构建延迟真实外屏帧回执，不替换状态机。连接中超时，设备出现失败提示且仍能翻页；迟到回执后外屏仍全黑。另一次在准备期间先拔线，旧回执后来执行，设备仍在原位置，章节锚点及时间戳逐字节相同。生产代码中不保留诊断注入 | `/tmp/yamibox-external-display-fallback-evidence/{timeout,disconnect}-*` |
| 准备过程中设备画面 | 修正共享模型先改排版造成的设备短暂裁切。真外屏帧已布局、诊断构建暂缓回执 8 秒时，手机仍显示完整单列原页、外屏黑；收到回执后外屏显示 5/6，手机才变成触控板。去掉注入的签名构建也通过阅读中热插拔及本机恢复 | `/tmp/yamibox-external-display-fallback-evidence/{snapshot-qa,clean}-*` |
| 漫画换章请求在途时拔线 | iPad 外屏从第 14 话选第 2 话，签名诊断构建让真实加载等待 8 秒。等待期间关闭 TVOut，本机暂时显示旧章；加载结束后同一进程显示第 2 话首图，数据库为章节 1357／图片索引 0，旧章没有覆盖新位置 | `/tmp/yamibox-external-display-chapter-interruption-evidence/` |
| 旧版 scene 委托分支 | 签名构建编译通过并保留 iOS 18 部署目标；本机没有旧版 iOS runtime，未运行 | `YamiboXApp.swift` availability 分支；[Apple 外接显示文档](https://developer.apple.com/documentation/uikit/presenting-content-on-a-connected-display) |

## 目标命中

| 控件 | 结果 | 证据 |
| --- | --- | --- |
| 正文与工具栏 | 小说和漫画正文中心点击唤出工具栏；点 × 退出。隐藏工具栏时点击原 × 位置只执行正文翻页，不退出。评论遮挡时，仍可见但标记为禁用的底层「返回」不会导航；设置加号单击只增加一次 | `/tmp/yamibox-external-display-stage3b-evidence/novel-controls-close-*`、`/tmp/yamibox-external-display-stage4-evidence/manga-gesture-show-controls*`、`/tmp/yamibox-external-display-iphone-final-evidence/{chain32,chain44-final}-*` |
| 目录与进度控件 | 小说目录选第 2 章；漫画进度胶囊可拖动。在独立本地漫画样本 1356（18 话）中，iPad 双指把目录从 1–9 话滚到 8–18 话，底层图片位置和 1/2 页不变。选第 14 话后拔线回本机同一图片；章节 1369、图片索引 0、更新时间相同 | 第 4 阶段 `novel-directory-*`、`manga-gesture-directory-slider-*`；`/tmp/yamibox-external-display-directory-background-evidence/{ipad-catalog-*,manga-anchor-chapter14-*}` |
| 设置与关闭 | 小说字号 1.3→1.4，关闭后重排；iPad 双指滚动设置并切换小说阅读方向；关闭设置后用该方向翻页 | 第 3b 阶段 `novel-remote-settings-*`、第 4 阶段 `novel-chain-settings-*`、`/tmp/yamibox-external-display-final-evidence/ipad-final-novel-rtl-settings-*` |
| 评论与返回 | 评论覆盖时底层设置不响应。内联工具栏支持「更多 → 屏蔽设置 → 点评与回复 → 返回 → 关闭筛选 → 关闭评论」。独立本地样本 1355 实测「共 2 条回复 → 查看对话 → 返回回复 → 返回评论」，打开作者资料时只在设备显示、TVOut 全黑，关闭后返回同一评论面板和触控板。原帖往返另见生命周期矩阵 | 第 3b 阶段 `novel-remote-comments-*`、`/tmp/yamibox-external-display-iphone-final-evidence/{comments-inline,chain34-nested}-*` |
| 搜索与注解 | 搜索在设备获取键盘、查到章节文本，选择结果回外屏并显示命中位置。在最终构建中点漫画喜欢条目的笔记按钮，设备显示有焦点的笔记编辑器，外屏全黑；取消后返回同一喜欢面板，未改变笔记或喜欢数据。未逐项检查书签及笔记提交操作 | `/tmp/yamibox-external-display-iphone-final-evidence/{stage5b,final}-novel-search-*`、`image-menu-final-existing-note-*` |
| 漫画图片动作 | 最终构建中，触控板长按打开外屏菜单（查看图片、设为封面、笔记、喜欢）；选择查看图片在设备显示图像，外屏全黑，关闭图像后恢复原漫画和触控板 | 同目录 `image-menu-final-{open,device-browser,returned}*` |
| 漫画下载 | iPad 仅用光标走完「下载 → 下载队列 → 下载管理 → 返回队列 → 关闭队列 → 关闭下载面板」，回到原漫画；未启动或删除下载 | `/tmp/yamibox-external-display-commands-evidence/ipad-commands-tv-{download-panel,queue,management,return-queue,queue-closed,reader-restored}*` |

当时显示在外屏的控件使用注册的可见命中区：顶部关闭及历史、目录／页进度、设置选项和滑块、评论正文动作／回复／筛选、搜索和注解、下载队列。现在外屏命中区只服务阅读器，浮动面板均由设备承载。

光标：单指移动后抬手，在设备不同位置落点不改变外屏光标位置；约 3.15 秒无操作后隐藏，触摸后在原位出现。iPad 实际从竖屏转为横屏再转回竖屏，触控板提示保持居中，1920×1080 外屏光标在两种方向都能移动到同一右上角且不越界，再反向移动时读页不变。证据 `/tmp/yamibox-external-display-final-rotation-evidence/`。尚未逐项实测所有隐藏或禁用目标。

## 设备输入与系统交互

初次链路实测走到「目录选第 2 章 → 改字号 → 写评论 → 设备评论编辑器」。第 4 阶段不能取消且外屏仍显示评论层；修正后第 5b 阶段，设备展示登录失效时外屏为纯黑，连接中取消回外屏评论；编辑器打开时拔线，设备仍保留同一编辑器，取消后返回本机评论，关闭评论回第 29/52 页。前后文字偏移和时间戳相同（偏移 286）。证据 `/tmp/yamibox-external-display-stage5b-evidence/novel-comment-*`、`novel-local-*-db.txt`。

后续使用本地论坛测试账号，证据在 `/tmp/yamibox-external-display-iphone-final-evidence/`。

| 场景 | 结果 | 证据 |
| --- | --- | --- |
| 搜索输入时拔线 | 设备键盘与查询保留，命中列表未外显；关闭后本机仍在 `novel-viewport-surface-1-28`、56%，保存的偏移 286 不变 | `final-novel-search-*` |
| 已认证草稿快速重连 | 在设备实际输入，拔线及 0.3 秒后重连仍保留文本和键盘；外屏全黑。取消时须确认放弃，未自动提交；关闭本机评论后自动接回同一章 | `final-auth-compose-*` |
| 已认证提交成功 | 本地论坛第 296 帖出现一次带 QA 标记的点评，设备回触控板，外屏评论出现新行和成功提示，关闭评论仍在原进度。空输入的发布按钮禁用 | `submission-1f077994-comment-submit*`、`submission-1f077994-local-html-count.txt`、`submission-1f077994-compose-empty-blocked*` |
| 服务器拒绝已认证回复 | 第 296 帖对 3 字节短回复返回「小于 10 个字符」；设备仍显示原草稿及「重试」，外屏截图与全黑基线逐字节相同。取消、确认放弃、关闭外屏评论后拔线，本机恢复第 29/52 页，章节锚点和文字偏移 286 不变。测试论坛回复数未变，没有修改规则或配置 | `reply-reject-final-*` |
| 照片选择 | 设备评论回复的上传图片唤起系统照片选择器，取消后回设备回复；另一次选中此前保存的本地样本，设备显示 21 KB PNG 的待上传确认。两个流程中外屏均全黑，从上传确认取消后再退出回复可返回外屏评论。未实际上传附件 | `submission-1f077994-photo-picker-{settled,cancel}*`、`comments-nav-final-photo-{selected-confirmation,selection-cancel,selection-return}*` |
| 系统分享与相册权限 | 漫画图片在设备唤起系统分享，取消分享回图像浏览器；拒绝照片添加后显示本机提示，允许后该模拟器相册出现新 PNG。两个分支关闭浏览器均恢复原外屏漫画，分享、权限提示期间外屏全黑 | `final-auth-manga-system-share-*`、`final-auth-manga-photo-*` |

同一次 iPhone 会话完成整条链路：外屏目录选第 1 章 → 字号点击一次从 1.4 调到 1.5 并应用 → 外屏打开评论 → 设备键盘输入回复 → 本地服务器拒绝时原草稿仍在、外屏全黑 → 放弃草稿，逐层关闭后拔线。设备回第 1 章、3%，文字锚点 `post:575#chapter:0`、偏移 140，在编辑前后相同。证据 `/tmp/yamibox-external-display-iphone-final-evidence/chain44-final-*`。

iPhone 搜索编辑中返回系统主屏幕，再回到原进程，保留同一查询和焦点，外屏一直全黑；关闭后回同一外屏页组。另用签名 Local 一次性诊断构建，经真实设备编辑器触发应用账号代次失效路径并关闭原会话，随后投递旧编辑完成回调：只回本机论坛，外屏仍黑且未重新拉起阅读器。第二项不修改服务器账号，和真实退到主屏幕的测试分开。证据 `/tmp/yamibox-external-display-fallback-evidence/{editor-background,stale-editor}-*`。

## 双指与外设

通过 Xcode 设备交互的 `mt` 输入实际多点触摸，而非调用业务动作。iPhone 小说纵向双指上移后，拔线恢复到第 25/46 页（原第 24/46 页），保存偏移 19→158；原地捏合前后无光标外屏截图逐字节一致。分页模式双指左移从 23/24 到 25/26，反向回到 23/24，一次手势只翻一组。证据 `/tmp/yamibox-external-display-stage4-evidence/novel-gesture-*`、`stage4-novel-paged-*`。当前移动增益 1.6；平移和捏合分别从 8–10 pt 和约 7.5% 间距变化判定，分页要满足 40–85 pt 的宽度相关阈值。模拟器触摸记录用于验证分类；没有实机手感或延迟数据。

同一构建的漫画真实双指：图片从 480×720 放大到约 1166×1749，平移后图片 X 偏移继续改变，始终是第 7 页；缩回后一次水平双指手势进入下一组。进度胶囊从 22% 拖到 50% 后落在第 17/18 页，未降级为正文翻一组。证据 `/tmp/yamibox-external-display-stage4-evidence/manga-gesture-*`。

另在 iPad 验证从右向左阅读：双指向右一次使漫画 4/36→6/36、小说 1/2→3/4，向左各回一组。漫画纵向外屏双指跨图从 5/36 到 6/36，拔线后本机仍为 6/36。证据 `/tmp/yamibox-external-display-final-evidence/ipad-final-{rtl,novel-rtl-stable,manga-vertical}-*`。尚未实测拖拽过程中切后台、目录或评论滚动途中销毁层级。

iPad 小说先捏合再保持双指间距横移 253 pt，过程中未转成翻页；另一次加入第二指再先抬第二指，也未补发点击，光标隐藏后的三张画面逐字节一致。证据 `/tmp/yamibox-external-display-gesture-cancel-evidence/ipad-gesture-novel-{paged-baseline,pinch-then-pan,add-remove-no-tap}*`。

iPad 外屏小说设置的字号滑块用 2.47 秒平移 205 pt，双指间距保持 140 pt。数值 1.0→1.6，预览变大、正文未翻页。点击被遮挡的正文设置按钮没有触发任何动作；关闭草稿未持久化设置。滑块按整段手势累计位移计算，避免小幅连续移动在逐帧舍入时丢失。证据 `/tmp/yamibox-external-display-slider-evidence/ipad-slider-{settings-before,settings-underlay-isolated,thumb-aligned,font-after-drag}*`。

长评论样本 1355 的章节评论由双指滚到后续标记 4–8，关闭后底层仍是原外屏页组 23/24；漫画长目录的双指隔离见上表。两次均用模拟器真实多点触摸。证据 `/tmp/yamibox-external-display-iphone-final-evidence/chain34-nested-{root-comments-active,root-comments-scroll,reader-return}*`。

另用真实双指先按 310 pt 手势正常从 1/2 翻到 3/4，再以同样距离移动并保持不抬手。确认手仍按住时关闭 TVOut，iPad 回到本机，保存偏移 477 和时间戳未变。抬手后重连，3/4 页的无光标截图与断开前逐字节一致。另一次在相同拖动仍未抬手时独立让系统设置进前台，UIKit 日志确认阅读 App 先失活、外屏变黑；回到同一进程后页组 5/6 截图一致、偏移 946 不变，时间戳只在切后台时更新。证据 `/tmp/yamibox-external-display-gesture-cancel-evidence/{final-interruption-*,final-anchor-*,ipad-gesture-final-*}`、`/tmp/yamibox-external-display-directory-background-evidence/ipad-settings-switch-*`。

外设绑定格式未改。一次性签名 Local 诊断构建在生产窗口键盘处理入口传入同一键的「按下、重复按下、释放」：双屏只翻一组，设备搜索编辑时章节锚点、时间戳不变，拔线后下一次命令只翻一页。这不是物理键盘或 UIKit 按键投递验证。公开的虚拟手柄连接成功，但隐藏方向键／面键和可见系统面键触摸均无原生输入流回调，未能验证手柄行为。证据 `/tmp/yamibox-external-peripheral-qa/evidence/`。不把文字输入、直接调用动作或编译当成硬件验收。

## 构建与验证边界

运行 `bash scripts/check-architecture.sh`、`git diff --check`、`openspec validate external-display-reader --strict`，以及 iPhone 模拟器的签名 `YamiboX-Local` 构建。不含诊断注入的最终构建日志 `/tmp/yamibox-external-reader-acceptance-build.log`，`codesign --verify --strict` 通过，链接目标为 iOS 18.0。断线后本机阅读、无外屏的小说／漫画阅读及退出恢复见上述分阶段回归。未新增测试 target、依赖或数据格式，未连接生产站点。1355 和 1356–1373 是标记明确的本地样本，不替换原有样本 296、299。

归档验收：26/26。用户豁免原 5.4 的实体键盘／手柄验收，不计入任务总数；规格与实现保持不变。上述模拟器诊断不视为实体外设通过。

未实测范围：旧版 iOS 运行时、物理 DP 输出、实机锁屏／延迟，以及实体键盘／手柄输入。一次性诊断构建用于可重现的时序与输入入口验证，所有故障注入及计数代码已从工作树和最终构建移除。

附带观察：两个模拟器构建用 `--open-page likes` 直接启动时曾停在启动画面；普通 Local 启动后经「我的」进入喜欢和外屏预览正常。没有确认直达问题的起因，不把它算成外屏预览途径通过。

## AirPlay 复验

有线与 AirPlay 共用 UIKit 的独立外屏场景和阅读会话，不按连接类型分支。iOS 27+ 在阅读器注册 scene accessory；iOS 18–26 继续接收系统连接的外屏场景。模拟器 TVOut 只覆盖这条共用路径，不能验证 AirPlay 接收端、网络链路、系统镜像或无线延迟。当前 `YamiboX-Local` 仅用于模拟器，AirPlay 无线实机验收待进行。

### TVOut 共用路径回归

使用 iPad Air 11 英寸 (M4)、iOS 27.0、签名 `YamiboX-Local` 与本地论坛。以下结果不代表系统镜像或 AirPlay 实测；iOS 18–26 的旧场景入口未在模拟器运行。

- 小说样本 1355 在 TVOut 关闭时可正常阅读；正在阅读第 2 章时开启 TVOut，外屏显示该章独立排版，iPad 切为触控板。未得到独立外屏场景时的本机阅读已覆盖，但没有模拟真实接收端只提供普通镜像的情况。
- 先开启 TVOut，再冷启动进入智能漫画样本 1356，未触摸设备即自动接管。触控板打开并关闭目录；断开 TVOut 后本机仍在第 2 话第 1/2 页，章节标识、图片索引和时间戳不变。
- 用触控板打开评论并进入本机编辑器，填入未提交的草稿。输入前后外屏黑帧逐字节一致；断开 TVOut 后保留草稿和键盘焦点。手动放弃草稿并关闭本机评论后，回到原阅读位置，章节锚点、偏移、进度和时间戳逐字节一致。

证据：`/tmp/yamibox-airplay-qa/`。

### 无线实机验收步骤（待验）

1. 准备支持 AirPlay 的 iPhone 或 iPad 与接收端（如 Apple TV 或启用 AirPlay 接收的 Mac），按 [Apple 的屏幕镜像指南](https://support.apple.com/zh-cn/102661)完成连接。设备和接收端在同一 Wi-Fi 下，从「控制中心 → 屏幕镜像」选接收端；不使用 App 内连接入口。
2. 分别验证「先连接再打开小说或漫画」和「正在阅读时连接」。书架和论坛不自行打开作品；进入有效阅读器后，电视显示独立排版的正文，设备在外屏首帧就绪后切换为触控板。只有电视正文与设备触控板分开显示，才算独立外屏接管；两边显示同一画面只是系统镜像。
3. 用触控板打开和关闭外屏目录、评论并推进阅读，记录章节及正文锚点或漫画图片位置。在控制中心选「停止镜像」，返回 App 后应在本机按本机布局接着读，不要求两种布局的页码相同。
4. 重新连接，在外屏打开评论编辑，在设备键入一段未提交文字。独立外屏应遮黑；停止镜像后草稿仍在且未提交，退出编辑后回到本机阅读。另测切到其他 App 时停止 App 自己的外屏呈现，返回后仅在同一会话和外屏仍可用时恢复。
5. 如果接收端只提供普通镜像，验证设备保持可操作的本机阅读；不要把系统镜像的画面或隐私行为当作 App 独立外屏的行为。记录设备、系统和接收端版本，以及独立外屏、仅镜像或接管失败的实际结果。
