# Swift 注释减量规则

Swift 源码不新增行注释、块注释、文档注释或 `MARK`。用可读的类型、命名和结构说明代码做什么；不显而易见的取舍和背景写入 [ADR](../adr/)，有待修复的实现由 Issue 跟踪。现有注释可以分批清理。根 `Package.swift` 的首行工具链声明是编译所需的指令，不是普通注释。

```sh
bash scripts/check-comments.sh check
bash scripts/check-comments.sh inventory 'Sources/YamiboXCore/Library/**'
bash scripts/check-comments.sh prune
```

- `check` 要求当前注释与基线一致；删除后先运行 `prune`，再将源码和缩小后的基线一起提交。
- 基线按仓库相对路径和注释文本指纹记录出现次数。文件内换行或移动已有注释不受影响；改写、复制或移动到另一文件会视为新增。CI 对照 PR 目标提交或推送前的提交，拒绝扩充基线，不能通过重建基线放行。
- 检查用当前 Xcode 自带的 SwiftParser，不新增 App 依赖。它只扫描仓库中的 Swift 文件（本地也包括未忽略的新文件）；字符串中的 `//` 不算注释。Shell、JS、PHP 脚本可同批审计，但不受这个 Swift 门禁约束；生成元数据和翻译注释也不在门禁内。

重复清理可调用 [`delete-comment` Skill](../../.agents/skills/delete-comment/SKILL.md)。统计可删物理行数时按 `inventory` 的 `wholeLines` 计算；同一行既有源码又有注释时，删除注释不会减少行数。
