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
2. **取新 commit**：`git log --reverse --format='%h%x09%an%x09%s' <起点>..HEAD`（tab 分隔三列：短 hash · git 作者 · subject；短 hash 是每条要引用的来源，`git show <hash>` 可回看 diff）。没有新 commit → 告知用户已是最新，结束。
3. **逐条筛选**（看用户可见性，type 只是线索）：
   - 收录：`feat:`、`fix:`、`l10n:`，以及任何改变用户可感知的行为、外观、性能的变更。
   - 跳过：纯 `refactor:` / `test:` / `ci:` / `docs:` / `chore:`，以及 bot 的 "Register v* in app-repo.json"。
   - 从 subject 看不出影响时，`git show <sha>` 看 diff 再判断。
4. **写成条目**：用户视角的中文短句，说效果不说实现；同一功能的多个 commit 合并成一条；与 Unreleased 已有条目属同一变更时合并或跳过，不重复记录（合并进已有条目时，把新 commit 的短 hash 追加到那条行尾）。
   - **归类**：每条归入三类之一——**新增**（用户能用到的全新功能/入口/开关）、**变更**（已有功能的行为、外观、性能、文案改动，含多数 `l10n:` 与体验优化）、**修复**（bug 修复，多为 `fix:`）。type 只是线索，按用户实际感受判断：`feat:` 若只是增强已有功能，归「变更」而非「新增」；拿不准就归「变更」。
   - **每条行尾用括号标注来源 hash 与作者**：`(<hash>[, <hash>…] · <@作者>[, <@作者>…])`——`·` 前是短 hash（合并了几个 commit 就列几个，小写十六进制裸值），`·` 后是各 commit 的 git 作者写成 GitHub `@handle`（本仓库唯一作者 git `arkalin` → `@Arkalin`；有多个就去重列出）。都不加反引号，GitHub Release 正文里短 hash 和 `@handle` 都会自动链接。这整段括号只出现在 GitHub Release；应用内更新弹窗由 release.yml 整段剥掉，终端用户看不到 hash 和作者。
   - ❌ `fix: guard against nil chapter index in reader`
   - ✅ `- 修复部分帖子打开阅读器时闪退的问题 (a1b2c3d · @Arkalin)`
   - ✅（多个 commit 合并成一条）`- 漫画阅读器缩放平移手感升级：橡皮筋回弹、松手惯性、双指以指间为中心 (a1b2c3d, e4f5a6b · @Arkalin)`
5. **写回**：条目按 `### 新增` → `### 变更` → `### 修复` 分组写进 `## Unreleased`（保留用户手工改过的措辞）。只写有内容的分类，空的不加标题，顺序固定如上；新条目追加到所属分类末尾，该分类标题还不存在就按固定顺序补上。`last-scanned` 更新为 HEAD 的完整 sha。
6. 最后向用户展示 Unreleased 段的当前全文。

## Unreleased 段结构

只写有内容的分类，标题顺序固定 `新增 → 变更 → 修复`；每条行尾带 `(hash · @作者)`：

```markdown
## Unreleased

### 新增
- 收藏设置新增开关，可关闭智能漫画卡片右上角的闪光标识 (a1b2c3d · @Arkalin)

### 变更
- 论坛首页首次加载显示与内容同形的骨架占位，不再整页转圈 (e4f5a6b · @Arkalin)

### 修复
- 修复部分帖子打开阅读器时闪退的问题 (0fead8f · @Arkalin)
```

## CHANGELOG.md 模板

```markdown
# YamiboX 更新日志

> 本地草稿，不进 git（见 .gitignore）。/changelog 增量补写，/release 发布时消费；丢失可用 /changelog 重建。

<!-- last-scanned: <full-sha> -->

## Unreleased

## v0.0.1 - 2026-07-14

- 首个版本
```
