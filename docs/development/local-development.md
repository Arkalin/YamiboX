# 本地开发入门

开发、测试与交互验证默认使用本地论坛和模拟器上的 **YamiboX-Local**。不要用普通 `YamiboX` Debug/Release App 或生产论坛替代本地环境；特殊环境需要明确授权。

## 工具链与工程入口

| 项目 | 当前要求或约定 |
| --- | --- |
| 主机 | 能运行所选 Xcode 的 macOS |
| Xcode | 以 Xcode 27 为当前开发基线，CI 使用 `xcode-27` runner |
| Swift | 6.2 及以上；[Package.swift](../../Package.swift)声明 `swift-tools-version: 6.2` |
| 部署目标 | iOS 18 及以上，支持 iPhone 与 iPad |
| 工程入口 | `YamiboX.xcodeproj`，App target 为 `YamiboX` |
| 开发 Scheme | `YamiboX-Local`，运行配置为 `Debug-Local` |
| 本地 App 标识 | `com.arkalin.YamiboX.local`，显示名为“Yamibo X 本地测试” |
| 验证设备 | 可用的 iOS 模拟器；Local 配置只支持 `iphonesimulator` |

首次使用 Xcode 时先完成组件安装，并在 Xcode 的 Settings 中安装需要的 iOS Simulator runtime。确认命令行工具使用完整 Xcode，而不是仅使用 Command Line Tools：

```sh
xcode-select -p
xcodebuild -version
swift --version
xcrun simctl list devices available
```

选择的 Xcode、编译器版本与模拟器 runtime 是不同信息。最低部署目标为 iOS 18，不代表任意旧 Xcode 都能编译当前源码；较新的系统能力由对应 SDK 和运行时可用性控制。

### Swift Package 依赖

Xcode 工程引用仓库根目录的本地 Swift Package。`Package.swift` 定义 `YamiboXCore`、`YamiboXUI` 两个 library target 及资源，UI 单向依赖 Core。第三方依赖为 GRDB.swift、Kanna 和 Nuke，版本以清单为准。

首次打开工程或执行构建时，Xcode/SwiftPM 会解析并下载依赖。需要 GitHub 网络访问，但不需要为项目安装 CocoaPods 或另建 workspace。不要为解决下载问题自行升级依赖、修改 package target 或改变语言模式。

## 准备本地论坛

