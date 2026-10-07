# 开发文档

本文档集面向 YamiboX 的开发者与维护者，说明当前代码的边界、运行方式和验证方法。功能使用、安装及常见问题请阅读 [GitHub Wiki 用户手册](https://github.com/Arkalin/YamiboX/wiki)；项目介绍见[主 README](../README.md)。

## 从哪里开始

1. 阅读[本地开发入门](development/local-development.md)，准备工具链、本地论坛与测试 App。
2. 阅读[架构总览](architecture.md)，确认 Core/UI 模块边界和代码归属。
3. 修改某项功能前阅读下面对应的技术专题，再以源码确认实现细节。
4. 按[验证指南](tests/README.md)选择检查；需要运行 App 时查阅[启动参数](tests/launch-arguments.md)。

开发与验证的约束以根目录 [AGENTS.md](../AGENTS.md) 为准。没有明确另行授权时，只使用模拟器上的 `YamiboX-Local` 和本地论坛，不使用正式 App 或生产论坛。

## 开发与维护

| 文档 | 要解决的问题 |
| --- | --- |
| [贡献指南](../CONTRIBUTING.md) | 如何反馈问题、准备贡献、验证改动与提交 PR |
| [本地开发入门](development/local-development.md) | 如何准备依赖、构建、安装和排查本地环境 |
| [架构总览](architecture.md) | 模块与业务目录如何划分，依赖如何约束 |
| [平台集成与资源维护](development/platform-and-resources.md) | 系统能力、平台实现、本地化、主题与资源如何接入 |
| [CI 与版本发布维护](development/release.md) | CI、版本身份、发布产物与软件源如何配合 |
| [图标设计与制作](design/app-icon.md) | 图标源文件、导出工具与系统显示检查如何维护 |

## 技术专题

| 文档 | 核心内容 |
| --- | --- |
| [阅读器设计](architecture/readers.md) | 小说与漫画内容管线、目录、排版、进度恢复及异步状态 |
| [论坛接入、认证与路由](architecture/networking-and-routing.md) | 请求、Cookie、HTML、站点适配与网页回退 |
| [账号与应用生命周期](architecture/account-lifecycle.md) | 应用装配、会话隔离、账号切换及任务停启 |
| [持久化、作品身份与迁移](architecture/persistence-and-identity.md) | 数据所有权、数据库、文件存储、作品身份及兼容边界 |
| [WebDAV 同步设计](architecture/webdav-sync.md) | 同步数据集、传输、合并、删除状态与命名空间 |
| [下载、缓存与封面存储](architecture/downloads-and-storage.md) | 队列、离线内容、图片缓存、封面和清理范围 |
| [编辑器与草稿设计](architecture/forum-editor.md) | BBCode、可视化投影、选区、附件、草稿与提交 |
| [Discuz 与 BBCode 兼容性参考](reference/bbcode-compatibility.md) | 标签支持、站点差异、源码保留与版本依据 |

## 验证与回归

| 文档 | 用途 |
| --- | --- |
| [验证与故障诊断指南](tests/README.md) | 根据风险选择检查，采集日志并说明证据边界 |
| [核心流程回归清单](tests/regression-checklist.md) | 账号、论坛、阅读、下载、同步、清理与 iPad 场景 |
| [测试 App 启动参数](tests/launch-arguments.md) | 参数语法、页面目标、启动示例及测试环境隔离规则 |
| [论坛标签回归](tests/forum-tags.md) | 标签解析、展示与导航的专项操作和预期 |
| [编辑器投影回归](tests/forum-composer-projection.md) | 源码与可视化编辑一致性的专项操作和预期 |

项目当前没有单元测试 target 或 UI 自动化测试宿主。回归清单描述需要检查的行为，不表示已经执行或通过；构建通过也不表示交互、网络或系统后台能力已经验收。

## 文档分工与维护约定

- **README 是入口**：介绍项目、展示主要能力并链接用户手册与开发文档，不复制完整教程。
- **Wiki 说明使用**：以用户任务组织步骤、真实截图、限制和排错；按已发布版本核对，不写内部类名和数据库实现。
- **`docs/` 说明实现**：以当前代码为依据，记录稳定的设计约束、接口关系和可执行验证方法，不堆叠修复经过。
- **OpenSpec 说明变更**：[OpenSpec 目录](../openspec/)中的提案和任务用于规划与跟踪。未完成方案不等于当前架构；不因重写文档改变其状态。
- **事实有来源**：依赖与 package target 以 [Package.swift](../Package.swift) 为准；App 构建配置以 [Xcode 工程](../YamiboX.xcodeproj/project.pbxproj)和共享 Scheme 为准；CI 以[实际工作流](../.github/workflows/swift.yml)为准。专题文档提供关键源码入口，而不是复制整个符号目录。
- **规范与结果分开**：回归步骤写操作与预期；某次执行的版本、环境、结果和限制属于该次验证记录，不把旧“通过”写成长期保证。
- **一处维护**：参数语法和页面目标只维护在启动参数文档；版本发布说明以 Releases 为入口；同一规则不在多篇页面复制完整列表。
- **允许删除**：陈旧、重复、一次性研究和过程文档在提取仍有效且独有的信息后删除，不默认搬入归档目录。Git 历史承担必要的追溯。
- **改动同步检查**：实现改变了契约、目录或操作入口时更新相关文档；删除或移动页面后修复相对链接、锚点及图片引用，不留下空白占位页。
- **示例不泄露数据**：测试、截图与日志使用本地演示数据，避免真实账号、Cookie、密码、私信和其他敏感内容。Wiki 图片展示真实 App 状态，不通过修图伪造功能。

文档改动通常只需要内容核对、链接检查与 `git diff --check`。操作步骤有疑问时再做针对性构建或交互验证，不为文档重写引入无关全量检查。
