# 验证与故障诊断

本文规定当前仓库的验证入口和证据要求，不是一次验收的通过报告。验证环境遵循 [AGENTS.md](../../AGENTS.md)：默认只使用签名的 `YamiboX-Local`、iOS 模拟器和本地论坛 `http://127.0.0.1:8088`。站点不可用时先修复本地环境，不切换正式 App 或生产论坛。

## 按变更选择检查

| 变更 | 必要检查 | 不能据此证明 |
| --- | --- | --- |
| 文档、链接、图片 | 核对代码与文案、链接和资源路径、实际渲染、`git diff --check` | 功能已在设备上通过 |
| 模块边界、依赖、跨功能契约 | 架构检查、Local 构建、受影响流程 | 完整依赖图或所有运行时边界正确 |
| 网络、账号、同步、持久化 | Local 构建、本地成功/失败路径、重启与账号边界 | 生产站和远程服务兼容性 |
| 页面布局、阅读器、输入与选区 | Local 构建、实际交互、页面层级与截图；影响平板时补 iPad | 真机性能、IME 和外设的全部行为 |

现有 `Package.swift` 没有测试 target，UI 自动化测试及其专用宿主已移除。不要使用旧项目的 `swift test` 或旧 UI host 代替 App 验证；未经明确授权不得新增单元测试、测试文件或 target。若以后引入测试设施，按届时实际入口更新本指南。

必要检查通过后停止扩展，除非出现新修改、失败或尚未解决的疑问。验证失败先区分本次回归、既有缺陷和环境故障，不顺手修复无关问题。

## 静态检查与模拟器构建

在仓库根目录执行：

```sh
bash scripts/check-architecture.sh
git diff --check
xcrun simctl list devices available
```

架构脚本检查 Core/UI 的 import 边界，以及若干已知跨功能依赖泄漏；它不是完整的 Swift 符号依赖分析，也不替代编译。

从列表选择可用 iOS 模拟器，将实际 UDID 填入下列变量。使用独立 DerivedData，避免把其他任务的旧构建当成本次产物：

```sh
SIMULATOR_UDID='<SIMULATOR_UDID>'
DERIVED_DATA='/tmp/yamibox-local-validation'
xcodebuild build \
  -project YamiboX.xcodeproj \
  -scheme YamiboX-Local \
  -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" \
  -derivedDataPath "${DERIVED_DATA}"
```

`YamiboX-Local` 使用 `Debug-Local`，产品为 `YamiboX.app`，Bundle ID 为 `com.arkalin.YamiboX.local`。需要交互时保留签名，构建完成并确认成功后安装：

```sh
xcrun simctl bootstatus "${SIMULATOR_UDID}" -b
xcrun simctl install "${SIMULATOR_UDID}" \
  "${DERIVED_DATA}/Build/Products/Debug-Local-iphonesimulator/YamiboX.app"
```

若设备尚未启动，先通过 Simulator 或 `simctl boot` 启动；不要终止其他任务占用的模拟器。启动、结束旧进程、页面直达和数据隔离规则均见 [测试 App 启动参数](launch-arguments.md)，不在此复制参数表。每次启动显式提供本地站地址，从桌面冷启动不能恢复它。

仅做编译检查时可以追加 `CODE_SIGNING_ALLOWED=NO`，但不能安装该产物验证 Keychain 或账号行为。[CI 工作流](../../.github/workflows/swift.yml) 当前使用普通 `YamiboX` Scheme 并关闭签名，属于 CI 编译门禁，不改变本地交互验证的环境约定。

## 交互与截图

使用 [核心流程回归清单](regression-checklist.md) 选择受影响场景。每个场景先写明前置数据与预期，再操作并记录实际结果，不能将清单本身标为通过。

- 本地论坛准备独立测试账号、小说/漫画章节、普通帖子、图片与附件；涉及分页、失败或队列进度时，数据规模应足以触发相应路径。
- 用页面层级或辅助功能信息确认按钮、弹窗、当前页面与可操作状态；结合真实触摸、滚动和输入，不仅凭截图猜测操作结果。
- 图片加载及动画结束后再截图。检查原图与文档显示尺寸，确认文字、按钮和重点内容清晰，无无关键盘、加载占位或弹窗遮挡。
- 截图只证明该时刻的画面。进度恢复、保存、离线文件、提交结果和同步都需后续操作或日志确认。
- 使用原创或有许可的图片；本地默认 8×8 像素 fixture 不适合验证常规漫画缩放和清晰度。不要用修图掩盖 App 布局错误。
- 不并行修改其他验证会话使用的账号、论坛帖子或 App 数据。需要重置时，仅处理本次隔离的本地测试数据。

截图可以通过模拟器的原生导出功能或命令采集：

```sh
xcrun simctl io "${SIMULATOR_UDID}" screenshot /tmp/yamibox-local-validation.png
```

## 日志与性能诊断

应用的统一日志 subsystem 固定为 `com.arkalin.YamiboX`，**不是 Local Bundle ID**。常用 category 包括 `app`、`account`、`networking`、`forum`、`reader`、`downloads`、`sync`、`persistence`、`library` 与 `offline-cache`。最后一项是技术缓存日志，不代表用户下载队列。

按实际 UDID 采集统一日志，必要时增加 category 条件；记录操作开始时间，结束采集后再比较：

```sh
xcrun simctl spawn "${SIMULATOR_UDID}" log stream \
  --level debug \
  --predicate 'subsystem == "com.arkalin.YamiboX"'
```

网络故障优先查看 App 的「设置 → 数据存储 → 网络日志」、页面错误详情以及本地论坛服务日志。先确认请求是否到达、状态码和响应结构，再区分认证、路由、解析与页面状态问题。导出前检查并脱敏 Cookie、口令、服务地址中的凭据、私信和个人内容，不因为是本地环境就公开完整认证材料。

小说阅读器已有可选诊断开关 `YAMIBOX_READER_PERF=1`。在按[启动参数文档](launch-arguments.md)启动新进程时，以 `SIMCTL_CHILD_YAMIBOX_READER_PERF=1` 注入环境；不修改共享 Scheme，不使用普通 Debug App。已运行进程不会接收新环境变量。

筛选 `Reader presentation` 可观察 `structures`、`positions`、`chrome`、`attached`、`curl` 累计次数及局部操作耗时。同一内容结构内普通位置变化应主要更新动态字段；旋转、排版、方向、内容结构变化或缓存释放可能引起重建，不能只凭计数增加判断回归。对照时固定内容、设置、操作和构建模式，区分启动预热与稳定采样。

模拟器局部耗时不等于整机帧率或完整阅读链路收益。需要性能结论时分别测量排版、绘制、图片管线、持久化和内存，并说明设备及方法；历史报告数字不能替代当前版本数据。

## 证据与未覆盖边界

验证记录至少包含：代码提交或工作区状态、工具链、App 配置、模拟器型号/系统版本、站点、前置数据、步骤、预期、实际结果、截图/日志路径与未覆盖项。凭据不进入记录。长期文档保留稳定方法与契约，临时产物存放在隔离工作目录；不要把 `/tmp` 链接当作随仓库分发的证据。

构建、前台下载和模拟器截图不能证明真机帧率、峰值内存、后台持续活动、实体键盘/手柄/Apple Pencil 全部正确。Local 版不运行后台自动唤醒或签到快捷指令；模拟器可能不支持后台持续处理授权。涉及这些能力时明确记录“未验证”及原因，真机或其他环境须另获授权，不能切换生产环境绕过限制。

专项参考：[论坛标签](forum-tags.md)、[可视编辑器块边界与选区](forum-composer-projection.md)。
