# CI 与版本发布维护

本文面向维护者，说明仓库现有的编译检查、发布身份、IPA 与更新源之间的关系。阅读或更新本文不等于获得发布授权；版本提交、创建 tag、推送、触发远端发布及破坏性恢复必须属于用户明确要求的操作。

## 事实来源与运行边界

| 来源 | 负责的事实 |
| --- | --- |
| [Swift 工作流](../../.github/workflows/swift.yml) | 架构检查、模拟器选择与编译入口 |
| [Release 工作流](../../.github/workflows/release.yml) | tag 触发、归档、IPA、GitHub Release 与更新源注册 |
| [发布身份校验脚本](../../scripts/validate-release-identity.sh) | 实际 Release 构建设置、tag 与 commit 一致性 |
| [Xcode 工程](../../YamiboX.xcodeproj/project.pbxproj)、[Info.plist](../../YamiboX/Info.plist) | 版本号、构建号、Bundle ID、签名与部署目标 |
| [更新源](../../app-repo.json)、[更新检查实现](../../Sources/YamiboXCore/Update/AppUpdateChecker.swift) | AltStore 源及应用内版本比较 |
| [发布流程](../../.agents/skills/release/SKILL.md)、[发布说明整理流程](../../.agents/skills/changelog/SKILL.md) | 维护者确认、构建号递增、说明与 tag 的准备要求 |

工作流当前使用 `xcode-27` runner，并输出 Xcode 和 Swift 版本。不要把 runner 标签当作任意本机上都存在的配置；环境问题应结合实际运行日志判断。

日常开发与交互验证仅使用 `YamiboX-Local`、`Debug-Local` 和本地论坛。具体环境、安装及启动见 [本地开发入门](local-development.md)与[测试 App 启动参数](../tests/launch-arguments.md)。本文描述普通 Scheme 在 CI 和正式归档中的既有行为，不授权把普通 App 安装到模拟器连接生产论坛验证。

| 配置 | Bundle ID | 用途 |
| --- | --- | --- |
| `Debug-Local` | `com.arkalin.YamiboX.local` | 仅模拟器，使用显式指定的测试论坛 |
| `Debug` | `com.arkalin.YamiboX.debug` | 普通 Debug，论坛环境为生产；不是默认验证 App |
| `Release` | `com.arkalin.YamiboX` | 正式分发与更新源匹配 |

## 编译检查与质量门禁

`swift.yml` 在推送 `main`、面向 `main` 的 Pull Request，以及被其他工作流通过 `workflow_call` 调用时运行：

1. checkout 代码，执行 `bash scripts/check-architecture.sh`。
2. 输出工具链版本。
3. 从 `simctl list devices available` 的 iOS 分组中选择最后一个可用 iPhone；没有候选或无法解析 UDID 时失败。
4. 使用普通 `YamiboX` Scheme 执行模拟器 `xcodebuild build`，设置 `CODE_SIGNING_ALLOWED=NO`。

这是架构规则检查与编译检查，不包含单元测试、UI 自动化、签名安装或论坛交互。架构脚本也不是完整的 Swift 符号依赖分析。CI 成功不能替代 Local App 的针对性行为验证；未签名编译产物不应用于需要 Keychain 的交互验收。

**发布前，应核对待发布 commit 对应的 Swift 运行确实成功。当前 `release.yml` 没有调用 `swift.yml`，也没有依赖其结果的 `needs` 质量门禁。** `workflow_call` 提供的是复用能力，不代表 Release 已自动执行它。维护者必须检查同一 SHA，不能拿其他 commit 或旧分支的成功记录代替。

## 版本、构建号与发布说明

### 发布身份

- `MARKETING_VERSION` 写入 `CFBundleShortVersionString`，约定 tag 为 `vX.Y.Z`。
- `CURRENT_PROJECT_VERSION` 写入 `CFBundleVersion`。发布准备时在当前值基础上加 1，不因主版本、次版本或补丁版本变化而重置。
- 更新应用 target 的各构建配置后核对一致性，不假设字段永远只出现两次。工作流不会自动递增构建号。
- 正式归档使用 `YamiboX` Scheme、`Release` 配置、`YamiboX` target 和 `generic/platform=iOS`。不能从 `app-repo.json` 最新记录或工程文件任意一处文字推断待发布版本。

