---
name: release
description: "发布 YamiboX 版本：确认版本与说明、递增构建号、提交并推送 annotated tag，由 GitHub Actions 发布。仅用于明确的发版请求。"
---

# 发布新版本

发布说明的传递链：CHANGELOG.md 的 Unreleased 段 → annotated tag 的 message →（release.yml）→ GitHub Release 正文 + app-repo.json 的 localizedDescription（应用内更新弹窗）。本地只负责产出 tag，其余全部由 workflow 自动完成。

## 前置检查

只对确实阻塞发布且无法在授权范围内解决的问题询问用户；可以继续整理说明或诊断失败原因，不擅自切分支、丢弃改动或修复无关代码。

1. 在 main 分支，working tree 干净，与 origin/main 同步（`git fetch origin` 后看 `git status`）。
2. 待发布 main commit 对应的 CI 通过：可用 `gh run list --branch main --limit 3` 定位，核对 commit SHA，不把其他 commit 的成功当作本次通过。
3. 先按 /changelog 的流程把 Unreleased 补到 HEAD；Unreleased 至少要有一条内容。

## 发布步骤

1. **定版本号**：当前版本取自 pbxproj 的 `MARKETING_VERSION`。按 Unreleased 内容建议 bump（只有修复 → patch；有新功能 → minor），向用户确认版本号和发布说明全文，确认后才继续。用户已确认同一版本与说明时，不重复索取确认。
2. **bump 版本**：检查 `YamiboX.xcodeproj/project.pbxproj` 中应用目标各构建配置，更新两个字段；按实际配置核对，不假设永远各有 2 处：
   - `MARKETING_VERSION`：改成新版本号。
   - `CURRENT_PROJECT_VERSION`（构建号，即 `CFBundleVersion`）：不随 `MARKETING_VERSION` 重置，在当前值基础上 **+1**，即使这次只是 patch。
3. **commit**：`chore: bump version to X.Y.Z (build N)`（遵循仓库 commit 规范）。
4. **打 annotated tag**：把发布说明（`## Unreleased` 段正文——含 `### 新增/变更/修复` 分类小标题和各条行尾的 `(hash · @作者)`，但不含 `## Unreleased` 那行）**原样**写入 scratchpad 临时文件，然后 `git tag -a vX.Y.Z -F <临时文件>`。tag message 保留小标题、hash 和作者——它进 GitHub Release 正文（`###` 渲染成分组标题，短 hash 和 `@handle` 自动链接）；应用内更新弹窗里 `###` 会转成 `【新增】` 纯文本、`(hash · @作者)` 整段被剥掉，都由 release.yml 处理，这里不用管。
5. **push**：`git push origin main vX.Y.Z`。tag push 触发 release workflow。
6. **善后 CHANGELOG.md**：把 `## Unreleased` 标题改为 `## vX.Y.Z - <今天日期>`（`### 分类小标题`和各条行尾 `(hash · @作者)` 随之保留，作为已发布版本的追溯线索），在其上方新建空的 `## Unreleased` 段，`last-scanned` 更新为发布 commit 的 sha。
7. **告知用户**：给出 workflow 运行链接（`gh run list --workflow release.yml`）；提醒 workflow 结束后 bot 会往 main 推一个 `Register vX.Y.Z in app-repo.json` commit，下次开工前先 `git pull`。

## 失败恢复

workflow 失败时先查看日志与远端状态，区分构建失败、部分发布和暂时性服务错误。可重试的任务优先重跑失败 job；需要重新触发时评估 workflow_dispatch（release_notes 输入留空会回落到 annotated tag 的 message）。删除、覆盖远端 release 或重打已发布 tag 前必须另获明确授权，不把普通发布请求视为授权破坏性恢复；报告未完成状态，不盲目重复发布。
