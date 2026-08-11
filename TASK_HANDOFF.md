# MacInkostomo 同人创作模式交付交接

更新时间：2026-08-11 10:30（Asia/Shanghai）

## 给 review agent 的前置警告

三条，违反任意一条会污染真实数据或得出错误结论。

1. **`book/` 和 `data/` 是用户的真实小说。** Debug 构建不带 `MACINKOSTOMO_WORKSPACE`
   启动就会写进去。任何要启动 app 的验证，先读 [AGENTS.md](AGENTS.md) 的 Testing 段。
   本轮生产验证是用户明确授权的例外（原话：「就在生产环境 新建 一个小说即可」），
   不要据此认为后续也可以直接写生产工作区。
2. **`data/debug/events.jsonl` 的 `ts` 是 UTC，文件 mtime 是本地 +8。** 混用会得出
   完全错误的时间线。本文所有事件时间戳都是 UTC。
3. **文档曾经跑在实现前面。** 本仓库的 `README.md` / `AGENTS.md` 在原生迁移期被当作
   预期规格来写，导致半成品读起来像已完成。**核实任何一条声明前先 grep 调用方**，
   包括本文的声明。本轮我按这条规则查出 `README.md:155` 的「尚未接通」已过期并改掉了。

## 交付范围

新建小说增加「同人」/「自创」两种类型。自创保持原流程：客户随便写设定，LLM 润色成
完整大纲。同人在此之上加三层，输入仍然只有两样东西——一份原著 txt、一段设定文本。

| 层 | 文件 | 职责 |
| --- | --- | --- |
| 原著检索 | `InkOSCoreDerivative.swift`（新增 1177 行） | 识别编码、切章、BM25 + 语义双索引；写作时按节拍卡关键词回原文捞段落 |
| 正典抽取 | `InkOSCoreCanon.swift`（新增 649 行） | 按字数预算分批抽成世界设定／规则／实体／伏笔，合并进连续性投影；客户设定文本作为 `manualOverlay` 最后应用 |
| 时间进度 | `InkOSCoreTimeline.swift`（新增 347 行） | 以原著锚点事件为第 0 天，按节拍卡 `storyDays` 累加推算本章故事日期，把原著事件分成已发生／尚未发生／未确定三类写进提示词 |

发布范围覆盖原生同人建书、检索、正典抽取、时间进度、模型角色配置、工作区进度 UI 与原生 smoke 回归；三个新增核心文件都已加入 Xcode target。

## 发布前系统分析补修

逐条核对调用链和持久化状态后，补掉八个会在长篇原著、失败恢复或隔离验证时暴露的问题：

1. 卷首按 `index=0` 保留供检索，但不再计入正典游标的 `chapterCount`，避免所有正文批次跑完后仍永远显示未完成。
2. 替换原著会清空旧源写入的 `baseContinuity` 和旧 checkpoint，同时保留作者 `manualOverlay`、已审核章节贡献与连续性策略，避免两部原著正典混在一起。
3. `sourceDay` 改成整部原著的全局锚点坐标；不含锚点的批次丢弃模型输出的局部第 0 天，不按章号插值。
4. 作者设定 overlay 的时间线不再携带 `sourceDay` / `sourceChapter`，因此不会被时间闸门误判成尚未发生的原著事件。
5. 每批正典合并后刷新连续性计划，下一批提示词能看到上一批刚登记的实体 ID，减少同一人物跨批重复建 ID。
6. 抽取提示词使用 `sourceTitle` 而不是衍生书目录 ID；检索键除 `focusCharacters` 外，也覆盖目标、场景和必写事件里出现的正典实体。
7. `source/preparation.json` 原子保存作者设定与语义索引意图。继续操作会补齐正典、overlay 和索引，App 重启后也会恢复未完成横幅，不再出现“正典完成但 overlay/index 失败后没有入口”的状态。
8. `MACINKOSTOMO_WORKSPACE=$(mktemp -d)` 现在无条件采用空目录，并禁止 Release 旧工作区迁移；此前显式目录没有预建 `book/` 时会被忽略，隔离启动实际落到 Application Support。

对应 smoke 探针已经覆盖显式空工作区隔离、前言 + 正文章号、替换源分层保留、跨批实体名册、原著标题与全局锚点提示词、sourceDay 接受边界、overlay 坐标清空、准备状态恢复判定和扩展检索键。

## 设计取舍（review 时请针对这些提问）