身份校验脚本先调用 `xcodebuild -showBuildSettings -json`，从目标实际解析唯一、非空且不含空白的 `MARKETING_VERSION`，再检查：

1. tag 是有效 Git 引用，且恰好等于 `v` 加实际版本号；`v*` 只是工作流触发筛选，不是完整版本校验。
2. tag 能解析为 commit，当前 checkout 的 `HEAD` 就是该 commit。
3. 对 tag push 事件，触发 revision 解析为 commit 后也必须相同；手动 dispatch 则必须指定已有 tag。

校验不强制语义化版本格式、annotated tag、tag 位于 `main`、构建号递增或 Swift CI 成功。这些仍是发布准备要求，不应误写成已实现的自动检查。

### 发布说明传递链

根目录 `CHANGELOG.md` 被 [`.gitignore`](../../.gitignore) 忽略，是本地发布草稿，不是仓库公开日志，也不是 Wiki 的更新记录入口。丢失后可从 Git 历史重建，不应链接不存在的远端文件或将其强制入库。

准备发布时，将 `## Unreleased` 正文整理为用户能理解的 `### 新增`、`### 变更`、`### 修复` 分类；只保留有内容的分类，条目可带 `(短 hash · @作者)` 来源。确认后把正文原样写入 annotated tag message，不包含 `## Unreleased` 标题。不要只把版本号作为 tag message。

工作流按以下顺序选择说明：

1. 手动 dispatch 的非空 `release_notes` 输入。
2. 输入为空且 tag 为 annotated tag 时，使用 tag message。
3. 没有可用正文时，GitHub Release 仍请求生成说明；更新源使用“版本更新，详见 GitHub Release 说明”。

GitHub Release 创建命令始终带 `--generate-notes`，有正文时另带 `--notes`；更新源使用的是已解析的正文，不读取生成后的 GitHub Release 正文。注册更新源时，工作流剥除每行末尾以至少 7 位十六进制 hash 开始的来源括号，将 `### 分类` 转为 `【分类】`，供应用内纯文本显示。

## 准备与远端发布

### 无发布副作用的预检

以下检查不会创建 commit、tag 或 Release。远端查询需要已有 GitHub 访问权限；网络失败不能当作 CI 通过。

```sh
git status --short --branch
git rev-parse HEAD
git log -1 --format='%H %s'
git check-ignore -v CHANGELOG.md
bash scripts/check-architecture.sh
gh run list --workflow swift.yml --branch main --limit 10 \
  --json databaseId,headSha,status,conclusion,url
```

核对工作树、当前分支和目标 SHA 后，再从运行列表定位相同 `headSha` 且已完成、结论为成功的运行。`origin/main` 是本地记录；若未刷新，不能仅凭“与 origin/main 同步”的本地提示确认远端状态。发布准备阶段应先获取最新远端引用，再核对同步情况，不能用重置或强制覆盖来清空现有改动。

### 明确发版请求后的维护流程

1. 确认 `main`、工作树干净、与远端同步，并核对目标 commit 的 Swift CI。
2. 补齐本地 `Unreleased`；按变更建议版本号，向用户确认版本与完整发布说明。
3. 更新应用 target 的版本与构建号，核对各配置，按仓库约定提交版本变更。版本提交会改变 SHA，之前 CI 的通过不自动覆盖该提交；正式发布前还需核对最终目标 commit 的检查结果，不能依赖 tag 工作流补跑 Swift 门禁。
4. 创建 annotated tag，将确认的说明作为 message。推送 `main` 与 tag 会触发远端发布，是正式副作用，不能包含在普通文档维护或只读预检中。
5. 跟踪 Release 运行并核对资产与更新源。整理本地草稿为已发布版本，新增空 `Unreleased`，更新 `last-scanned`。

tag push 后的工作流依次执行：

1. checkout 对应 tag，获取完整历史，重新获取 tag 对象并校验发布身份。
2. 解析发布说明，以关闭签名的参数归档 `Release`。
3. 将归档中的 `YamiboX.app` 放入 `Payload/` 并压缩为 `YamiboX_v<版本>_unsigned.ipa`，计算文件字节数。
4. 使用仓库 token 创建对应 tag 的 GitHub Release，并上传 IPA。产物是未签名 IPA，安装需由侧载工具重新签名；这不是 App Store 发布流程。
5. 获取最新 `origin/main`，在 runner 切换到该分支，更新 `app-repo.json`，必要时提交 `Register v<版本> in app-repo.json` 并推送 `main`。

