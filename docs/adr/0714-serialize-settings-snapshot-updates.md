# 在存储层串行更新设置快照

[设置存储](../../Sources/YamiboXCore/Settings/Data/SettingsStore.swift)使用一份 JSON 快照。单项编辑在 actor 内无挂起地读、改、保存，不能让调用方分开 `load` 与 `save`，否则多窗口可用旧快照覆盖彼此的修改。实际保存才发出变更信号；监听流只发布当前 Store 实例的失效信号，不传递设置正文或来源标识。下载设置改名时只重写成功解码的旧值，不把解码失败得到的默认值当作已迁移的数据。

[设置模型](../../Sources/YamiboXCore/Settings/Domain/SystemSettings.swift)保留旧启动页字段，便于从早期本地快照迁移，并与仍只理解旧字段的客户端交换设置；新版以完整导航配置为准。新字段缺失时填充自身默认值，保留旧快照里已有的其他字段。例如[外屏配置](../../Sources/YamiboXCore/Settings/Domain/AppSettings.swift)仅为缺少灵敏度的已有分辨率配置补上当时的全局值，不重置其阅读偏好，见[外屏阅读规格](../../openspec/specs/external-display-reading/spec.md)。

[WebDAV 设置参与者](../../Sources/YamiboXCore/Settings/Application/AppSettingsWebDAVParticipant.swift)仅同步选定字段：以完整子集快照应用胜出的版本，不逐字段混合两套导航配置，未同步字段留在本机。自动上传先检查子集是否真的改过，不因本机首次看到快照就覆盖远端；同步修订由引擎负责，缺失修订时保留旧格式的协调路径，见[WebDAV 分数据集协调](0602-webdav-dataset-reconciliation.md)。
