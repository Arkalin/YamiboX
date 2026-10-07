# 账号与应用生命周期

本页描述当前 Core/UI 两模块下的应用装配、账号转换和数据重置。账号认证、持久化与业务顺序属于 Core；窗口、WebKit 和系统前后台事件由 UI 接入。

## 应用装配与启动

`YamiboAppContext` 是组合根，不是供所有页面查询服务的全局容器。AppEntry 用它装配窗口、共享 workflow 和各功能的 `*Dependencies`；功能视图与 ViewModel 应接收所需依赖包或更窄的能力接口。

正式启动先在后台任务中调用 `prepareDownloadStorage()` 打开数据库并完成迁移，再构造 AppContext 和窗口协调器。文件升级可能耗时，不应绑定到某个窗口的可取消任务。准备失败时启动入口展示错误与重试，而不是创建一套半升级的 Store 继续运行。准备成功的 `DatabasePool` 传入 AppContext，各 GRDB Store 共用这一连接池。

`YamiboWindowCoordinator` 管理共享运行时及多窗口；每个 `YamiboAppModel` 管理该窗口的导航、阅读会话和展示状态。会话 Store、下载、同步和平台网页会话不应为每个窗口分别创建一套互不协调的实例。

应用级订阅由 `AppRuntimeCoordinator` 持有：

- `start()` 同步注册各 Store 的变更流，再启动消费任务；重复调用不建立第二套订阅。
- WebDAV participant 与变更源通过同一个 `AppWebDAVDataset` 列表装配，避免新增同步数据集却漏掉自动同步观察。
- 进入 active 时触发同步检查，并刷新未读消息与黑名单；进入 background 时取消前台刷新、使其结果失效，并请求后台同步收尾。
- 运行代次与阶段代次过滤迟到结果。`stop()` 取消订阅和前台任务，但不撤销已经交给 continuity workflow 的工作。

`AppContinuityWorkflow` 负责启动续读、进度协调与自动同步；自动同步失败记录诊断，不阻塞应用外壳。前后台同步策略及同步数据集见 [WebDAV 同步设计](webdav-sync.md)，阅读会话恢复见 [阅读器设计](readers.md)。

## 账号操作租约与候选登录

`AccountOperationGate` 在网络 `await` 期间保持一个操作 owner，避免 actor 重入使两个账号操作交错。`acquire()` 已被占用时返回 `AccountSwitchError.busy`，不是排队等待；`run` 在成功、失败和取消后都释放自己持有的租约。

租约与会话代次不是同一个概念：租约排他保护整个账号操作，会话代次拒绝旧账号的异步读写。不能通过“当前忙”标志推断调用者拥有租约。

新增或重新登录先在隔离候选环境完成认证：

1. 登录弹窗获取正式账号 Store 的操作租约。
2. 使用 `AccountStore.temporary()`、非持久化 WebKit 数据仓库及 ephemeral 网络会话完成候选登录；候选会话不写入正式 Keychain 或偏好。
3. 获取已验证的个人资料，校验 Cookie、UID，以及重新登录场景的预期 UID。
4. `activateLogin` 检查租约 owner，经统一转换 workflow 提交到正式 Store。
5. 关闭弹窗时取消并等待候选任务、拆除网页协调器，最后释放租约。

切换已保存账号也在租约内先验证目标会话。目标已失效时保留账号资料并使凭据失效；网络失败或身份不匹配不应直接把当前账号替换成目标账号。验证目标会话不借用当前账号的 WAF 恢复会话。

## 账号转换的固定顺序

`AccountSwitchCoordinator` 负责选择操作及校验身份，`AccountTransitionWorkflow` 负责顺序和失败收尾，AppContext 仅装配依赖。正常切换、激活登录、退出和应用重置共用此路径。

| 阶段 | 行为与边界 |
|---|---|
| 保存本地编辑 | `willBegin` 先让编辑器保存草稿；失败立即返回，此时尚未开始身份转换 |
| 开始身份转换 | `beginIdentityTransition` 创建转换 token、推进会话代次；转换期间普通会话写入和旧代次请求不能通过 |
| 建立同步屏障 | WebDAV coordinator 取消并等待所有正在运行或排队的同步，推进 epoch、清空连接相关内存状态，在操作期间拒绝新运行 |
| 停止账号任务 | 未读消息与黑名单先进入账号变更准备状态；随后停止并等待下载执行器；UI lifecycle 再停止网页会话、收藏同步与更新检查 |
| 清理账号缓存 | 图片管线切换账号状态，论坛首页与板块缓存清理并推进缓存代次；这不是删除全部本地阅读资料 |
| 提交账号 | 检查取消后，用转换 token 提交新的会话与个人资料，或提交退出/重置；正式 AccountStore 将相关投影写入同一 vault 文档 |
| 清理与接入 | 读取实际已持久化的会话，按策略清理 Foundation Cookie、HTTP 缓存和注入的 WebKit 数据；UI `didChange` 接入该会话 |
| 发布 | 结束身份转换并推进代次，恢复未读/黑名单观察，再调用 `didPublish` 更新窗口、导航和阅读会话；最后释放同步屏障和账号操作租约 |

UI 通过 `AccountTransitionLifecycle.configure` 注入 `preserveLocalEdits`、`prepare`、`finish` 和 `publish`，Core 不导入 WebKit。多窗口由窗口协调器为所有存活模型发布账号变化，并清理已断开场景的恢复记录，避免重新打开窗口恢复旧账号内容。

