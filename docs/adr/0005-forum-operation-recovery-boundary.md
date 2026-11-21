# 论坛请求的恢复权限归属逻辑操作

[论坛接入设计](../architecture/networking-and-routing.md#4-waf-恢复与重放)维护当前的恢复流程、适配器和验证规则。这里记录不应随传输实现改变的设计取舍。

- **重放权由业务语义决定，不由 HTTP 方法或传输适配器决定。** Discuz 的部分 GET 会修改服务端状态；即使恢复验证成功，未审定的操作也不能当作读取重发。[命名路由](../../Sources/YamiboXCore/Infrastructure/Networking/YamiboRoute.swift)和[动态导航定义](../../Sources/YamiboXCore/Infrastructure/Networking/ForumRequestDefinition.swift)提供准入；图片和下载共享资源读取定义。每次逻辑操作拥有自己的尝试、重放预算和租约，Cookie 更新不会新建逻辑操作，加入既有验证也不会延长租约。
- **允许共用一次验证，不允许共用不相容的身份。** [请求契约](../../Sources/YamiboXCore/Infrastructure/Networking/ForumWAF/ForumRequestContracts.swift)不以账号 UID 代替会话实例：候选登录、当前会话和退役会话有各自的身份与 Cookie 存储作用域。同一 attempt 用委托逐跳证据和真实传输统计一起判断响应来源；回调只记录证据，执行器只在传输成功且未取消后提交当前代次的新凭据。缓存响应不能刷新凭据寿命；代次检查和合并必须在同一存储事务内完成，以免跨越账号切换。
- **验证器不拥有导航、登录或展示权限。** [验证契约](../../Sources/YamiboXCore/Infrastructure/Networking/ForumWAF/ForumSilentVerifying.swift)只允许回传变化的防护 Cookie，不能替换账号凭据或 User-Agent；重新采集令 Cookie 看似更新，并不代表其值发生变化。已有 WebKit 导航可向执行器交接一次尝试，不能因此扩大验证器权限。已接收的文档与安全入口预热分别合并，避免预热吃掉真实响应；[协调器](../../Sources/YamiboXCore/Infrastructure/Networking/ForumWAF/ForumWAFRecoveryCoordinator.swift)的超时独立于平台调用，不能因为平台没有响应取消就永远挂起调用者。
- **供应商只解释证据，不能授权重放。** [响应分类器](../../Sources/YamiboXCore/Infrastructure/Networking/ForumWAF/ForumWAFResponseClassifier.swift)保留有界检查，正文候选、边缘会话标识和有效通行凭据不是等价证据。若检查前缀截断在 UTF-8 字符中间，既有 ASCII 证据仍可保留。仅向受控验证器交付完整、成功接收、不超预算的文档；失败凭据仅携带核对所需的证据，不保存或记录可执行文档。重定向丢失手写请求头时，[传输适配器](../../Sources/YamiboXCore/Infrastructure/Networking/ForumWAF/ForumDataTransport.swift)从原 attempt 重建，而不是读取可能已经切换的当前账号。

结果是各业务可以沿用内联失败或缓存回退策略，但不得在终态错误上开启第二轮恢复。一处适配器或验证器缺省时也不能绕过执行器。
