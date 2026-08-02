# MacInkostomo 章节生成韧性修复交接

更新时间：2026-07-31 15:26（Asia/Shanghai）

## 结论

原任务（第五章生成失败）已修复并在真实工作区验证通过。之后又修了两个由它暴露出的缺陷。当前有一个已诊断、未决策的性能问题（节拍卡重复生成），和一个已知的外部故障（中转不稳）。

**注意**：日志 `data/debug/events.jsonl` 的 `ts` 是 UTC，文件 mtime 是本地时间（+8）。混用会得出完全错误的时间线结论，本轮排查一度因此误判。

## 已完成修复

### 1. 损坏 JSON 外壳中的完整正文恢复

文件：`macos/ChapterPublisher/InkOSCoreLLM.swift`

- `extractedJSONStringField(_:from:requireTerminator:)`：逐字段解码 `title`/`content`/`summary`，不依赖整个对象可解析。未转义引号只在其后紧跟 `}` 或 `,` 加下一个 `"key":` 时才算字段结束（`closesJSONString`），因此对白裸引号不会截断正文。`requireTerminator: false` 供流式预览。
- `recoverCompleteChapterProse(from:chapterNumber:)`：只返回可确认完整的正文字段，不复用损坏外壳里的 Delta。
- `requestChapterPayload`：解析失败 → 记 `chapter.invalidJson` → 尝试恢复 → 成功则记 `chapter.proseRecovered` 并跳过整章重试 → 只补 Delta。仅当正文本身中途截断才追加严格格式要求重试整章；第二次外壳仍坏但正文完整时同样恢复。
- Delta 补登条件从 `requireDelta` 放宽为 `requireDelta || recoveredProse`：恢复路径必然丢掉模型已写出的 Delta，而 Delta-only 请求成本低。
- `streamedChapterText` 改为复用新解析器，旧的独立扫描循环已删除。

**真实验证**：第五章 11:35 本地 `proseRecovered attempt=1` → 13:19 approved；第六章 13:57 `attempt=2` → 14:20 approved。对比上午 10:04 同样 `invalidJson` 的那次，旧代码直接 `chapter.failed`。

### 2. Delta 补登不再静默失败

原实现三条路产出同一个静默 nil：`try?` 吞请求错误、`parseJSONObject` 返回 nil、解析对象里没有 Delta 字段。现在各自记 `chapter.deltaRepair.failed` 带 `reason`：

- `requestFailed`（带 `statusCode`）
- `invalidJson`（带 head/tail）
- `missingDeltaField`（带实际返回的键）

补登失败时正文保持已恢复的内容。

### 3. 缺一致性文件不再退化成整章重写

`persistGeneratedDraftForRevision` 在 `rawDelta` 为 nil 时不写 `story/runtime/chapter-XXXX.consistency.json`。而 `performStoredDraftRevalidation` 和 `performDeltaOnlyRevision` 都调 `chapterConsistencyDelta`，后者在文件缺失时抛错。断链过程：

复校验抛错 → `lastReview` 保持 nil 而 `automaticLeadIn` 已置 true → `deltaRepairReview` 算出 nil → Delta-only 分支被整个跳过 → 全文重写，恢复出来的正文白扔。

新增 `repairableConsistencyDelta(bookID:chapterNumber:operation:)`，两个修复入口改用它：文件缺失时按空 Delta 起步并记 `chapter.delta.missingForRepair`。`chapterConsistencyDelta` 本身不变——人工审核通过和连续性投影仍必须要求文件存在。

## 回归测试

文件：`test/NativeCoreSmoke.swift`，位于已注册 `AutomatedRevisionLLMProtocol` 的作用域内。`AutomatedRevisionLLMProtocol` 新增 `requestCount()`（`configure` 时归零）。

正文恢复 6 项：外壳损坏但 content 闭合；正文含裸引号；正文中途截断返回空；结束引号后无分隔符返回空；流式预览读未闭合正文；端到端只消耗 2 次请求且事件齐全。

补登失败 3 项：`requestFailed`、`invalidJson`、`missingDeltaField` 各一项，均断言正文未丢。用 400（非 transient）避免触发 `requestLLM` 的 3 次重试退避拖慢测试。

缺一致性文件 1 项：复现第 8 章现场，断言原文复审通过、正文未变、只消耗 1 次请求、记录 `chapter.delta.missingForRepair`。

两轮变异验证均确认断言有效（回退实现后测试失败，已还原）。

## 验证命令

