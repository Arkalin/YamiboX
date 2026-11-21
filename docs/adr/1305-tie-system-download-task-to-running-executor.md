# 系统下载任务不能成为队列执行者

[下载持续处理适配器](../../Sources/YamiboXUI/Platform/BackgroundTasks/DownloadContinuedProcessingCoordinator.swift)在主 actor 拥有系统任务和向系统展示的进度；业务队列不依赖系统调度成功。启动时清掉上一进程的系统请求，因为没有可与该请求绑定的旧 executor，不应借请求重启已恢复的队列。结束事件允许先于新 worker 的启动通知到达，适配器据运行 ID 拒绝事后登记。到期先结束系统任务，再暂停且只暂停与该任务绑定的执行。详见[下载与存储架构](../architecture/downloads-and-storage.md)。
