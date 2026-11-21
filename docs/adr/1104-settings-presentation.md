# 设置导航和编辑控件跟随实际展示环境

[设置首页](../../Sources/YamiboXUI/Features/Settings/SettingsHomeView.swift)在 iPhone 沿用「我的」导航，在 iPad 使用独立的分栏容器以便窗口变窄后仍保有栏选择。侧栏的关闭按钮依据窗口而非栏宽的尺寸级别；Command-F 唤起原有搜索输入而不增加一套可见控件。关于与 WebDAV 是当前导航栈的详情，不各自包裹导航容器或提供独立关闭语义。

搜索索引只登记当前设备实际可操作的行。收藏网格尺寸只在 iPad 有效，同时从 iPhone 移除控件和搜索入口，避免能搜到却找不到控件。收藏的同步偏好与快捷操作的「记住」使用同一组字段，因此用户可从设置撤销之前记住的选择。

[导航配置编辑器](../../Sources/YamiboXUI/Features/Settings/SystemSettings/NavigationSettingsEditor.swift)按已选标签集合而非顺序标识列表：成员变化时重建编辑行，避免原先处于可选区的行保留不可拖动状态；仅重新排序时保留身份，避免中断当前拖动。[外观预览](../../Sources/YamiboXUI/Features/Settings/SystemSettings/SettingsAppearanceSection.swift)使用论坛实际解析的配色，示意卡片限制字号占用，但真实操作控件保留完整的辅助文字大小。[颜色选择器](../../Sources/YamiboXUI/Features/Settings/SystemSettings/AppThemeEditor.swift)只更新草稿，可滑动关闭；用户在外层表单保存时才写入。

[漫画目录管理](../../Sources/YamiboXUI/Features/Settings/SystemSettings/MangaDirectoryManagementView.swift)没有可单独管理的子条目，不新增详情页。滑动用于单项清理，批量与全量清理共用下载管理的「选择 → 删除」流程；确认按钮使用与提示文案一致的「清除」，表示清理目录索引。