最后一步不是修改 tag 内的文件，也不移动 tag；它在当时最新的 `main` 上产生独立 bot commit。下一次维护前先检查并同步该提交，保留自己的未提交工作，不盲目执行覆盖操作。不要为了补注册而随意重新发布同一 tag。

### AltStore 源与应用内更新

工作流更新 `app-repo.json` 中 `apps[0].versions`：移除相同版本号的旧项，把本次记录插入首位，填写版本、UTC 发布时间、纯文本说明、Release 下载 URL 和 IPA 字节数。维护顶层身份、图标等字段时另行核对，不将其与每次版本注册混为一谈。

应用内默认读取 `main` 上的此文件，按当前 Bundle ID 查找应用，并比较 `versions` 第一项与当前版本，不扫描所有条目寻找最大版本。因此：

- GitHub Release 已创建而源注册失败时，IPA 可能已可下载，但 AltStore 或应用内更新尚未得到本次记录。
- 记录顺序有功能含义。重发旧版本可能将它置顶，不应把“更新源写入成功”当作“最新版本排序正确”。
- 源中只有正式 Bundle ID；Debug 和 Local ID 不匹配不是正式更新源失效，不能为验证更新而切换生产 App。
- bot 提交使 `main` 前进不表示 tag 内容改变。发布验证应分别记录 tag SHA、Release 资产与源提交。

## 失败诊断与恢复

先查看失败步骤和远端实际状态，区分“未发布”与“部分发布”。不要因工作流最终标红就断言没有远端副作用。

| 失败位置 | 先检查 | 恢复边界 |
| --- | --- | --- |
| runner、checkout 或 tag 获取 | runner 可用性、tag 是否存在、触发/dispatch 参数 | 只有明确暂时性原因才考虑重跑，不能凭空重打 tag |
| 身份校验 | Release 实际版本、tag commit、checkout 与触发 SHA | 找出不一致来源；覆盖 tag 不是默认修复 |
| 归档或 IPA 打包 | 编译错误、归档 `.app` 路径、工具链 | 若需源码修复，应重新走版本与身份确认，不把不同源码塞入原 tag |
| GitHub Release 创建 | 是否已存在 Release、是否已有资产、token 权限 | 创建不是覆盖式操作；重跑遇到已有 Release 可能再次失败 |
| 更新源提交或推送 | Release 是否已经成功、`main` 最新状态、写入权限及源记录 | 可能是部分发布；先核对已上传 IPA，再安排获授权的源修复，避免重复创建 Release |

只读诊断示例：

```sh
gh run list --workflow release.yml --limit 10 \
  --json databaseId,headSha,status,conclusion,url
gh release list --limit 10
```

找到目标 run 后查看失败日志，核对对应 tag 的 Release 与附件。重跑失败 job 会重执行该 job 的步骤；当前 Release 只有一个 `build-and-release` job，并没有从失败的步骤继续执行的保证。因此即便只是更新源推送失败，也不能不检查已有 Release 就重跑整个 job。

`workflow_dispatch` 接受已有的 `release_tag`，并检出该 tag；`release_notes` 留空会回落到 annotated tag message。它会执行同样的归档、Release 创建和源注册，**不是只读验证，也不是幂等的补注册入口**。应在确认当前远端状态与恢复授权后使用，不提供自动重发的一键命令。

删除或覆盖远端 Release、替换资产、删除或重打已发布 tag、强制推送都属于另外的恢复决策，不能从普通发布请求推导授权。

## 完成判据

- 版本号与构建号已核对，tag 指向确认的源码，发布说明来源正确。
- 待发布源码的 Swift CI 已通过，必要的 Local 交互验证另有记录；不把编译结论夸大为全部行为通过。
- Release 对应正确 tag，IPA 名称、下载 URL 与字节数同更新源一致。
- `main` 上的更新源已经注册，最新记录顺序正确，说明没有来源括号或 Markdown 分类标题残留。
- 向用户报告运行与 Release 链接；若只有 IPA 或只有部分注册完成，明确说明缺口，不宣称整个发布完成。
