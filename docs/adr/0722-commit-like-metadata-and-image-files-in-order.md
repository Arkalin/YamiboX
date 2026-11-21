# 喜欢图片的元数据和文件按固定顺序提交

喜欢内容独立于收藏：添加喜欢不创建收藏，删除收藏也不级联删除喜欢。用户留存的图片不是可重新生成的装饰，文件按拥有它的条目 ID 保存原始字节，不做封面式转码。图片文件与数据库没有共同的事务，所以新增时先写新文件，再提交元数据；写库失败或并发操作已占用同一锚点时，只清理本次的文件，不触碰胜出的条目。锚点去重与写入由同一数据库事务执行。删除时先提交元数据，以免写库失败后条目仍存在、文件却已丢失。

用户确认的批注写入开始后，不把发起它的手势、编辑菜单或视图的取消传播到提交任务。如此既能在界面消失后完成事务，也能走完需要的文件补偿；文件补偿本身仍可能失败。图片索引保留历史文件后缀和原目录枚举的首项选择，删除后废弃索引，避免把局部更新后的内容误当成并发写入后的完整目录。两类阅读器从同一个依赖包创建批注服务，供同时呈现或编辑喜欢和书签的阅读界面使用，两者的持久化仍各自独立。

涉及实现：[图片捕获](../../Sources/YamiboXCore/Like/Application/ImageLikeCaptureService.swift)、[批注操作](../../Sources/YamiboXCore/Like/Application/ReaderAnnotationService.swift)、[图片存储](../../Sources/YamiboXCore/Like/Data/LikeImageStore.swift)、[喜欢元数据](../../Sources/YamiboXCore/Like/Data/LikeStore.swift)。
