# 关闭 SwiftUI 面板时延后发布模型状态

SwiftUI 会在其展示更新期间写入布尔绑定。如果 setter 同步清除由 `@Published` 驱动的展示状态，模型会在视图更新途中再次发布。[展示绑定](../../Sources/YamiboXUI/SharedUI/Support/PresentationBindings.swift)因此把清除安排到后续主 actor 执行。任何后续实现仍须避免在视图更新中发布，并且只应清除刚被关闭的展示，不要清掉替换它的新内容。
