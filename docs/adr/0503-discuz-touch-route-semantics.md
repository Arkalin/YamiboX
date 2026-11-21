# Discuz 原生路由遵循 touch 模板的显式语义

原生页面不能把桌面模板、服务端默认值和显式 touch 行为混作同一种路由。依据 [路由构造](../../Sources/YamiboXCore/Infrastructure/Networking/YamiboRoute.swift)及[历史站点兼容约定](../architecture/networking-and-routing.md#5-原生-url-路由与网页回退)，保留这些差异：

- 通过帖子 ID 打开时显式发送 `ordertype`，否则服务端可能继承该帖的默认倒序位，改变页码与阅读位置的意义。按链接进入的路由则先解析现有 URL 和查询（包括相对链接、HTML 转义），再叠加 touch 页码和作者视图，不能直接丢弃原查询重建。
- 用户空间列表保留 `view=me`：省略会使自己的帖子列表为空；回复列表还需独立的 `type=reply`，`view=reply` 会退回主题列表。发私信的 touch 表单入口不带 `op`；对话读取使用 `space_pm.htm` 的 `subop=view` 分支，桌面 `op=showmsg` 没有对应的 touch 模板。
- URL 身份由 [共享提取器](../../Sources/YamiboXCore/Infrastructure/Networking/YamiboForumURLIdentity.swift)同时处理相对／原始链接与绝对 URL，避免路由层和漫画目录再次出现不同的正则口径。本地 UCenter 头像按 query 选 UID 和尺寸，不能套用普通头像 URL 去 query 的规则；[本地资源适配](../architecture/networking-and-routing.md#7-本地-docker-论坛的兼容边界)只重写已知 Docker 资源。
- [签到页](../../Sources/YamiboXCore/Account/Data/YamiboCheckInRemoteRepository.swift)不以提交的 HTTP 成功推断签到完成，必须读取结果页：已签到日期使用日历中的 `.on` 状态，按钮状态是另一条确认线索。签到、推广与验证读取的权限各自归命名路由。