App 仓库不包含 Discuz 服务端。现有本地论坛由独立的 [yamibo-dicuz-plugins 仓库](https://github.com/Yamibo300/yamibo-dicuz-plugins)提供，默认入口是 `http://127.0.0.1:8088`。

1. 启动 Docker Desktop，或确认 Docker Engine 与 Compose 可用。
2. 按服务端仓库的 [README](https://github.com/Yamibo300/yamibo-dicuz-plugins/blob/main/README.md)准备同级 `yamibo-bbs-dz35` 和 `yamibo-bbs-template` 仓库及其固定版本。来源和版本由服务端维护，不在此复制另一份安装清单。
3. 在 **服务端仓库根目录** 执行：

   ```sh
   docker compose up --detach --build --wait
   docker compose ps --all
   ```

4. 确认 `db`、`web`、`local` 的状态，并检查站点：

   ```sh
   curl -I http://127.0.0.1:8088/forum.php
   docker compose logs --tail 200 web local
   ```

5. 使用服务端 README 提供的本地测试账号，或在本地论坛建立专用演示账号。不要使用正式站账号，也不要把演示内容发布到生产论坛。

8088 是工作流默认端口，不是 App 的硬编码回退地址。服务不可达时先修复本地 Docker、端口或网络配置，不切换生产站继续验证。其他任务正在使用本地论坛时避免重置整个数据库，优先使用独立账号和帖子。

## 在 Xcode 中运行

1. 打开 `YamiboX.xcodeproj`，等待 package 解析完成。
2. 选择共享 Scheme `YamiboX-Local` 与一个 iOS 模拟器，不选择 `YamiboX` 或真机。
3. 按[测试 App 启动参数](../tests/launch-arguments.md)在 Edit Scheme → Run → Arguments 中配置本次启动地址；共享 Scheme 不预设地址。参数语法、页面目标及启动示例只在该文档维护。
4. 保持签名启用后构建并运行，进入 App 后使用本地测试账号登录。

Local App 与普通 Debug/正式 App 的安装标识、沙盒和账号 Keychain service 分离。首次绑定测试站或切换站点会清理 Local App 数据；同一站点重启保留数据。完整隔离规则和失败行为见启动参数文档。切换站点前应确认没有需要保留的演示数据。

从模拟器桌面冷启动不会恢复上一次地址，也不会回退生产站。请按启动参数文档重新启动；参数无法注入一个已经运行的进程。

## 命令行构建与安装

下面的命令在 **App 仓库根目录** 执行。先从可用设备列表选择一个 iOS 模拟器，用其实际 UDID 替换占位符。不要复制文档或旧日志中的设备 ID。

```sh
xcrun simctl list devices available

SIMULATOR_UDID='<SIMULATOR_UDID>'
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/YamiboX-Local-Development"

xcodebuild build \
  -project YamiboX.xcodeproj \
  -scheme YamiboX-Local \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -derivedDataPath "$DERIVED_DATA"
```

`YamiboX-Local` 使用 `Debug-Local`，不必额外覆盖 configuration。明确指定 DerivedData 可以确定安装产物路径，也避免在源码目录堆积构建文件。

若设备尚未启动，先执行下列第一行；设备已经启动时跳过 `boot`：

```sh
xcrun simctl boot "$SIMULATOR_UDID"
xcrun simctl bootstatus "$SIMULATOR_UDID" -b
xcrun simctl install "$SIMULATOR_UDID" \
  "$DERIVED_DATA/Build/Products/Debug-Local-iphonesimulator/YamiboX.app"
```

安装完成后，按[启动参数文档中的命令行示例](../tests/launch-arguments.md#页面目标与启动示例)启动 App。多台模拟器运行时，将示例中的 `booted` 换成所选 UDID，避免操作错误设备。

### 签名不能省略

用于安装和交互验证的模拟器构建必须保留签名，以便 Keychain 正常工作。不要为绕过签名错误安装 `CODE_SIGNING_ALLOWED=NO` 的产物；先检查所选 Scheme、Xcode 签名配置与账号环境。

`CODE_SIGNING_ALLOWED=NO` 仅适用于不安装、不运行的编译检查。编译成功的未签名产物不是后续交互验证的有效基础，需要重新签名构建。

## 本地验证与 CI 的区别

在 App 仓库运行架构检查：

```sh
bash scripts/check-architecture.sh
```

然后按改动影响范围选择 Local 构建和必要的模拟器操作，详见[验证指南](../tests/README.md)与[核心流程回归清单](../tests/regression-checklist.md)。当前 package 和工程没有测试 target，不使用旧项目的 `swift test` 或旧 UI 测试宿主替代验证；新增单元测试需要用户明确批准。

[Swift CI 工作流](../../.github/workflows/swift.yml)目前执行架构检查，自动选择可用 iPhone 模拟器，并使用 **`YamiboX` Scheme 与禁用签名的编译检查**。它不安装或运行 App，也不证明本地论坛、Keychain 或交互流程通过。这是现有 CI 事实，不是本地开发的 Scheme 选择规则；本地开发继续使用签名的 `YamiboX-Local`。

## 常见环境问题

| 现象 | 先检查什么 |
| --- | --- |
| `xcodebuild` 指向 Command Line Tools，或 SDK 不满足 | 用 `xcode-select -p` 与 `xcodebuild -version` 确认选中的完整 Xcode；在本机配置中选择正确的 Xcode |
| package 下载失败 | GitHub 连通性、代理与 Xcode package 解析日志；不要通过更改锁定版本“修复”网络问题 |
| destination 不存在 | 重新列出 `devices available`，检查 runtime 是否已安装，使用当前设备 UDID |
| App 显示启动配置错误 | 核对 Local Scheme、本次参数和互斥规则；从桌面冷启动未传地址会出现该错误 |
| Mac 能访问但 App 无法加载 | 确认实际安装的是 Local App、进程已按参数重新启动、Docker 端口未变化；再按启动参数文档排查 |
| Docker 启动失败 | 在服务端仓库查看 `ps --all` 和 `web/local` 日志，确认同级源码仓库及端口占用；不要在 App 仓库执行 Compose |
| Keychain 登录或凭据保存异常 | 确认安装产物保留签名、bundle ID 为 Local、没有误装编译检查产物 |
| 数据突然清空 | 检查是否首次绑定或切换了测试站身份；与单纯切换登录账号区分 |
| 图片太小，无法判断漫画缩放 | 现有 REST fixture 包含 8×8 像素附件，使用实际尺寸的原创或获许可本地图片 |
| 快捷指令、后台唤醒或系统实时活动未出现 | 先检查 Local 环境限制及系统授权；模拟器和前台成功不能替代真实系统能力验收 |

问题记录应包含 App 版本、Scheme、Xcode/系统版本、站点地址、复现步骤和脱敏日志。不要把 Cookie、密码或完整用户私信提交到仓库或 Issue。

## 实现入口

- [共享 Local Scheme](../../YamiboX.xcodeproj/xcshareddata/xcschemes/YamiboX-Local.xcscheme)与 [Xcode 构建配置](../../YamiboX.xcodeproj/project.pbxproj)：运行配置、支持平台和安装标识。
- [YamiboForumEnvironment](../../Sources/YamiboXCore/Infrastructure/Networking/YamiboForumEnvironment.swift)：构建环境、站点与存储标识。
- [YamiboTestSiteBootstrap](../../Sources/YamiboXCore/App/YamiboTestSiteBootstrap.swift)：站点绑定与 Local 数据清理。
- [测试 App 启动参数](../tests/launch-arguments.md)：地址解析、直达导航及验证边界的唯一操作参考。
