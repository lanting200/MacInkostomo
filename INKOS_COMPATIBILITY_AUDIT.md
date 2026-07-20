# InkOS 兼容性审计与改造原则

## 目标

`chapter-publisher` 只做 InkOS 的控制台/UI 壳：展示、调度、调试、番茄集成、系统 LLM 二审；小说工程本体必须以 InkOS 为权威。

## InkOS 权威边界

以下内容以 `book/books/<bookId>/` 下 InkOS 文件为准：

- 章节索引：`chapters/index.json`
- 章节正文：`chapters/000X_*.md`
- 章节状态：InkOS 原生 status，例如 `ready-for-review`、`audit-failed`、`state-degraded`、`approved`、`rejected`、`published`
- 设定与规则：`story/` 下的 `book_rules.md`、`outline/story_frame.md`、`outline/volume_map.md`、`roles/`、`pending_hooks.md` 等
- 记忆/快照/运行产物：`story/runtime/`、`story/snapshots/`、`story/state/`、`memory.db`

## Publisher 只允许保存的元数据

`data/state.json` 只能作为 UI/外部服务元数据，不得作为小说正文和 InkOS 状态权威：

- 系统 LLM 初审结果 `llmReview`
- UI 修改历史/人工备注
- 番茄映射/发布辅助状态
- 创建任务、调试任务等 Publisher 自身状态

## 当前已完成的兼容修复

1. 章节列表和详情 API 改为优先读取 InkOS `chapters/index.json` + Markdown 正文。
2. API 对前端暴露 InkOS 原生 `status`，旧 Publisher status 仅作为 `publisherStatus` 元数据返回。
3. 人工通过先调用 `inkos review approve`，成功后才更新 Publisher 元数据。
4. 继续生成新章前，以 InkOS index 的状态为阻塞条件；只有 `approved/published` 才允许继续。
5. 前端状态展示支持 InkOS 原生状态，不再只识别 `pending_review/revision_failed`。
6. 分卷信息从 InkOS `story/outline/volume_map.md` 解析，不再硬编码某本书的四卷结构。
7. 普通 PATCH 不再允许直接写章节正文；章节正文修改必须走 InkOS revise/rewrite/sync 流程。
8. Publisher 自动规范化/失败恢复后的产物同步，改为调用 `inkos write sync` / `inkos review reject --keep-subsequent`，避免直接篡改 `chapters/index.json`。

## 仍需继续收敛的风险点

- `data/state.json` 仍保留历史章节正文副本；后续应迁移成纯 metadata store，避免任何新逻辑读取它作为正文权威。
- `/revise` 中失败恢复仍需要先写回旧 Markdown，再调用 InkOS sync/reject。这属于应急回滚路径；理想状态是 InkOS core 提供官方 restore/revert 命令。
- `lib/inkos.js` 的 revise fallback 会使用 `inkos agent` 自然语言要求写回文件；它仍通过 InkOS CLI，但比正式 `inkos revise/write` 更难验证。后续应优先推动 InkOS core 暴露稳定的 revision API。
- 老章节已经 `approved` 但保留了历史 `auditIssues`，InkOS 语义上仍是 approved；如要修复内容，应走 InkOS revise/rewrite/sync，而不是 Publisher 直接改。