**同人与自创的真正差别在约束方向，不在多几个字段。** 自创是「客户设定 → LLM 自由扩写」，
同人是「客户设定 → 必须与原著线自洽」。所以节拍卡和剧情大纲的提示词对同人是**减法**：
先给正典事实，再给禁止清单。三处提示词各有同人分支，调用链已核实：

- 建书方案：`derivativeCreationSections`（`InkOSCorePlanning.swift:544`），由
  `createBookPrompt`（同文件 514）调用。要求 worldbuilding 不发明与原著冲突的体系、
  原著人物沿用既定姓名关系、`outline` 与 `volumePlan` 尊重开篇时间点。
- 节拍卡：`derivativeBeatSections`（`InkOSCoreCraft.swift`）。
- 正文：`derivativeGenerationSections`（`InkOSCoreLLM.swift:2275`），由
  `generationPrompt`（同文件 2197）在 2230 行调用——**禁止清单确实进了正文提示词，
  不只在节拍卡里**。

**时间进度系统是防「LLM 写到哪是哪」的核心，也是最容易做错的一层。** 三个已定的取舍：

- `sourceDay` 精确但稀疏，`sourceChapter` 是单调回退分类器。**不从原著章号插值推算日期**，
  这是刻意的：插值会把「第 5 章」硬变成某一天，给出一个没有依据的精确值。
- `order` 是稠密排序键，不是时间轴。别拿它当日期用。
- 未发生的原著事件在提示词里是硬禁止：「本章绝对不得发生，也不得被任何人知晓、预告或讨论」。

**已知的语义张力，不阻塞交付但值得讨论**：上面那句「不得被任何人知晓」与穿越设定天然冲突——
主角本来就带着未来知识。当前实现只禁止具名事件出现或被议论，不禁止主角泛指地知道
「一年后这城市会出事」。第 1 章正文就落在这条线上（见下）。这条边界是否要显式写进提示词，
需要产品判断。

## 生产验证：《灰雾之前》

诡秘之主同人，主角穿越到廷根，时间为原主穿越前一年。

正典抽取 57/1406 章（覆盖锚点窗口）：102 条正典、61 条规则、75 个实体、31 条知识边界、
93 条时间线事件、64 条伏笔、overlay 已应用。

第 1 章《春雨》，2904 字，`pending_review`，初审 `passed`，`auditIssues` 与 `issues` 均空，
两条 soft 建议（字数超计划上限 29 字但低于验收上限；冷幽默人设未落地）。

**时间闸门实测**：

```
ch1  storyDay=-365 configured=true   past=0 future=12 unplaced=0
ch10 storyDay=-358 configured=true   past=0 future=12 unplaced=0
```

提示词写明「距原著事件「克莱恩穿越」还有 365 天，该事件尚未发生」，12 条原著事件全部
列在禁止清单里。正文一条都没碰，并且自己认出了时间位置：「他记得小说里的廷根，知道一年后
会有什么事情把这座城市搅得不得安宁」。

日期累加自校验通过：`chapter-beats.json` 里第 1-9 章 `storyDays` 累计 7 天，
第 10 章 `storyDay=-358` = −365 + 7，一致。

节拍卡 10 张，批次 `(1,3) (4,4) (5,5) (6,8) (9,10)`——被 `splitRetry` 打碎成 5 段，
但不重叠、无重号。上一轮交接文档担心的「碎片化导致 `batches` 累积重叠记录」在本例未发生。

## 途中修掉的三个缺陷（本轮最需要 review 的部分）

生成一开始三次全挂。根因不是提示词，是 **`maxTokens = 16384` 对推理模型太紧**：
同一个提示词的推理长度实测在 **5347 到 16383 token 之间浮动**，推理与正文共用同一预算，
所以失败看起来是随机的。双向证明过：同一提示词在 16384 下返回 `finish=length` + 0 内容 +
16383 推理 token，在 65536 下返回完整 9872 字符节拍卡；而另一次在 16384 下又成功了——
正是这次成功确立了「浮动」而非「硬阈值」。

文件：`macos/ChapterPublisher/InkOSCoreLLM.swift`

**缺陷 1：重试沿用刚刚失败的同一个上限。** 三次注定同样失败。改为每次翻倍，
上限 `maxTokensRetryCeiling = 65536`。有界而非无界：模型因为「不愿回答」而不产出正文时，
无界重试会在越来越大的预算上反复烧整趟推理。

**缺陷 2：空内容判定只认 `finishReason == "length"`。** 实际有三种形态：`length`（在上限处截断）、
`stop` 且零内容（模型写完了但什么都没写）、`finishReason` 完全缺失（流在推理阶段就被切断，
记为 `(none)`）。只有「内容为空」是可靠信号，`length` 不是。改为按空内容判定。
第三种形态是补了 `response.empty_content` 日志才第一次可见的——此前无法与前两种区分。

