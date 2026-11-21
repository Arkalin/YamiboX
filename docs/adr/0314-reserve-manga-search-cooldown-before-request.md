# 发起目录搜索前预约冷却窗口

前台和后台可共用同一个目录搜索冷却 actor，在调用论坛搜索前原子地检查并预约冷却时间。若改在请求完成后设置冷却，并发调用可能同时开始搜索，失败（包括论坛限流）也会让下次请求立即重试。标签目录读取只浏览标签结果，只有实际进入搜索路径才预约。见[目录 workflow](../../Sources/YamiboXCore/Reader/Manga/Application/MangaDirectoryWorkflow.swift)。

[目录命令计时](../../Sources/YamiboXCore/Reader/Manga/Application/MangaDirectoryCommandTiming.swift)只共享倒计时和强制搜索快捷窗口的计算规则，每个展示面拥有自己的状态和任务；等待冷却查询后再修改该状态，不让 `inout` 跨过挂起点。
