# 小说阅读器按布局代次提交界面

小说阅读器的同步视口采样发生在逐帧路径，不能为每次采样跨执行器，也不能把活动的 TextKit 对象图发给后台。由调用方隔离的 [阅读 workflow](../../Sources/YamiboXCore/Reader/Novel/Application/NovelReadingWorkflow.swift) 持有会话；[运行时契约](../../Sources/YamiboXCore/Reader/Novel/Application/NovelTextViewportRuntime.swift) 限于 package，由 UI 提供每个布局代次的 TextKit 对象图，Core 只经契约查询几何和绘制。可发送的语义准备可在后台执行；初次抓取内容可以独立于入场过渡中的不稳定尺寸。

布局、会话位置和显示结构必须同时提交。候选 [presentation](../../Sources/YamiboXCore/Reader/Novel/Application/NovelReaderPresentationBuilder.swift) 从候选快照、设置和容器计算，不能读取已提交的半套状态；旋转和字体变化也使用同一双页判定。开始加载后若几何先变，语义准备会以新设置重试；如果一个已获准的预取晋升在几何调整准备期间完成，仍为当前请求的几何调整可基于晋升后的文档重做一次，但新文档请求仍会取代旧请求。提交参数中，只有不能合法清空的字段才把 `nil` 当作沿用当前值；作者和预取项必须显式传入，因为清空与沿用不是同一个状态。

界面结构按已提交的布局代次共享，不随阅读位置修订号重建。[进度投影](../../Sources/YamiboXCore/Reader/Novel/Domain/NovelReaderProgress.swift) 复用已归一化的结构索引，避免每次滚动重新映射；章节信息按开始页一次排序，但同页章节仍保留原先次序。[会话](../../Sources/YamiboXCore/Reader/Novel/Application/NovelReadingSession.swift) 与展示共用双页配对规则，禁止把论坛源页末尾的奇数页配给下一源页，否则展示与翻页记账会错位。排版和显示使用同一内边距；双页由视口决定，旧的 `showsTwoPagesInLandscapeOnPad` 设置字段仅为兼容已保存的数据保留。

每次有效采样都更新精确语义位置供恢复使用；纯进度变化只在相对**上次发布状态**的累计偏移跨过门槛时发布。比较相邻采样会让持续慢速滚动永远达不到门槛。缓存页枚举不能阻塞首屏，只在文档代次仍匹配时补充元数据，不覆盖已发布的其他状态。显式开启的性能诊断可采集更新耗时，正常阅读路径不进行逐次计时和记录。

参见[阅读器设计](../architecture/readers.md#阅读-workflow-与提交)。