```bash
swiftc -parse-as-library \
  macos/ChapterPublisher/NativeModels.swift \
  macos/ChapterPublisher/InkOSCore.swift \
  macos/ChapterPublisher/InkOSCorePlanning.swift \
  macos/ChapterPublisher/InkOSCoreContinuity.swift \
  macos/ChapterPublisher/InkOSCoreLLM.swift \
  macos/ChapterPublisher/InkOSCoreCraft.swift \
  macos/ChapterPublisher/InkOSCoreSettings.swift \
  macos/ChapterPublisher/InkOSCoreFanqie.swift \
  test/NativeCoreSmoke.swift \
  -o /tmp/macingkostomo-native-core-smoke && /tmp/macingkostomo-native-core-smoke

xcodebuild -project ChapterPublisher.xcodeproj -scheme ChapterPublisher \
  -configuration Debug -derivedDataPath /tmp/MacInkostomo-DerivedData \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project ChapterPublisher.xcodeproj -scheme ChapterPublisher \
  -configuration Release -derivedDataPath /tmp/MacInkostomo-Release-DerivedData \
  CODE_SIGNING_ALLOWED=NO build

git diff --check
```

全部通过。文档已同批更新 `AGENTS.md`（Long-Form Governance）和 `README.md`（章节生成段落）。

## 当前现场

- 运行中：PID `40219`，启动 11:05，跑的是 **10:58 那次构建**。修复 2 和 3 尚未生效，需重启才生效。
- 备份：`~/MacInkostomo-Backups/pre-chapter5-20260731-110326/`（不在任何 git 仓库内）。
- `TASK_HANDOFF.md` 未被 git 跟踪，也未被 gitignore。

章节状态：

| 章 | 标题 | 字数 | 状态 |
| ---: | --- | ---: | --- |
| 1 | 雨落20层 | 3363 | approved |
| 2 | 橙色预警 | 3348 | approved |
| 3 | 断货 | 3017 | approved |
| 4 | 红色预警 | 2894 | approved |
| 5 | 现金 | 3441 | approved |
| 6 | 容器不空 | 3410 | approved |
| 7 | 时刻表也不稳 | 2854 | approved |
| 8 | 先保哪一样 | 2258 | revision_failed |

## 待处理

### 第 8 章需要重写补足字数

2258 字，计划下限 2550，**短 292 字**。这是独立于 Delta 问题的真实缺陷，篇幅校验必然失败，必须重写，与上述修复无关。直接点「驳回修改」即可。

### 已诊断未决策：节拍卡重复全批生成

`beatBatchRange` 按**卷起点**对齐批次，而卷 1 是第 1-500 章、批次大小 10，因此第 1-10 章全部映射到同一批次 1-10。`invalidateChapterBeats` 只在每轮修订末尾被调用一次（唯一调用方在 `InkOSCoreLLM.swift`，`fromChapter = 当前章 + 1`），删掉 N+1 之后的卡；下一章缺卡时重生**整批 10 张**，其中已 approved 章节的卡被反复重写。

实测 8 次全是批次 1-10，累计 54 分钟，平均 407s，最慢 899s。

已向用户说明的修法与代价：

- 批次范围按实际缺口算，不按卷起点对齐。收益 880s → 400-500s 量级，不是消失：prompt 里约 40k 字符的设定/圣经/摘要不管生成几张都要全量发送。
- 代价：prompt 是按整批协同规划设计的（进度相称、副本跨章分布），改成只补缺口会让模型从"同时写 10 张"降级为"按最近 4 张摘要续写"，批次内弧线协同变弱。此退化不可测，只能人工读卡判断。
- 必须连带处理：`beatPrefetchInFlight` 以 `nextStart` 为键，范围可变后两个不同 start 可能范围重叠并发写盘，`atomicWrite` 不会写坏文件但后写覆盖前者会丢卡；`batches` 去重是精确匹配 `startChapter ==` 且 `endChapter ==`，碎片化后会累积重叠记录。
- 已撤回的建议：`removedBeats == 0` 时跳过写盘。因为 `plan.batches.removeAll { $0.endChapter >= fromChapter }` 可能在 `removedBeats == 0` 时仍真删批次记录，只看 beats 数量就跳过会留下陈旧记录。要做必须同时判断 beats 和 batches 是否真有变化。

用户尚未决定是否改。低风险替代方案：只放宽 `prefetchUpcomingBeatBatch` 的触发条件（现为 `currentChapter >= 批次末尾 - 2`，批次 1-10 意味着要到第 8 章才满足），把等待藏进人工审核时间，一张卡都不少生成。

### 外部故障：中转不稳

`baseUrl` = `http://47.96.146.52:3000/v1`，`model`/`reviewModel` 均为 `k3`，`maxTokens` 16384。今天 09:00 后 9 次故障（504 超时、openai_error、空内容），其中 5 次集中在 15:00 前后。它同时在拖慢节拍卡、打断 Delta 补登。第 8 章的 Delta 补登失败就是 15:02 那次 504。

`prefetch` 已于 14:57 首次触发（第 8 章开始满足条件），但 15:12 被中转错误打挂。按设计 prefetch 失败静默吞掉，惰性路径按需重排，因此下一章仍会付全额节拍卡时间。

代码侧无解，需要看中转本身。
