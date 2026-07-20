# InkOS 内置框架审计

## 当前结论

InkOS 已从外部 CLI 依赖重构为 MacInkostomo 框架内的源码模块。`inkos.pipeline` 由 `FrameworkKernel` 注册和管理，Publisher 默认在当前 Node.js 进程中调用模块 port。CLI 只保留为兼容入口，并复用同一个 core runtime；它不再是应用架构边界。

原生 macOS 客户端使用 SwiftUI。macOS 26 使用 Liquid Glass，旧系统使用 Material；客户端未嵌入 `WKWebView`。`public/` 是本地浏览器兼容与诊断界面，不参与 Xcode 应用渲染。

## 模块边界

- `inkos/packages/core/src/framework/`: registry、kernel、workflow、fault、diagnostics。
- `inkos.pipeline`: 创建、规划、写作、审核、修订、整章重写、同步、状态修复和审核状态变更。
- `lib/inkos-runtime.js`: Publisher 到内置模块的 composition root，负责进程级 runtime 租约、配置轮换、关闭取消、本机配置、密钥注入、trace 和诊断桥接。
- `server.js`: 本地 API、任务生命周期、Publisher 元数据与外部集成，不实现小说生成算法。
- `macos/ChapterPublisher/`: 原生视图、状态模型和 API client，不直接读写小说工程文件。

模块调用受并发 bulkhead、超时、熔断和结构化 fault 约束。跨模块长流程应使用 workflow step、retry 和 compensation；新增能力应扩展 port，而不是从 UI 或 route 直接操作 core 私有文件。

## 权威数据

以下内容以 `book/books/<bookId>/` 为准：

- `book.json`: 小说配置
- `long-form-plan.json`: 总字数、分卷、逐章预算、特殊约束和 continuity 契约
- `chapters/index.json` 与 `chapters/000X_*.md`: 章节状态和正文
- `story/outline/`、`story/roles/`、`story/book_rules.md`: 大纲、人物和规则
- `story/state/long_form_state.json`: 时间线、实体、知识边界、随机设定和伏笔聚合状态
- `story/runtime/`、`story/snapshots/`、canon checkpoints、`memory.db`: 运行状态、回放基线和记忆

`data/state.json` 只保存系统二审、人工备注、UI 历史、番茄映射及 Publisher 任务元数据。历史兼容字段即使包含正文副本，也不得作为读取或生成依据。

## 长篇一致性约束

1. 新建小说提交结构化总字数、分卷、单章字数、容差和特殊约束；上限为 300 万字、100 卷、10,000 章。
2. 总字数被精确分配到每章和每卷，运行时按已写字数计算下一章可行区间。
3. 每章必须结算结构化 consistency delta；校验时间线顺序、实体归属和属性、人物知识边界、世界规则、随机设定值与伏笔生命周期。
4. 卷末生成 canon checkpoint，后续卷只从已经确认的正典继续。
5. 修订、repair 和 resync 从第 N-1 章 runtime/long-form snapshot 重放；聚合态不得直接 reapply 到同一章。
6. 已影响正文的 immutable canon、不可变规则、实体锁和已生效 timeline/knowledge/hooks 受 PATCH 写保护。
7. 普通 API PATCH 不直接写正文；正文变更统一经过 `write.revise`、`write.rewrite` 或 `write.sync`。
8. 章节正文、truth、index、book metadata、runtime、long-form、canon checkpoint 和快照处于同一个 book-scoped rollback journal；prepared transaction 会在下一次书锁获取时恢复。

## 审核工作流

- 生成前检查上一章必须是 `approved` 或 `published`，并同步 Publisher 审核状态。
- 人工通过和驳回走 `review.approve` / `review.reject` 模块操作。
- 默认驳回回滚到上一章快照并移除依赖章节；`keepSubsequent` 是显式保留后续草稿的受控模式。
- 整章重写使用 core 的强制 revision 行为，并保留 latest-chapter 因果边界。
- `state-degraded` 会阻止继续生成，直到通过 repair/resync 恢复结构化状态。

## 调试契约

框架和 Publisher 输出同一结构化事件 schema，持久化为 JSONL，并通过 `/api/debug/events`、`/api/debug/schema`、`/api/debug/health` 和 `/api/debug/stream` 暴露。事件必须包含足以关联调用的 trace、book、chapter、module、operation、phase 和 fault code；密钥、Authorization header 和正文大块内容必须在写入前清理。

## 兼容边界

- Publisher 默认使用进程内 core；显式 `PUBLISHER_INKOS_RUNTIME=subprocess`、诊断 draft 模式或 `dist/index.js` 缺失时可使用项目内 CLI。CLI 创建完成后必须保留 core 生成的 continuity seed，并用 Publisher 提交的预算重新基准化。
- 老书缺少 `long-form-plan.json` 时允许一次受控迁移；已存在但损坏的规划必须报告错误，不能静默覆盖。
- 番茄接口属于外部系统，失败不得改变 InkOS 权威章节与设定状态。
- 本地服务没有认证并只绑定 `127.0.0.1`，不得直接暴露到公网。
