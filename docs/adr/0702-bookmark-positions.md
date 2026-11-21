# 书签按位置切换，不并入喜欢或续读

[书签](../../Sources/YamiboXCore/Bookmark/Domain/BookmarkItem.swift)是用户显式设置的导航点，不是自动续读状态，也不是有内容、图片、样式和笔记的喜欢项。书签在独立表中按位置切换；喜欢可以追加并合并重叠选区。书签不携带图片字节，也没有供跨设备合并的编辑字段，因此同步只需要元数据和删除时间；软删除防止旧快照复活记录。

小说锚点使用同续读点的坐标，但保留目录序号来区分同一论坛页的不同帖子，并保存页码及作者作用域来定位投影缓存。捕获时即保存章节标题、位置排序键和少量正文：列表无需载入投影就能按书中顺序区分平时没有固定页号的位置，原文编辑后也有重新锚定的备选。漫画的全局页索引已经是排序键；同章同页才算同一位置，保存板块 ID 以便按打开时的板块配置路由。小说匹配窗口则刻意很窄：放宽可能静默删除用户当前看不到的书签，宁可容许相邻书签并让用户从列表删除。

[位置索引](../../Sources/YamiboXCore/Bookmark/Data/BookmarkPositionIndex.swift)只保留检索所需字段，按原始书中顺序打破同位置匹配的平局，与无缓存查询一致；小说按有限整数偏移查找，同时保持 Swift 的 Unicode 字符串和可选身份相等规则。[Store](../../Sources/YamiboXCore/Bookmark/Data/BookmarkStore.swift)在同个数据库读快照内核对索引版本并抓取胜出行，读任务乱序完成时只允许最后发起的查询保留缓存，没有版本直接走权威查询。只监听 DELETE 不足以发现旧作品的行被 SQLite REPLACE 替换，修订触发器须在冲突 ID 消失前使旧作品索引失效。

设备可独立为同一位置生成不同 ID，仅按 ID 合并会留下两个书签并让「取消书签」移除不干净。[同步归并](../../Sources/YamiboXCore/Bookmark/Application/BookmarkLibraryWebDAVParticipant.swift)在 ID 合并后再按位置去重，保留最早创建者、同刻按 ID 裁决，其余写入 tombstone。
