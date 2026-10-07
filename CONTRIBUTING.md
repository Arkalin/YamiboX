# 贡献指南

欢迎参与 YamiboX。问题反馈、功能建议、文档修正、简繁体本地化和代码改进都很有帮助。讨论可使用简体或繁体中文，请围绕具体问题交流，并尊重其他贡献者。

## 提交 Issue

先查阅 [用户手册](https://github.com/Arkalin/YamiboX/wiki)，并搜索已有的 [Issues](https://github.com/Arkalin/YamiboX/issues) 和 [Pull requests](https://github.com/Arkalin/YamiboX/pulls)，避免重复报告。同一问题可在原 Issue 补充复现信息，不同问题请分别提交。

在 [Issue 入口](https://github.com/Arkalin/YamiboX/issues/new/choose) 选择合适的模板：

- **Bug 反馈**：提供 App 版本与安装来源、设备和系统版本、复现步骤、预期与实际结果。阅读器问题请注明阅读模式、翻页方式和相关设置；下载、同步或账号问题请注明必要的前置状态。
- **功能建议**：先说明使用场景和遇到的问题，再描述期望行为及现有替代方法。较大的功能、架构或依赖变更建议先讨论，避免投入后方向不一致。
- **文档问题**：指出 README、开发文档或 Wiki 的具体位置、错误或缺漏，以及建议的修正。

不适合上述分类的内容可以使用空白 Issue。无需具备开发环境，也无需为了报告日常使用中发现的问题另行部署本地论坛。

### 保护隐私与内容

Issue、PR、截图和附件通常是公开的。提交前请移除密码、Cookie、Token、WebDAV 凭据、私信和其他个人信息；日志只保留定位问题所需的最小片段。论坛帖子、图片和附件请使用原创、获许可或脱敏后的最小示例，不要上传整份用户数据库或论坛内容备份。

涉及凭据泄露或可利用的安全漏洞时，不要在公开 Issue 中贴出敏感细节。如果仓库的 Security 页面提供私密报告入口，请使用该入口；否则先与维护者确认私密沟通渠道，不要假定公开 Issue 是私密的。

## 准备开发环境

推荐的本地环境搭建步骤见 [本地开发入门](docs/development/local-development.md)。**Local 验证不是外部贡献者提交 PR 的必要条件**：没有本地论坛或 Local 测试环境时，可以使用其他可用环境进行适当验证，也可以提交改动并说明未验证项与原因。

- 使用 macOS、支持 Swift 6.2+ 的 Xcode 与 iOS 模拟器；当前开发基线为 Xcode 27，最低部署目标为 iOS 18。
- 外部贡献者可 Fork 仓库并在自己的功能分支上工作，PR 通常提交到本仓库的 `main`。
- 打开 `YamiboX.xcodeproj`，由 Xcode 解析 Swift Package 依赖。依赖和 target 配置以 [Package.swift](Package.swift) 为准。
- 有本地测试环境时，推荐使用 `YamiboX-Local` Scheme、`Debug-Local` 配置和 `com.arkalin.YamiboX.local` App，与日常使用的数据隔离。
- 使用 Local 环境时，本地论坛默认地址为 `http://127.0.0.1:8088`。准备方式见本地开发文档；每次运行 App 的参数、导航目标和示例统一见 [测试 App 启动参数](docs/tests/launch-arguments.md)，不要将地址硬编码为 App 回退值。
- 没有 Local 环境时，可在自己可用的构建配置、模拟器或设备上验证，并在 PR 中注明实际环境。请保护已有数据，不要在生产论坛进行破坏性操作、批量造数或压力测试。
- 用于安装和交互验证的构建须保留有效签名，确保 Keychain 正常工作。禁用签名的产物只用于编译检查，不用于安装验证。

[AGENTS.md](AGENTS.md) 与开发文档中的默认 Local 工作流用于约束本仓库的自动化代理操作，不要求其他贡献者先搭建同样的环境。使用代理时仍应遵循适用的代理约束。

## 修改代码与文档

- `Sources/YamiboXCore` 负责数据模型、应用流程、网络和持久化；`Sources/YamiboXUI` 负责界面和平台实现，UI 单向依赖 Core。先阅读 [架构总览](docs/architecture.md) 与相关 [技术专题](docs/README.md)。
- 遵循相邻代码的命名、格式、并发与错误处理方式，优先复用现有 API。每个 PR 聚焦一个问题，不夹带无关重构、格式化、依赖升级或生成文件。
- 界面改动考虑 iPhone/iPad、自适应布局和辅助功能；涉及文案时检查简体与繁体资源，维护方式见 [平台集成与资源维护](docs/development/platform-and-resources.md)。
- 行为、配置或操作方式变更时同步更新相关文档。不要在多个文档中复制启动参数或服务端配置清单。
- 不提交本机路径、签名凭据、账号数据、构建产物或临时诊断文件。新增资源和第三方代码须有可使用的授权，并保留必要的来源与许可声明。
- 使用 AI 辅助时同样遵循 `AGENTS.md`，提交者仍需理解改动并核实验证结果，不将未经执行的检查写成通过。

## 验证改动

按 [验证指南](docs/tests/README.md) 选择与风险相称的检查，不要求每个 PR 都运行完整回归：

| 改动类型 | 验证要求 |
| --- | --- |
| 文档、模板、链接 | 检查内容、链接、格式和适用的结构语法，运行 `git diff --check`；无需 App 构建 |
| Swift 代码、依赖或模块边界 | 架构检查、可用环境中的构建，并尽可能验证受影响流程；无法执行的检查说明原因 |
| UI、阅读器与交互 | 在上述基础上检查实际操作与截图；影响 iPad 时补充 iPad 验证 |
| 网络、账号、同步与持久化 | 检查相关成功/失败路径，以及适用的重启、账号隔离或数据兼容性场景 |

代码改动可先在仓库根目录执行静态检查：

```sh
git diff --check
bash scripts/check-architecture.sh
```

如已准备 Local 环境，可按下例构建，将占位符替换为当前可用的 iOS 模拟器 UDID。使用其他环境的贡献者按实际配置构建并记录结果，无需为了提交 PR 搭建 Local 环境。

```sh
xcrun simctl list devices available

xcodebuild build \
  -project YamiboX.xcodeproj \
  -scheme YamiboX-Local \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>'
```

按 [核心流程回归清单](docs/tests/regression-checklist.md) 选取受影响场景。记录环境、步骤、实际结果和未覆盖项；无法验证时说明原因，不用编译成功代替交互或真机能力验证。

当前工程没有测试 target，旧 UI 自动化测试及其专用宿主已移除，不使用旧项目的 `swift test` 流程。未经明确批准，不新增单元测试、单元测试文件或 target；认为需要时先在 Issue/PR 中提出并取得批准。

[Swift CI](.github/workflows/swift.yml) 当前执行架构检查和禁用签名的 `YamiboX` 模拟器编译，不安装或运行 App。CI 可提供编译结果，但不能证明交互验证通过；不要求外部贡献者额外完成 Local 验证。

## 提交 Pull Request

1. 保持改动范围清晰，提交前检查 diff，移除无关变更与敏感信息。
2. 提交标题采用 `type: lowercase imperative description`，不用 scope 或句末句号，例如 `fix: preserve reader progress after rotation`、`docs: clarify local setup`。
3. 按 PR 模板说明改动原因、主要变化、关联 Issue、验证结果和已知限制。没有关联 Issue 时填写“无”；仅真正解决问题时才使用 `Closes #123`。
4. UI 改动附脱敏截图或录屏；数据格式、迁移、同步或依赖改动说明兼容性与风险。不适用的模板项目明确标注，不要勾选未完成的检查。
5. 等待 CI 和维护者审阅，按反馈更新同一个 PR。文档或小型修复不必为了提交 PR 先创建 Issue。

普通贡献不需要自行递增版本号、创建发布标签或修改软件源；发布流程由维护者按 [发布维护文档](docs/development/release.md) 处理。

## 许可

项目采用 [GNU AGPL-3.0](LICENSE)。请确保自己有权提交相关代码、文档和资源，且贡献可按项目许可证分发；第三方材料保留其适用的许可与署名。
