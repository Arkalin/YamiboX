# 小说进度链路优化与验证

## 实现边界

页面结构及查询索引由 `NovelReaderPresentationStructure` 持有，以创建时的 UUID 标识；
候选结构与 runtime transaction 一起提交。当前位置、页内进度和缓存元数据不改变结构身份。
公开 presentation 的数组通过 Swift 写时复制共享，不使用整份 presentation 的哈希作为缓存键。

会话级 UI 缓存复用章节标题、刻度、拖动目标、附页和卷页序列。普通位置更新只刷新动态字段；
跨章节才更新激活刻度。附页键不含当前位置和 revision，卷页序列只依赖结构、双页模式及方向。
视口以结构身份和渲染参数判断内容刷新，选择位置仍独立更新。Chrome 的快照和设置独立观察。

保留 2% 发布阈值、精确位置采样、原百分比公式、阅读锚点、持久化、单／双页与翻页方向规则。
不修改 TextKit 排版、正文绘制、漫画、图片解码、数据库或依赖。没有新增测试文件或 target。

## 诊断方式

在启动进程时显式设置 `YAMIBOX_READER_PERF=1`，不要改共享 scheme。例如已安装 Debug app 时：

```sh
SIMCTL_CHILD_YAMIBOX_READER_PERF=1 xcrun simctl launch <SIMULATOR_UDID> com.arkalin.YamiboX.debug
```

需先结束已在运行的旧进程，启动环境才会生效。统一日志中筛选 `Reader presentation`：

- `counts`：`structures`、`positions`、`chrome`、`attached`、`curl` 累计次数。
- `structure`、`position`、`chrome-index`、`chrome-position`、`attached-information`、`page-curl-sequence`：对应局部操作的毫秒耗时。
- 关闭计时开关时不会读取时钟或输出逐次日志；计数仍可通过现有 debug state 查询。

结构计数包含实际创建过、随后可能被丢弃的候选结构。附页及卷页缓存按需构建，因此 `counts`
行可能先于当前帧的懒加载。内存警告主动释放 UI 派生缓存，下一次使用时重建不属于失效错误。
菜单显示／隐藏会改变附页信息展示模式，允许附页缓存重建。

## 2026-09-19 验证记录

环境：Xcode 27.0（27A266a），iOS 27.0 Simulator，iPhone 16 与 iPad Pro 13-inch（M5）。
构建入口为 `YamiboX` scheme；不使用旧 `swift test` 或已移除的 UI host。
iPhone Debug、iPad Debug、iPhone Release 构建均成功，`git diff --check` 通过。

### 设备交互与缓存计数

- iPhone 短内容 576423：恢复 `3/4、67%` 与修改前一致；正反滑动、卷页、末页图片正常。
- iPhone 中内容 570293：竖向慢滚、快滚、模式切换、关闭重开。滚动期间 `positions=2→22`，
  `structures=3/chrome=3/attached=3/curl=1` 不变；末页 `22/22、100%` 重开仍一致。
- iPad 长内容 568841：当前论坛页含 406 个阅读页。横屏双页滑动／卷页、左右翻页方向、跨章、
  目录跳至 `375/376、92%` 及已有书签返回 `7/8、2%`。同一结构内四类静态构建计数均不增长。
  改变方向时结构按规则重建。没有重置数据；验证结束恢复设备原阅读设置。
- 最终包另做 iPhone 冒烟（可执行文件时间 17:09:11）：中等内容连续倒翻、切滚动、滚至末尾、
  切回翻页均正常，进度到达 100%，图片可见，无退出；覆盖最后的设置观察边界与初始索引复用修改。

Debug 交互计时仅用于观测更新链路，不是性能收益对照：

| 采样 | 数量 | 中位数 ms | P95 ms |
| --- | ---: | ---: | ---: |
| iPhone Core position | 27 | 0.006958 | 0.013583 |
| iPad Core position | 8 | 0.012792 | 0.026125 |

### 优化构建的合成对照

临时诊断程序在同一 iPhone 模拟器运行，链接 Release Core，UI 相关实际源码以 `swiftc -O`
编译。比较保留的公开构造路径（每次重新生成 progress projection 和 chrome snapshot）与
索引化 projection 加复用 snapshot。每组 20 次预热、400 次采样，消费结果校验和以防计算被移除。
页面为合成数据，正文不参与排版；性能组全部属于同一论坛内容页，每 20 页一个章节，包含跨章跳转。

| 页面数 | 原路径中位数 ms | 索引路径中位数 ms | 原路径 P95 ms | 索引路径 P95 ms |
| ---: | ---: | ---: | ---: | ---: |
| 23 | 0.051209 | 0.048708 | 0.066625 | 0.061666 |
| 1,000 | 0.102375 | 0.060917 | 0.120167 | 0.064417 |
| 10,000 | 0.524416 | 0.063833 | 0.591709 | 0.068708 |

这是 **projection + chrome 更新** 的局部对照，不包括原页面结构重建、TextKit、视口绘制、
持久化或图片管线，不能换算为整机帧率提升或完整阅读链路的加速倍数。

另以 0／1／4／7／23／257 页、多论坛页边界、无章节、重复／乱序章节、单／双页、左右方向、
翻页／滚动模式以及越界选择构造了 12,160 次新旧结果对比，页码、百分比、章节刻度、拖动目标、
标题查表、双页摘要和剩余页数无差异。诊断是临时可执行程序，没有创建单元测试或测试 target。

本机诊断源及输出：`/tmp/reader-progress-diagnostic.swift`、`/tmp/run-reader-progress-diagnostic.sh`、
`/tmp/reader-progress-diagnostic-results.log`；设备日志为 `/tmp/yamibox-reader-perf-device.log` 与
`/tmp/yamibox-reader-perf-ipad.log`。临时目录内容不随仓库分发。

## 尚未完成的验收

- 尚无真机帧率、峰值内存和 Instruments 分配数据，也没有真实短／长小说的完整链路优化构建前后对照。
- 连续设置请求的取消／失败竞态已检查提交边界，但未做设备故障注入；预取最大论坛页数变化、刷新失败、
  搜索跳转、quiet 主题及内存警告仍缺专项设备覆盖。
- iPad 实测文档为偶数页；末尾奇数单页、无章节、单页场景只覆盖了派生数据对比，未全部设备实测。
- 图片锚点切换竖滚后最初两次滑动的进度未立即变化，后续持续更新正常；末图关闭重开观察到约 40pt
  视觉偏移，页码／百分比及章节一致。未完成旧版同操作对照，不能认定为本次回归或宣称已消除。

因此，构建及已列交互／复用检查通过，不代表完整性能验收全部完成。
