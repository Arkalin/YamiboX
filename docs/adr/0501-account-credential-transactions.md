# 账号切换以本地凭据事务为准

账号操作跨越异步网络调用；actor 本身不能保证整段操作互斥。采用 [账号操作租约和单文档凭据 vault](../architecture/account-lifecycle.md#账号操作租约与候选登录)，前者覆盖整个操作，后者原子保存凭据与当前会话、个人资料投影。登出必须先提交本地状态，再以退役会话请求服务器退出；反序会在本地写入失败时留下一个已在远端失效、却仍显示已登录的账号。重置也要保留空 vault 作为迁移已处理的标记，不能放任旧偏好重新导入。见 [账号协调器](../../Sources/YamiboXCore/Account/Application/AccountSwitchCoordinator.swift)和 [账号存储](../../Sources/YamiboXCore/Account/Data/AccountStore.swift)。

候选登录保存在内存中，验证身份前不写当前账号的偏好或 Keychain。登录表单的 Cookie 来自隔离 jar，随显式 POST 请求头一起提交；仅携带通行 Cookie 会丢掉此前表单建立的会话。资料验证可能刷新防护状态，持久化时读取校验后的快照。签到仓储与旧账号的请求仍受各自绑定的会话代次约束。见 [原生登录](../../Sources/YamiboXCore/Account/Application/YamiboAccountService.swift)和 [签到仓储](../../Sources/YamiboXCore/Account/Data/YamiboCheckInRemoteRepository.swift)。

WebKit 快照不是账号切换指令，也不能无条件用更短寿命的通行 Cookie 覆盖当前值；保留 Cookie 路径、域和期限元数据可避免将已过期的持久 Cookie 恢复成会话 Cookie。恢复 Foundation Cookie 时，非 Secure 项省略 Secure 属性，不使用字符串 `"FALSE"` 表示关闭。[Cookie 模型](../../Sources/YamiboXCore/Account/Domain/YamiboCookie.swift)和 [会话状态](../../Sources/YamiboXCore/Account/Domain/SessionState.swift)实现这些约束。正式论坛认证 Cookie 用已知名称，本地 Discuz 的站点前缀由部署生成，不能借用正式名称判断；服务端域／端口匹配也不能靠系统 Cookie jar 单独保证，见[网络凭据设计](../architecture/networking-and-routing.md#cookie-与请求凭据)。

Core 负责编排会话转换和清理，UI 注入 WebKit 的停止与数据清理能力，避免 Core 直接依赖 WebKit。普通登出清理论坛 Cookie 以免网页回退仍显示旧登录，重置则清整份站点数据；没有平台实现的 Core 调用仅完成 Foundation 侧清理。[转换工作流](../../Sources/YamiboXCore/Account/Application/AccountTransitionWorkflow.swift)保留该职责边界。[Store 多播通知](../architecture/account-lifecycle.md#作用域与迟到结果)的 `changeID` 标识发出通知的 Store 实例，不可用于推断账号、代次或提交版本。

[签到状态存储](../../Sources/YamiboXCore/Account/Data/YamiboCheckInStore.swift)的容量报告快照仅统计键值的 UTF-8 载荷：偏好文件由多个功能共用，不能将整个文件或按键推算的物理空间算作签到数据。
