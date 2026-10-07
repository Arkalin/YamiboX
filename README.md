<p align="center">
  <img src="YamiboX/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="128" alt="Yamibo X icon">
</p>

<h1 align="center">Yamibo X</h1>

<p align="center">
  <strong>简体中文</strong> · <a href="README.zh-Hant.md" lang="zh-Hant">繁體中文</a>
</p>

<p align="center">
  面向百合会论坛的非官方 iOS 综合客户端
</p>

<p align="center">
  <a href="https://github.com/Arkalin/YamiboX/releases"><img src="https://img.shields.io/github/v/release/Arkalin/YamiboX?style=flat-square&label=%E4%B8%8B%E8%BD%BD&color=2f6f73" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/平台-iOS%2018.0%2B-247344?style=flat-square" alt="iOS 18.0+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/许可-AGPL--3.0-1f5f9c?style=flat-square" alt="AGPL-3.0 License"></a>
</p>

<p align="center">
  <a href="#安装与更新">安装与更新</a> ·
  <a href="#功能概览">功能概览</a> ·
  <a href="https://github.com/Arkalin/YamiboX/wiki">用户手册</a> ·
  <a href="#开发者">开发文档</a> ·
  <a href="https://github.com/Arkalin/YamiboX/issues">问题反馈</a>
</p>

---

Yamibo X 是面向百合会论坛的非官方 iOS 综合客户端，使用 SwiftUI 与 UIKit 构建原生界面，整合论坛浏览与互动、书架、收藏管理、小说阅读和漫画阅读。支持 iPhone 与 iPad，并提供简体中文和繁体中文界面。

## 安装与更新

**系统要求** · iOS 18.0 及以上，支持 iPhone 和 iPad。

