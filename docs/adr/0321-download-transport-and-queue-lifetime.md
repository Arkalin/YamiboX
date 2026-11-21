# 下载传输与队列以本次运行的存活状态为准

## 系统会话不能恢复 App 内的执行权限

系统后台 `URLSession` 不提供每次重定向前的否决机会。受论坛会话约束的下载使用可控且可取消的 data 传输；系统后台传输只处理不带论坛凭据和 Referer 的外部公开资源。可控传输的逐跳回调与系统后台传输的事后 metrics 不可互相替代。

下载回调退出后 Foundation 会移除临时文件，传输层读取并暂存有上限的结果和分类前缀。成功交付须汇合文件结果、重定向证据和任务完成；取消及传输错误不等待可能缺失的 metrics。注册与启动系统任务须与取消互斥，否则暂停可能只取消尚未注册的任务，稍后仍启动传输。

App 重启后不存在原请求的可信 pending 和 lease。旧后台任务只能取消并收尾，不能转化为一次新的下载执行；已完成的文件和持久队列仍可留给用户显式继续。完整协议及命名迁移见[下载与存储](../architecture/downloads-and-storage.md#9-平台后台任务与验证限制)。

## 停止和恢复必须协调已获准的写入

队列先认领 worker 再挂起以申请后台机会；多个继续命令共享同一个 worker。继续命令退出前若发现上一轮正在持久化暂停，等待它完成再恢复运行，避免迟到的暂停覆盖新轮次。账号失效先停止准入，再等待已准入命令和 worker 退出，最后持久化暂停；仅清除 task 引用、只在 UI 层丢弃结果或复用当前账号暂停都不能替代这个顺序。

身份变更和取消条目前都等待旧 worker 退出，防止挂起的写入在移动引用或删除后恢复。取消条目如果已提交部分删除再失败，仍尝试继续剩余工作并向调用方报告原错误。恢复沿用原逻辑轮次及已完成计数，不伪造一次用户发起的后台申请；到期回调仅暂停捕获的 executor 与 run ID，验证后直接开始取消。

系统字节回调可能并发且密集。一次网络尝试内先在锁内发布有序快照，再由有界流交给单个消费者处理；不为每次字节回调创建 actor task，也不把瞬时字节数当作持久条目的累计进度。

代码入口：[传输、重定向与任务准入](../../Sources/YamiboXCore/Reader/Shared/Download/Application/DownloadBackgroundTransport.swift)、[旧会话迁移](../../Sources/YamiboXCore/Reader/Shared/Download/Application/DownloadBackgroundSessionMigration.swift)、[队列生命周期](../../Sources/YamiboXCore/Reader/Shared/Download/Application/DownloadQueueExecutor.swift)、[传输进度](../../Sources/YamiboXCore/Reader/Shared/Download/Application/DownloadWorkProcessor.swift)。