普通转换使用 `.session` 网页清理策略；应用重置默认使用 `.all`。`.session` 清理论坛 Cookie 和 HTTP 缓存，`.all` 还清理全量网页数据。平台实现通过 `WebsiteDataClearing` 接入，不在 Core 中直接调用 WebKit。

### 失败不是无条件回滚

- 保存草稿或开始转换失败时，不进入后续转换阶段。
- 若建立同步屏障失败，结束已开始的身份转换并传播错误，不声称账号切换成功。
- 屏障内停止任务、清缓存或提交失败时，仍按实际持久化会话执行收尾和发布，再传播原始错误。清理不能假设目标账号已经提交。
- Keychain 写入成功前不更新内存文档；写入失败不能让 UI 宣布新账号已激活。
- 退出先完成本地提交，再尽力请求服务端退出；服务端退出失败不撤销已完成的本地退出。

因此，调用失败可能已清掉某些可重建缓存，但不等于目标账号已激活；应用重置失败也可能已经删除部分数据。

## 作用域与迟到结果

| 标识 | 负责拒绝什么 |
|---|---|
| 账号操作 lease | 不是当前账号操作 owner 的激活、释放请求 |
| `AccountSessionSnapshot.generation` | 旧账号的网络请求、WAF Cookie 回写和个人资料结果；转换期间也不准入 |
| 论坛缓存 `accountGeneration` | 旧账号首页/板块请求结束后写入新账号缓存 |
| WebDAV run epoch 与 receipt scope | 旧连接、旧账号的同步任务、收据和远端文件缓存 |
| 窗口 `accountGeneration` / `accountEpoch` | 旧账号导航、阅读器打开和启动恢复结果 |
| 草稿数据库 generation、revision 与删除标记 | 重置、并发修改或删除后恢复的旧草稿写入 |

AppContext 的客户端工厂捕获会话快照，在使用时校验快照代次，并显式传递凭据。不要只检查 `Task.isCancelled`：请求可能已完成，回调也可能已经入队；发布和写入边界仍要校验所属作用域。

这些标识不能互相代替。Store 的 `changeID` 只标识订阅的 Store 实例，不是账号 UID、会话代次或数据版本。

## 凭据与本地数据的边界

正式 `AccountStore` 将当前会话、当前个人资料和保存账号记录作为一个 JSON 文档放入环境隔离的 Keychain vault。使用 `AfterFirstUnlockThisDeviceOnly`、不启用 Keychain 同步；没有保存论坛登录密码。旧 `yamibox.session` 与 `yamibox.profile` 仅在迁移时读取，成功持久化后删除；重置写入空 vault，防止旧偏好再次导入。

`SessionStore.snapshot()` 能抛出安全存储错误，适合需要准确身份的操作。`load()` 是可用性读取：失败会记录日志并返回未登录状态，不能用它的默认值推断“安全存储一定为空”。

**多账号不是所有本地数据按 UID 分库。** 草稿明确按账号 UID 隔离，认证与账号相关缓存随会话转换；本地收藏、进度、目录、喜欢、书签等多数资料仍属于同一 App 安装的共享业务库，普通切换不会清空它们。WebDAV 收据按账号作用域维护，载荷核对论坛 UID，但不会自动建立账号专属远端目录，也不会将这些本地表分成独立账号数据库。具体数据归属见 [持久化与身份](persistence-and-identity.md)。

## 应用数据重置

`AppDataResetWorkflow` 在同一账号操作租约与转换屏障内，先清空全部保存账号，再按 AppContext 注册顺序执行 `AppDataResetStep`。步骤包括设置和同步配置、阅读恢复、业务 Store、投影缓存、下载、背景与图片、UI 恢复状态、喜欢/书签和网络日志。

每个参与者使用自己的正式清理方法，不能绕过 Store 直接删表或并发执行有序步骤。遇到首个错误立即停止、记录步骤 ID 并传播原始错误；前面成功的步骤不回滚。该流程跨 Keychain、偏好、数据库和文件系统，不是一个全局事务。新增重置能力应在组合根注册步骤，而不是在执行器添加业务分支。

## 维护入口与验证

关键源码：

- [应用启动入口](../../YamiboX/YamiboXApp.swift)、[AppContext](../../Sources/YamiboXCore/App/YamiboAppContext.swift)、[运行时装配](../../Sources/YamiboXCore/App/YamiboAppContext+Runtime.swift)。
- [转换 workflow](../../Sources/YamiboXCore/Account/Application/AccountTransitionWorkflow.swift)、[账号协调器与 lifecycle](../../Sources/YamiboXCore/Account/Application/AccountSwitchCoordinator.swift)、[账号 Store 与操作 gate](../../Sources/YamiboXCore/Account/Data/AccountStore.swift)。
- [窗口协调](../../Sources/YamiboXUI/AppEntry/YamiboWindowCoordinator.swift)、[候选登录](../../Sources/YamiboXUI/Features/Mine/AccountLoginSheet.swift)、[数据重置](../../Sources/YamiboXCore/App/AppDataResetWorkflow.swift)。

调整这些流程时，按 [核心流程回归清单](../tests/regression-checklist.md) 验证有未保存草稿、正在下载/同步、待返回网络请求及多个窗口时的账号切换、退出和重置。观察“旧请求没有覆盖新状态”和“失败被正确展示”，不能仅检查最终 UID。网络诊断见 [论坛接入与路由](networking-and-routing.md)，下载停机边界见 [下载与存储](downloads-and-storage.md)。

本页依据源码说明契约，不是一次切换、重置或多窗口交互的通过报告。