从 [Releases](https://github.com/Arkalin/YamiboX/releases) 下载最新的 `.ipa`，通过 [AltStore](https://altstore.io) 等工具签名安装；也可添加下方软件源，在 AltStore 内安装和更新。

<p align="center">
  <a href="https://celloserenity.github.io/altdirect/?url=https://raw.githubusercontent.com/Arkalin/YamiboX/main/app-repo.json">
    <img src="https://github.com/CelloSerenity/altdirect/blob/main/assets/png/AltSource_Blue.png?raw=true" alt="添加 AltStore 软件源" width="200">
  </a>
</p>

**检查更新** · 在“我的 → 设置 → 关于”中查看新版本与更新说明，或通过 AltStore 软件源更新。

## 功能概览

### 阅读与书架

- **书架与续读**：展示最近阅读的小说和漫画，可分别配置数量或混合展示，支持仅显示收藏作品和自定义书架背景。
- **阅读模式**：按板块配置普通帖子、小说、漫画或智能漫画模式，也可在阅读时切换。小说与漫画均支持横向分页和纵向滚动；分页动画可选无动画、滑动、卷页或快速淡入淡出，支持翻页方向与点击区域设置，并按可用空间自动适配双页。
- **小说阅读器**：支持字体导入与管理、字号、行距、字距、页边距、正文图片、简繁转换，以及粗体、颜色、注音、引用等原帖格式的显示开关。
- **漫画阅读器**：支持画面缩放、适配方式和边缘填充；智能漫画可识别、聚合同一作品的章节帖子，并提供目录编辑及列表／网格浏览。
- **阅读工具**：支持章节目录、阅读进度保存、书签、文本与图片摘录；“我的喜欢”可按作品和内容类型浏览、搜索。阅读器提供沉浸模式，以及“液态玻璃”和“图书”两种工具栏样式。
- **章节评论与外设**：支持查看评论、对话和评分理由，发表章节评论及配置屏蔽规则；支持 Apple Pencil（含 Pro）、游戏手柄和键盘操作，并可自定义按键绑定。

### 论坛与收藏

- **原生论坛浏览**：支持板块、帖子、搜索、标签、公告、用户空间、日志与积分记录；暂不支持的站内页面通过内置网页浏览器打开。可识别剪贴板中的论坛链接并提示打开。
- **发帖与互动**：原生编辑器支持可视化 BBCode、格式编辑、表情、图片与附件上传，以及按账号保存草稿；支持发帖、回复、撰写日志、评分和点评。
- **账号与消息**：支持多账号管理、私信与消息提醒、未读角标和论坛黑名单；提供手动签到，以及通过 iOS 快捷指令自动化执行签到。
- **收藏管理**：支持论坛收藏同步、分类、合集、标签、手动排序、搜索、批量操作与封面管理；可检查作品更新、接收更新通知并管理更新未读标记。

### 下载、同步与个性化

- **离线下载**：统一管理小说、漫画、智能漫画和论坛附件的下载队列与本地内容，支持暂停、继续和失败重试，已下载小说可自动更新。iOS 26 及以上可申请后台持续下载并显示系统进度；是否获准及持续时长由系统决定，不保证强制退出后继续下载。
- **WebDAV 同步**：可按类别选择同步收藏、喜欢、书签、阅读进度、封面配置、应用设置、漫画目录和浏览记录，支持手动与自动同步。
- **界面定制**：支持自定义应用主题、书架和开屏背景、底部导航顺序及启动页；书架、消息、历史、喜欢可作为可选导航项。iPad 支持侧栏、自适应布局和多窗口阅读。

## 数据与安全

- 登录状态、收藏、历史、阅读进度、下载内容和缓存等数据保存在设备本地或来自百合会论坛账号本身。
- WebDAV 同步直接连接用户配置的服务器，密码保存在系统钥匙串中。同步数据会核对论坛账号，但不同账号的云端路径需自行分开，本机阅读资料并不全部按账号隔离。
- WebDAV 不同步离线下载；封面和图片摘录只同步记录与来源信息，不传输图片文件。应用设置只同步导航、启动页和网页导航栏偏好，不是完整设置备份。
- 封面图片独立持久化保存，不随普通图片缓存清理或容量淘汰而移除；可在存储设置中单独管理。
- 请只从本仓库 Releases 或上方 AltSource 安装 `.ipa`，避免使用来源不明的改包版本。
- 清理应用数据、卸载应用或更换设备可能导致本地历史、下载内容、缓存和设置丢失。

## 内容边界

- 本项目为非官方客户端，与百合会论坛运营方无隶属关系。
- 请遵守目标论坛规则、版权要求以及所在地法律法规。
- 论坛内容、图片和用户发表的信息来自原站点，其版权与内容责任归原始来源所有。
- 本项目在功能设计上参考了相关上游项目，相关来源与许可证信息请同时参考本仓库的 [LICENSE](./LICENSE)。

## 开发者

从[开发文档索引](docs/README.md)开始，查阅本地开发、架构专题、回归验证和发布维护说明。用户操作指南统一维护在 [GitHub Wiki](https://github.com/Arkalin/YamiboX/wiki)。

### 项目结构与依赖

[`Package.swift`](Package.swift) 定义 `YamiboXCore` 和 `YamiboXUI` 两个模块，UI 单向依赖 Core：

| 目录 | 职责 | 组织方式 |
| --- | --- | --- |
| [`Sources/YamiboXCore`](Sources/YamiboXCore) | 业务模型、应用流程、网络、解析、同步与持久化 | `Domain` · `Application` · `Data` |
| [`Sources/YamiboXUI`](Sources/YamiboXUI) | 功能界面、共享 UI、平台实现与应用装配 | `Features` · `SharedUI` · `Platform` · `AppEntry` |
| [`YamiboX`](YamiboX) | App 入口、资源与系统配置 | [`YamiboX.xcodeproj`](YamiboX.xcodeproj) |

模块边界与代码归属见[项目结构](docs/architecture.md)，开发与验证约定见 [`AGENTS.md`](AGENTS.md)。

主要依赖为 [`GRDB.swift`](https://github.com/groue/GRDB.swift)（数据库）、[`Kanna`](https://github.com/tid-kijyun/Kanna)（HTML 解析）和 [`Nuke`](https://github.com/kean/Nuke)（图片加载），具体版本以 `Package.swift` 为准。

### 本地开发

**工具链** · Swift 6.2+，部署目标 iOS 18+，CI 使用 Xcode 27。

**开发环境** · iOS 模拟器，`YamiboX-Local` Scheme，`Debug-Local` 配置。安装标识为 `com.arkalin.YamiboX.local`，与普通 Debug 和正式版隔离。

在仓库根目录查看可用模拟器，然后将下方 `<SIMULATOR_UDID>` 替换为所选 iOS 模拟器的标识：

```bash
xcrun simctl list devices available

xcodebuild build \
  -project YamiboX.xcodeproj \
  -scheme YamiboX-Local \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>'
```

也可使用 Xcode 打开工程，选择 `YamiboX-Local` 和 iOS 模拟器。运行前按[测试 App 启动参数](docs/tests/launch-arguments.md)准备本地论坛；默认地址为 `http://127.0.0.1:8088`，每次启动都须通过参数传入。

> 安装到模拟器的构建须保留签名，确保 Keychain 正常工作；`CODE_SIGNING_ALLOWED=NO` 仅用于不安装运行的编译检查。

### 验证

架构边界检查：

```bash
bash scripts/check-architecture.sh
```

CI 执行架构检查和模拟器编译，配置见 [Swift 工作流](.github/workflows/swift.yml)。

## 许可与致谢

本项目依据 [GNU AGPL-3.0](./LICENSE) 发布。

第三方依赖和相关项目以其原作者或原项目的许可证声明为准。

感谢以下项目的原作者与贡献者，Yamibo X 的功能设计参考了其中的相关实现：

- [prprbell/YamiboReaderPro](https://github.com/prprbell/YamiboReaderPro)
- [flben233/YamiboReader](https://github.com/flben233/YamiboReader)
- [LittleSurvival/yamibo-app](https://github.com/LittleSurvival/yamibo-app)
- [KrelinnBios/YamiboReaderLite](https://github.com/KrelinnBios/YamiboReaderLite)

## 反馈与贡献

欢迎通过 [Issue 模板](https://github.com/Arkalin/YamiboX/issues/new/choose) 提交使用问题、兼容性问题、功能建议或文档问题。参与代码、文档或本地化改进前，请阅读[贡献指南](CONTRIBUTING.md)，了解开发环境、验证要求与 PR 提交流程。