**缺陷 3：截断的 JSON 被原样返回。** 节拍卡规划器读到 `length` 就把章节范围对折
（1-10 → 1-5 → 1-3），每次付一整趟推理——**预算不够时反而缩小答案**。新增
`truncatedJSONError` 让它走抬预算重试。注意这里区别对待：截断的**散文**仍然返回，
因为章节流程能审能改；截断的 **JSON** 根本无法解析，必须抬预算重试。

生产侧确认修复生效：`request.retry` 带 `maxTokensRaisedTo: 32768` → 随后
`chapter_beats.generated` 首次成功产出这本书的节拍卡。

### 一处刻意的测试反转，请重点看

`test/NativeCoreSmoke.swift` 原有探针 `assertBudgetExhaustionIsNotRetried` 断言
「预算耗尽绝不重试」，与本修复直接冲突。它的前提是「结果由提示词和预算唯一确定，
重试只是烧时间」——**这个前提被 5347–16383 的实测推翻了**。我改写了探针而不是弱化修复，
重命名为 `assertEmptyContentRetriesAtRaisedBudget`，并在文档注释里记下反转原因。

探针现在断言**每次请求实际发出的 `max_tokens`**（`observedMaxTokens()`）。这是关键：
只断言重试次数的话，「重试但不抬预算」——也就是生产上真实发生的那个 bug——照样能通过。
`URLProtocol` 在 session 取走请求后会把 `httpBody` 置空，所以取值要从 `httpBodyStream` 抽干。

**变异验证（已执行，双向成立）**：把 `InkOSCoreLLM.swift:2636` 的 `budget = raised` 删掉、
保留重试与 `raisedTo` 日志，探针如期失败：

```
NativeCoreSmoke.swift:2660: Precondition failed:
retry must double the ceiling, saw [Optional(16384), Optional(16384)]
```

这正是生产上那个 bug 的形态。恢复后重新全绿（改动前后 `shasum` 一致，变异未残留）。
附带一个独立信号：变异后编译器报 `variable 'budget' was never mutated`，
所以这个退化在 CI 里也不会静默通过。

六个用例：流式 length-空内容抬到 `[16384, 32768]`；每级都耗尽得到
`[16384, 32768, 65536]` 且报错文案含 `max_tokens` 与 `推理模型`；已在 `maxTokensRetryCeiling`
上配置的核心必须首次失败且 `requestCount() == 1`；`stop`-带推理-空内容同样抬预算；
截断 JSON 抬预算；截断**散文**必须原样返回且 `requestCount() == 1`；502 传输失败以
**不变**的上限重试 `[16384, 16384]`。

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
  macos/ChapterPublisher/InkOSCoreDerivative.swift \
  macos/ChapterPublisher/InkOSCoreCanon.swift \
  macos/ChapterPublisher/InkOSCoreTimeline.swift \
  test/NativeCoreSmoke.swift \
  -o /tmp/macink-smoke && /tmp/macink-smoke

xcodebuild -project ChapterPublisher.xcodeproj -scheme ChapterPublisher \
  -configuration Debug -destination 'platform=macOS' build

xcodebuild -project ChapterPublisher.xcodeproj -scheme ChapterPublisher \
  -configuration Release -destination 'platform=macOS' build

xcodebuild -project ChapterPublisher.xcodeproj -scheme ChapterPublisher \
  -configuration Debug CODE_SIGNING_ALLOWED=NO analyze
