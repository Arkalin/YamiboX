# Proposal

## Why

当前论坛通信、来源模型、阅读转换、会话、缓存和下载实现共处 `YamiboXCore`，仅增加 `YamiboXForumSource` target 仍会经 Core 间接依赖整个应用。需要同时建立可独立装配的来源实现和来源中立的消费边界，使论坛协议变化不再要求阅读器、书库或用户数据模块同步理解 Discuz。

## What Changes

- 在同一 package 的七模块布局中实际建立 `YamiboXForumSource`，仅依赖中立 Core 及明确允许的第三方实现；净化 Core/UI，按职责迁出其余业务和存储实现，不保留聚合 Legacy 模块。
- 保留已确认的 `Forum -> ForumSource` 公开 API 依赖。Reader、Library、UserData 和公共 UI 不直接或传递依赖 Source；App 负责显式装配，不能充当来源算法的替代实现。
- Source 提供两类出口：供 Forum 使用的论坛专用能力与模型，以及供阅读、详情、目录发现、远端收藏和更新检查使用的中立能力。来源标识、分页、作者范围、HTML、Cookie 和 Referer 由 Source 解释，不以改名后的论坛 DTO 冒充中立契约。
- 将传输、环境、会话有效性、安全验证、缓存字节、持久资源和诊断接入改为明确端口；移除来源对具体 Store、宿主启动参数、全局环境及隐式数据库初始化的依赖。非论坛网络访问不归入 Source。
- 分开来源缓存策略与存储执行、来源下载材料准备与持久队列、目录发现与本地编辑/身份提交、来源 URL 解析与应用展示决策。App 内适配器只转换和连接，不另建 Adapter target。
- 保持论坛功能、阅读与 Library 行为，以及已有数据库、账号 vault、下载文件、技术缓存、恢复身份和 WebDAV 载荷兼容；保留失败、取消、观察、账号代次和跨业务原子提交语义。
- 将 Source 独立装配、消费者替换、非法依赖负向检查和 Local App 兼容验证作为独立验收条件；不以“文件已移动”或“App 能编译”替代这些证据。
- **BREAKING**：调整内部 Swift 模块归属、公开工厂、初始化器和调用签名，仓库内消费者一起迁移；不承诺保留宽依赖包、具体实现默认参数或整模块重新导出。此处不包含用户数据格式的破坏性变更。

不新增正式第二数据源、来源选择 UI、动态插件、跨来源作品合并或通用社区产品；不拆数据库，不升级依赖，不借此改变本地数据的账号共享策略。

### Relationship to Existing Change

`enforce-reader-module-boundaries` 尚处于规划后的待实施状态，当前 manifest 仍只有 Core/UI。本变更沿用其七模块方向，细化 Source 的完整责任，并将其允许的 `Library -> ForumSource` 过渡边收紧为本变更交付时必须消失；目标图中的其他临时实现依赖同样不得永久保留。

本变更不假定旧变更已经实施，也不修改或完成旧变更的任务。共享的模块切换只实施一次：若从当前两模块起步，按本变更的协调切换批次落位；若旧变更先落地，复用已验证的代码并补齐剩余差距。两者不得并行执行相互覆盖的搬迁。Reader 内部封装、视口等旧变更专属验收仍按其自身标准核对，不能因本变更通过而自动标记完成。

## Capabilities

### New Capabilities

- `forum-source-boundaries`：来源及消费方的编译依赖、双类 API、算法所有权、独立装配和可失败的边界准入。
- `forum-source-runtime-contracts`：显式环境与会话、来源中立内容/资源、缓存与下载载荷、非论坛消费者接线，以及兼容和生命周期语义。

新增的是可验证的开发期装配和准入能力，不是重新描述现有论坛产品功能。当前 `openspec/specs/` 无主规格；旧变更的 reader capabilities 仍是未归档 delta，不在本变更中重复创建同名规格。

### Modified Capabilities

无。

## Impact

- 构建：`Package.swift`、`YamiboX.xcodeproj` 的直接 package products、统一架构检查及现有 CI 接线。
- 来源：当前 `Infrastructure/Networking`、`Infrastructure/HTML`、`Forum/Data`、账号远端仓储、收藏远端仓储、小说/漫画来源适配、评论解析与资源加载；按职责拆分，不整目录照搬。
- 消费者与装配：Reader、Library/ContentDetail、Forum、账号和设置依赖包、路由、AppEntry、平台 WebKit/后台桥接，以及 `YamiboAppContext`。
- 用户数据：论坛/投影缓存、`DownloadStore` 及载荷文件、账号与设置兼容编码、图片/封面存储、日志存储、身份事务和 WebDAV 内部子系统。
- 文档与验证：更新实际架构和相关专题，记录独立闭包、替换、负向检查及旧数据证据。仅使用本地测试 App/论坛；不新增单元测试、测试文件或测试 target，确需新增时另行申请。

本次 propose 仅创建本变更规划文件，不修改应用代码、既有变更或主规格，不启动实施。
