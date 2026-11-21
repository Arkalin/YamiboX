# 持久化逻辑阅读动作和平台输入标识

[外设设置](../../Sources/YamiboXCore/Settings/Domain/GamepadSettings.swift)存储阅读动作的原始值，以及 Game Controller 元素别名（字符串）或 USB HID 键码（键盘 Keyboard/Keypad 页，和 `GCKeyCode` 原值一致）。[平台适配器](../../Sources/YamiboXUI/Features/Reader/Shared/Gamepad/ReaderPeripheralInputManager.swift)负责转译实际输入，让 Core 保持独立于 GameController。手柄元素可同时报告多个别名，捕获时按固定优先级选一个持久化，运行时仍用整组别名匹配；键盘每次按键只报告一个键码。重绑同一标识由最近一次绑定获胜，被取代的动作回到未绑定。

始终保留手柄 Menu 键呼出阅读菜单，方向键也维持固定语义。手柄用允许列表排除系统拦截的 Home 键及模拟输入；键盘可绑定键较多，改用排除列表保留方向键和修饰/导航键的含义。各外设的启用开关独立控制阅读时派发动作，不阻止设置页重新绑定。默认手柄绑定按面键的物理位置选择，界面从连接的外设读取实际符号，不假定不同品牌的字母标签相同。输入转译按下沿派发一次逻辑动作，不把每次状态回调都当作新按键；竖向阅读的滚动步长小于一屏，保留上下两次视口之间的内容衔接。