```

四条全部通过（`Native InkOSCore smoke test passed`、两次 `BUILD SUCCEEDED`、
`ANALYZE SUCCEEDED`）。Release bundle 的 Info.plist 已核对为 `1.2.0 (2)`。
`InkOSCoreCanon.swift` / `InkOSCoreDerivative.swift` / `InkOSCoreTimeline.swift` 必须
出现在 smoke 编译列表里，否则链接失败。

应用级隔离也已通过：直接执行 Release bundle 内二进制并传入空的
`MACINKOSTOMO_WORKSPACE=$(mktemp -d)`，5 秒后进程仍存活，临时目录产生独立
`book/books`、`data/state.json`、`data/debug` 和 `data/settings-backups`；应用无子进程、
进程树无 TCP LISTEN。第一次探测正是由空目录被忽略而发现第 8 个缺陷，修复后重跑才计为通过。

本轮相关的探针输出行：

```
Explicit workspace isolation probe passed
Derivative retrieval probe passed: semantic on, 3/3 embedded
Canon extraction probe passed: 3 batches, resume + overlay precedence
Derivative timeline probe passed: past/future/unplaced gates + day summation
Model-null normalization probe passed: NSNull tolerated, required nulls throw
```

## 新增 API 面（`InkOSLibrary.swift`，全部已有调用方）

`importDerivativeSource`、`embedDerivativeSource`、`derivativeSourceEmbeddingStatus`、
`retrieveDerivativeContext`、`extractDerivativeCanon`、`extractDerivativeSettingsOverlay`、
`derivativeCanonStatus`、`saveDerivativePreparationIntent`、
`derivativePreparationSnapshot`、`derivativeTimeline`、`saveDerivativeTimeline`、
`derivativeTimelineStatus`、`bookKind`。

调用链已核实：导入与抽取由 `WorkspaceModel.prepareDerivativeSource`（`WorkspaceModel.swift:427`）
经新建小说流程调用；检索注入由 `InkOSCoreLLM.swift:2299` 在 `generationPrompt` 里落地。

## 建议的 review 切入点

按性价比排序：

1. **抬预算之外的重试语义。** 「保留重试、去掉抬预算」这一个变异我已经验证过了
   （见下节），所以不必重跑。仍然没有变异覆盖的是另外三条断言：
   `maxTokensRetryCeiling` 处停止、传输失败**不**抬预算、截断散文原样返回。
   把这三条各自的实现改坏，探针是否都会失败，我没有逐一验证。
2. **`truncatedJSONError` 只对 `json: true` 生效。** 确认截断散文没有被误伤——
   章节正文走的是可恢复路径，误判成错误会白扔已写好的正文。
3. **时间闸门的三类分档边界。** 锚点当天的事件、没有 `sourceDay` 只有 `sourceChapter` 的事件、
   两者都没有的事件，分别落到 past/future/unplaced 的哪一档。本轮修过一次
   「锚点当章事件与非原著里程碑被错分」的缺陷。
4. **禁止清单在正文提示词里的实际位置。** 调用链我已核实（见「设计取舍」），
   但没有验证过**内容对齐**：`derivativeGenerationSections` 给正文的禁止清单，
   与 `derivativeBeatSections` 给节拍卡的那份是否覆盖同一批事件。两份不一致的话，
   节拍卡可能规划出一个正文被禁止写的事件，冲突要到写作阶段才暴露。

## 待处理

**`openHooksText` 无条数上限。** 这是节拍卡提示词里唯一不设上限的段落（对比
`knownEntitiesText(limit: 60)`）。当前投影后 65 条、约 2060 字符，还不构成问题，
但它随伏笔累积单调增长，最终会挤占同一个 `max_tokens` 预算——也就是上面三个缺陷的
同一个根因。（两个数都对，别当成 off-by-one：`baseContinuity.hooks` 是 64，
`manualOverlay.upsert.hooks` 加 1 条，投影后 `continuity.hooks` 是 65。
`status` 报的 `hooks=64` 取的是 base 那一层。）
建议加 limit，但要注意伏笔被截断意味着「回收提醒」丢失，取舍需要产品判断。

**`maxTokens` 仍是 16384。** 配置文件未改动——我没有用户对具体改动的授权。抬预算重试
现在能兜住，但每次兜都要付一趟额外的完整推理。把默认值直接调到 32768 能省掉这笔开销，
需要用户点头。

**第 1 章仍是 `pending_review`，等人工审核。** 两条 soft 建议未处理（字数超上限 29 字、
冷幽默人设未落地）。初审给的具体修法在 `chapters/index.json` 的 `revisionGuidance` 里。

## 现场状态

- 生产工作区：仓库根目录，书 ID `灰雾之前`，路径 `book/books/灰雾之前/`。
- 三个模型角色当前都指向 `deepseek-v4-flash`；`reviewBaseUrl` / `extractionBaseUrl` /
  `extractionApiKey` 留空即继承主角色。
- 驱动程序 `/tmp/macink-prod-driver/proddriver`，用法
  `proddriver <workspace> status <bookID> <chapter>`。它当前的二进制**早于**
  `truncatedJSONError` 改动，要复现抬预算路径需要重新构建。
- `git status` 已确认 `data/` 与 `book/` 不在待提交清单里（被 gitignore 挡住），
  生产数据不会进版本库。
- 文档已同批更新：`AGENTS.md`（Model Roles、Canon Extraction）与
  `README.md`（原著正典抽取段落、第 155 行过期声明）。
