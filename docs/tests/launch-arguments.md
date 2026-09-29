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
2. 在 Xcode 中选择共享 Scheme `YamiboX-Local` 和 iOS 模拟器，在 Edit Scheme → Run → Arguments 中添加 `--forum-base-url` 和地址（例如 `http://127.0.0.1:8088`）。共享 Scheme 不预设地址。该 Scheme 使用 `Debug-Local`，安装为「Yamibo X 本地测试」（`com.arkalin.YamiboX.local`）。仅做编译检查时，可将 [README](../../README.md) 中构建命令的 Scheme 改为 `YamiboX-Local`；不要安装其中 `CODE_SIGNING_ALLOWED=NO` 生成的 App，未签名的模拟器 App 无法正常访问 Keychain。
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
| `--open-page home` / `forum` / `favorites` / `mine` | 首页、论坛、收藏、我的 |
| `--open-page search` / `login` / `settings` | 搜索、登录、设置首页 |
| `--open-page mine/profile` / `mine/messages` | 我的资料、我的消息（默认私信）；未登录时打开登录入口 |
| `--open-page mine/history` / `mine/likes` / `mine/downloads` | 浏览记录、我的喜欢、下载管理（内含下载队列入口） |
| `--open-page favorites/updates` | 收藏更新页 |
| `--open-page settings/general` / `settings/home` / `settings/forum` | 通用、首页、论坛设置 |
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

不传直达参数时维持原来的启动行为；不支持更深设置子页、章节/楼层/图片定位或执行操作参数。

## 连接失败排查与限制

若页面无法加载，先在 Mac 上执行 `curl -I http://127.0.0.1:8088/forum.php`，并在 Docker 仓库执行 `docker compose ps --all` 查看 `web`、`db` 服务状态；再确认 Xcode 选中的是 `YamiboX-Local` 且目标是 iOS 模拟器。真机不能使用此 Scheme。现有 REST fixture 的附件图片只有 8×8 像素，默认头像也只是占位图，不能用来验证常规大图浏览。此模式不保证未安装于本地论坛的正式站专属插件可用。
