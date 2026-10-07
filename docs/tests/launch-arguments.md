# 测试 App 启动参数

本文说明 `YamiboX-Local` 的启动参数、页面目标和数据隔离行为。

## 参数总览

| 参数 | 是否必需 | 用途 |
| --- | --- | --- |
| `--forum-base-url <URL>` | 必需 | 本次启动连接的 HTTP/HTTPS 测试站根地址 |
| `--open-page <目标>` | 可选 | 直达 App 页面或指定帖子的详情页、阅读器 |
| `--open-url <URL或站内路径>` | 可选 | 使用现有论坛 URL 路由打开页面 |

三个参数均支持 `--参数 值` 和 `--参数=值`，每个参数最多出现一次。`--open-page` 与 `--open-url` 不能同时提供。参数不会作为下次启动配置保存。

## 运行准备与站点参数

此模式只支持 iOS 模拟器，通过启动参数指定本地或远程 HTTP/HTTPS 测试论坛，不会覆盖普通 Debug 或正式版 App。普通 Debug、Release 始终使用正式站，忽略此参数。

1. 在本机的 `yamibo-dicuz-plugins` 仓库启动论坛：`docker compose up --detach --build --wait`。确认 `http://127.0.0.1:8088/forum.php` 可访问；启动与测试账号说明见该仓库的 `README.md`。不要在 App 中使用正式站账号。
2. 在 Xcode 中选择共享 Scheme `YamiboX-Local` 和 iOS 模拟器，在 Edit Scheme → Run → Arguments 中添加 `--forum-base-url` 和地址（例如 `http://127.0.0.1:8088`）。共享 Scheme 不预设地址。该 Scheme 使用 `Debug-Local`，安装为「Yamibo X 本地测试」（`com.arkalin.YamiboX.local`）。命令行构建见 [README](../../README.md#本地开发)。安装到模拟器的构建须保留签名；仅编译检查时可追加 `CODE_SIGNING_ALLOWED=NO`，不要安装该未签名产物，否则无法正常访问 Keychain。
3. 使用测试论坛已有账号在 App 内手动登录。测试 App 的沙盒和 Keychain 账号服务均与其他版本分离。每次启动必须传入地址；从模拟器桌面冷启动只显示配置错误，不恢复上次地址，也不会清理数据或回退正式站。

安装后也可用命令启动（重启前先用 `simctl terminate` 结束旧进程）：

```sh
xcrun simctl launch booted com.arkalin.YamiboX.local --forum-base-url http://127.0.0.1:8088
```

地址只允许站点根路径，不接受用户信息、查询、片段、重复参数或 `yamibo.com` 及其子域名。协议、主机和有效端口构成站点身份；默认端口、域名大小写和根路径斜杠会规范化。首次升级到参数模式（无绑定记录）或切换站点时，会自动清空测试 App 的账号、设置、数据库记录、离线文件、缓存、WebKit 数据和后台任务；同站点重启保留会话与数据。绑定记录仅用于隔离检查，不作为启动地址。清理中断后下次有效启动会重试，成功前不进入业务界面。测试版不运行后台自动唤醒任务或签到快捷指令。此清理不影响其他版本或服务器数据。

实现边界：`YamiboForumEnvironment` 集中定义站点、Cookie 规则与存储标识；`YamiboNetworkPolicy` 统一处理凭证发送和重定向；`YamiboLocalForumAdapter` 处理 Docker URL 兼容。业务和解析代码通过通用接口使用这些规则，不自行判断测试模式。

## 页面目标与启动示例

仅 `YamiboX-Local` 支持以下可选参数，仍必须提供 `--forum-base-url`。普通 Debug 和 Release 忽略直达参数。`--open-page` 与 `--open-url` 互斥，只能提供一次；同时支持 `--参数 值` 和 `--参数=值`。

| 参数 | 目标 |
| --- | --- |
| `--open-page bookshelf` / `forum` / `favorites` / `mine` | 书架、论坛、收藏、我的；`home` 保留为书架的兼容别名 |
| `--open-page messages` / `history` / `likes` | 消息、浏览记录、喜欢；已加入底栏时选择该 Tab，否则从「我的」打开，不修改底栏配置 |
| `--open-page search` / `login` / `settings` | 搜索、登录、设置首页 |
| `--open-page mine/profile` / `mine/messages` | 我的资料、我的消息（默认私信）；未登录时提示登录，消息已加入底栏时切换到消息 Tab |
| `--open-page mine/history` / `mine/likes` / `mine/downloads` / `mine/bookshelf` | 浏览记录、我的喜欢、下载管理、书架；有对应 Tab 时切换到该 Tab |
| `--open-page favorites/updates` | 收藏更新页 |
| `--open-page settings/general` / `settings/bookshelf` / `settings/forum` | 通用、书架、论坛设置；`settings/home` 保留为书架设置的兼容别名 |
| `--open-page settings/favorites` / `settings/reading` / `settings/storage` | 收藏、阅读、数据存储设置 |
| `--open-page settings/accounts` / `settings/about` | 账号管理、关于 |
| `--open-page novel-detail/<帖子ID>` / `manga-detail/<帖子ID>` | 指定类型的详情页，不自动进入阅读器 |
| `--open-page novel/<帖子ID>` / `manga/<帖子ID>` | 直接进入指定阅读器，沿用已有进度和版块智能漫画设置 |
| `--open-page normal/<帖子ID>` | 强制打开原生普通帖子页，不受版块阅读模式影响，沿用普通帖子的阅读进度恢复 |
| `--open-url <URL>` | 当前测试站的完整 URL，或以 `/` 开头的站内路径；复用现有论坛路由 |

帖子 ID 必须是正整数。未知目标、缺值、重复或冲突参数、跨站 URL 会显示配置错误，并且不会触发站点数据清理。直达目标优先于旧标签与阅读器恢复，仅在本次进程的首个前台窗口执行一次，不因重新进入前台而重复导航。不自动登录、收藏、下载或提交操作；需要权限、内容不存在和网络错误沿用正常页面提示。

参数不能注入已经运行的进程，切换目标时先结束 App，再启动：

```sh
xcrun simctl terminate booted com.arkalin.YamiboX.local
xcrun simctl launch booted com.arkalin.YamiboX.local \
  --forum-base-url http://127.0.0.1:8088 --open-page novel-detail/852
```

其他示例（每次先 terminate）：

```sh
xcrun simctl launch booted com.arkalin.YamiboX.local --forum-base-url http://127.0.0.1:8088 --open-page novel/852
xcrun simctl launch booted com.arkalin.YamiboX.local --forum-base-url http://127.0.0.1:8088 --open-page normal/852
xcrun simctl launch booted com.arkalin.YamiboX.local --forum-base-url http://127.0.0.1:8088 --open-page settings/reading
xcrun simctl launch booted com.arkalin.YamiboX.local --forum-base-url http://127.0.0.1:8088 --open-url '/forum.php?mod=viewthread&tid=852'
```

不传直达参数时进入「导航栏与启动页」配置的启动 Tab，并保留阅读器续读；不会被上次选中的 Tab 覆盖。从后台返回不重新跳转。不支持更深设置子页、章节/楼层/图片定位或执行操作参数。

## 后台持续下载验证（iOS 26+）

前台明确点击下载或继续队列可以申请后台持续任务；这不启用测试版的后台自动唤醒，
也不会保存启动地址。系统提供队列实时活动，无需自定义 Widget。申请被拒绝时仍走原有下载。

使用本地漫画多图、纯文本小说、带图小说和论坛附件组成队列；大图/附件应使用本地限速数据，
避免小文件瞬间完成。观察返回桌面后的系统进度、回到 App 后的队列及离线文件，并检查：

- 切换下载项时累计完成数保留；追加项更新总数，删除项不增加完成数。
- 图片和附件接收过程中持续上报字节；未知长度显示已接收字节，保存前不报告整项完成。
- 暂停、系统取消/到期、失败、账号切换均结束对应系统任务；重新继续不受旧回调影响。
- 快速完成及完成前尚未获得后台授权时不留下排队申请；授权回调不能重新启动已结束队列。
- 失败重试不重复累计前一请求的字节，已有图片缓存仍计入当前项进度。

下载日志分类为 `downloads`，debug 日志包含轮次、项数、当前项比例及字节数，
不记录下载标题和认证信息。普通传输进度只写内存，不应产生逐字节数据库写入。
项目没有测试 target，本流程不新增单元测试或恢复 UI 测试宿主。

模拟器可能返回后台处理不可用，不能把“编译通过”或“前台下载成功”视为灵动岛验收通过。
需分别记录模拟器上的下载/进度验证与系统实时活动验证结果；iOS 26 真机验收须另外明确授权，
不得为绕过限制切换正式 App 或生产论坛。

## 连接失败排查与限制

若页面无法加载，先在 Mac 上执行 `curl -I http://127.0.0.1:8088/forum.php`，并在 Docker 仓库执行 `docker compose ps --all` 查看 `web`、`db` 服务状态；再确认 Xcode 选中的是 `YamiboX-Local` 且目标是 iOS 模拟器。真机不能使用此 Scheme。现有 REST fixture 的附件图片只有 8×8 像素，默认头像也只是占位图，不能用来验证常规大图浏览。此模式不保证未安装于本地论坛的正式站专属插件可用。
