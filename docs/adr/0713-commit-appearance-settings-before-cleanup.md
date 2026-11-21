# 提交外观设置后再清理旧资源

[背景提交器](../../Sources/YamiboXCore/Settings/Application/CustomBackgroundPersistence.swift)按背景用途在所有窗口之间共享，显式把文件写入、设置更新与清理排队；actor 会在等待文件或设置存储时让出执行，仅凭 actor 隔离不能防止并发编辑间互相清除图片。新图片保存后才提交引用；若引用没有提交，删除新图片。清理发生在设置提交之后，清理失败只记录，不把已生效的设置当成提交失败。

[主题库](../../Sources/YamiboXCore/Settings/Domain/AppThemeLibrary.swift)让主题列表和选中项一起持久化，删除当前主题时在同一更新中选择内置主题，避免留下指向不存在主题的选中项。[外观设置](../../Sources/YamiboXCore/Settings/Domain/AppAppearanceSettings.swift)的渲染预设与用户可选的主题列表是不同概念；多个自定义主题可以共用同一种渲染方式。
