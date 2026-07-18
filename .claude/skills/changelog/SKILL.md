---
name: changelog
description: 扫描上次记录点以来 main 的新 commit，筛出用户可见的变更，总结成中文发布说明条目写入本地 CHANGELOG.md 的 Unreleased 段（该文件被 .gitignore 忽略，不进 git）。Use when main 有新变更后要积累发布说明，或用户说"更新 changelog""总结最近的变更""补发布说明"。
---

# 积累发布说明

把 git 历史里"值得告诉用户的变更"增量提炼进本地 CHANGELOG.md，供 /release 发布时直接使用。CHANGELOG.md 不进 git——它只是草稿，真相在 git log 里，丢了随时可按本流程重建。

## 步骤

1. **定位扫描起点**：读 CHANGELOG.md 顶部的 `<!-- last-scanned: <sha> -->` 标记。
   - 文件不存在 → 按下方模板创建，起点用 `git describe --tags --abbrev=0`（最近的发布 tag）。
   - 标记的 sha 不在当前历史上（`git merge-base --is-ancestor <sha> HEAD` 失败）→ 回退到最近发布 tag 为起点，靠第 4 步去重。
2. **取新 commit**：`git log --reverse --format='%H %s' <起点>..HEAD`。没有新 commit → 告知用户已是最新，结束。
3. **逐条筛选**（看用户可见性，type 只是线索）：
   - 收录：`feat:`、`fix:`、`l10n:`，以及任何改变用户可感知的行为、外观、性能的变更。
   - 跳过：纯 `refactor:` / `test:` / `ci:` / `docs:` / `chore:`，以及 bot 的 "Register v* in app-repo.json"。
   - 从 subject 看不出影响时，`git show <sha>` 看 diff 再判断。
4. **写成条目**：用户视角的中文短句，说效果不说实现；同一功能的多个 commit 合并成一条；与 Unreleased 已有条目属同一变更时合并或跳过，不重复记录。
   - ❌ `fix: guard against nil chapter index in reader`
   - ✅ `- 修复部分帖子打开阅读器时闪退的问题`
5. **写回**：新条目追加到 `## Unreleased` 段末尾（保留用户手工改过的措辞），`last-scanned` 更新为 HEAD 的完整 sha。
6. 最后向用户展示 Unreleased 段的当前全文。

## CHANGELOG.md 模板

```markdown
# YamiboX 更新日志

> 本地草稿，不进 git（见 .gitignore）。/changelog 增量补写，/release 发布时消费；丢失可用 /changelog 重建。

<!-- last-scanned: <full-sha> -->

## Unreleased

## v0.0.1 - 2026-07-14

- 首个版本
```
