---
name: release
description: 发布 YamiboX 新版本——把本地 CHANGELOG.md 的 Unreleased 内容定稿为发布说明，bump MARKETING_VERSION 和 CURRENT_PROJECT_VERSION（构建号），创建以说明为 message 的 annotated tag 并 push，由 GitHub Actions 完成构建、GitHub Release 与 app-repo.json 注册。Use when 用户说"发布新版本""发个 release""打 tag 发版"。
---

# 发布新版本

发布说明的传递链：CHANGELOG.md 的 Unreleased 段 → annotated tag 的 message →（release.yml）→ GitHub Release 正文 + app-repo.json 的 localizedDescription（应用内更新弹窗）。本地只负责产出 tag，其余全部由 workflow 自动完成。

## 前置检查（不满足则停下询问用户）

1. 在 main 分支，working tree 干净，与 origin/main 同步（`git fetch origin` 后看 `git status`）。
2. 最新 main CI 通过：`gh run list --branch main --limit 3`。
3. 先按 /changelog 的流程把 Unreleased 补到 HEAD；Unreleased 至少要有一条内容。

## 发布步骤

1. **定版本号**：当前版本取自 pbxproj 的 `MARKETING_VERSION`。按 Unreleased 内容建议 bump（只有修复 → patch；有新功能 → minor），向用户确认版本号和发布说明全文，确认后才继续。
2. **bump 版本**：`YamiboX.xcodeproj/project.pbxproj` 里两个字段都要改，各 2 处（用 replace_all）：
   - `MARKETING_VERSION`：改成新版本号。
   - `CURRENT_PROJECT_VERSION`（构建号，即 `CFBundleVersion`）：不随 `MARKETING_VERSION` 重置，在当前值基础上 **+1**，即使这次只是 patch。
3. **commit**：`chore: bump version to X.Y.Z (build N)`（遵循仓库 commit 规范）。
4. **打 annotated tag**：把发布说明（`## Unreleased` 段正文——含 `### 新增/变更/修复` 分类小标题和各条行尾的 `(hash · @作者)`，但不含 `## Unreleased` 那行）**原样**写入 scratchpad 临时文件，然后 `git tag -a vX.Y.Z -F <临时文件>`。tag message 保留小标题、hash 和作者——它进 GitHub Release 正文（`###` 渲染成分组标题，短 hash 和 `@handle` 自动链接）；应用内更新弹窗里 `###` 会转成 `【新增】` 纯文本、`(hash · @作者)` 整段被剥掉，都由 release.yml 处理，这里不用管。
5. **push**：`git push origin main vX.Y.Z`。tag push 触发 release workflow。
6. **善后 CHANGELOG.md**：把 `## Unreleased` 标题改为 `## vX.Y.Z - <今天日期>`（`### 分类小标题`和各条行尾 `(hash · @作者)` 随之保留，作为已发布版本的追溯线索），在其上方新建空的 `## Unreleased` 段，`last-scanned` 更新为发布 commit 的 sha。
7. **告知用户**：给出 workflow 运行链接（`gh run list --workflow release.yml`）；提醒 workflow 结束后 bot 会往 main 推一个 `Register vX.Y.Z in app-repo.json` commit，下次开工前先 `git pull`。

## 失败恢复

workflow 失败时：修复问题后删掉远端的 release 和 tag（`gh release delete vX.Y.Z --yes`、`git push origin :refs/tags/vX.Y.Z`），重新打 tag 再 push；或用 workflow_dispatch 手动触发（release_notes 输入留空会回落到 annotated tag 的 message）。
