# 分数据集协调 WebDAV，而不是用一次同步时间覆盖业务变更

[同步参与者](../../Sources/YamiboXCore/Sync/WebDAV/WebDAVSyncParticipant.swift)拥有业务格式、合并和指纹；[同步引擎](../../Sources/YamiboXCore/Sync/WebDAV/WebDAVSyncService.swift)只解释通用 envelope 元数据，并在导出后写入协调 revision，不让每种业务合并规则传递该参数。指纹排除传输时间和 revision，避免每次导出自身制造脏状态；应用回执必须来自提交快照，而不是后来重新读取的数据。上传的 revision 也算已经吸收的远端 revision，否则下轮会把自己的上传再应用一次。

删除记录独立于活动数据，即使接收端没见过被删记录也保留，以免旧副本复活。共享[指纹编码](../../Sources/YamiboXCore/Persistence/SyncContentFingerprint.swift)和[删除比较规则](../../Sources/YamiboXCore/Persistence/SyncSoftDeletionRules.swift)的变更可能改变对同一份数据的判断；冻结的历史迁移不应改用运行时规则。

双方有 revision 时优先使用它，避免设备时钟偏差颠倒顺序；缺失 revision 的旧客户端仍需按 `updatedAt` 比较，所以合并后上传的时间略晚于已吸收远端时间。旧格式回执不能抹去已知 revision。干净的数据集也会吸收尚未应用的远端版本，不会因为别的数据集待上传而丢失变更。无业务动作的轮次只推进内存中的检查时间，不能改动持久内容时间并掩盖随后抵达的其他设备变更。

阅读活动内的高频变更过于频繁，不适合每次请求远端或重读所有库。节流轮次只更新受影响数据集及依赖者的脏标记；完整协调仍检查所有启用的参与者。缺少指纹基线不是本地编辑：快照型应用设置不能因此覆盖旧远端值，只有主动选择首次自动上传的参与者可以初始化。前后台切换是独立检查点，合并短间隔的空轮次，但不因此推迟待上传数据。

参见 [WebDAV 协调、方向与回执](../architecture/webdav-sync.md)。
