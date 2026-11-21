# 深色网页回退只覆盖全局默认颜色

论坛网页没有对应的原生深色配色。亮色模式修正已知站点容器不一致的颜色；深色模式只调整 `html`／`body` 的默认背景与文字色，不强行覆盖嵌套元素。Discuz 皮肤和帖子 BBCode 都可能自带前景或背景；把所有容器强制换成深色，会破坏这些颜色组合并导致文字不可读。

入口：[网页主题注入](../../Sources/YamiboXUI/Features/Forum/Web/ForumWebView.swift)。
