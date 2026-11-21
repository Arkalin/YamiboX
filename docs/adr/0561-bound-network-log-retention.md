# 网络诊断优先保护传输、隐私与磁盘限额

[记录器](../../Sources/YamiboXCore/Infrastructure/Networking/Logging/NetworkLogRecorder.swift)在传输回调内只留下已脱敏的令牌，不等待磁盘，也不因诊断写入失败而改变请求终态。[脱敏器](../../Sources/YamiboXCore/Infrastructure/Networking/Logging/NetworkLogEntry.swift)只保留已知错误域，避免任意域名成为日志字段；截断 URL 按 UTF-8 字节预算控制，且不保存不完整的编码。

[日志存储](../../Sources/YamiboXCore/Infrastructure/Networking/Logging/NetworkLogStore.swift)用带版本的 JSONL 分段存储，按请求开始时间而非完成时间列出和淘汰。容量不足时批量淘汰近一个分段，以少保留一些最旧记录换取更少重写；迟到的旧请求不能淘汰更新记录，也不能使用批量淘汰腾出的余量重新填充截止时间以前的历史。淘汰线以最早仍应保留的请求为准，允许开始时间等于截止线的记录。手动清空先推进内存代次，即使 I/O 失败也拒绝旧 token；还要记录清空时间，以拒绝恢复后台任务后才取得新 token、实际却在清空前开始的请求。

元数据和原子替换都占用预留预算，先落盘时间界限再删除较早记录。分段采用原地截断重写，不另写完整副本，以免瞬时突破留存限额；中断后只恢复完整、可解码且在时间界限内的行，不能恢复截断中丢失的字节。诊断留存因此不是事务型审计日志。
