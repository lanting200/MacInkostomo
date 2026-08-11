# MacInkostomo

MacInkostomo 是原生 macOS 小说工作台。界面使用 SwiftUI；InkOS 已迁入 Xcode target，作为 `InkOSCore` 原生库直接调用。应用不包含网页工作台、本地服务器、监听端口、Express、Node 运行时或子进程桥接；番茄登录 Sheet 仅承载平台官方认证页面。

## 架构

唯一运行路径：

```text
SwiftUI View
  -> WorkspaceModel
  -> InkOSLibrary typed functions
  -> InkOSCore Swift actor
  -> book/data files + configured remote LLM endpoint
```

- `InkOSLibrary` 提供书籍、章节、生成、修订、审核、设定、长篇规划、模型配置、调试和番茄对照函数。
- `InkOSCore` 负责文件事务、任务隔离、模型调用和结构化诊断。
- UI 不直接操作小说文件，也不通过 HTTP、RPC 或命令行调用 InkOS。
- `book/books/<bookId>/` 仍是小说正文、章节索引、设定和连续性状态的权威来源。
- `data/` 保存工作台状态、模型配置、备份和结构化调试事件。

`inkos/` 保存原项目源码快照，用于许可证溯源、迁移比对和语义回归；它不参与 `MacInkostomo.app` 的编译或运行。

## 原生模块

- `InkOSCore.swift`: 原生存储、书籍、章节、审批、任务与调试基础设施。
- `InkOSCorePlanning.swift`: 固定创建引导、精确分卷和最长 300 万字预算。
- `InkOSCoreContinuity.swift`: 已审核章节连续性投影、旧 Delta 迁移、模型字段清洗、人工覆盖和不可变冲突保护。
- `InkOSCoreLLM.swift`: 模型配置、创建辅助、章节生成、修订与一致性审核。
- `InkOSCoreCraft.swift`: 写法内核、本书写法约束、章节节拍卡分批规划、篇幅校验和运行时状态回写。
- `InkOSCoreSettings.swift`: 设定文件和原子备份恢复。
- `InkOSCoreFanqie.swift`: 番茄会话、在线作品与章节读取、创建作品、上传章节和替换章节。
- `InkOSLibrary.swift`: SwiftUI 使用的类型化函数入口。

## 长篇治理

新建小说需要目标总字数、分卷数、单章字数、字数容差和特殊约束。原生核心支持 1,000 至 3,000,000 字、最多 100 卷和 10,000 章，并把总字数精确分配到每章与每卷。

LLM 辅助整理创建方案后，主角性格档案必须在创建向导中经人工逐字审核并确认，否则核心拒绝创建小说。确认后的档案写入 `story/protagonist.md`，在设置页「角色档案」分组维护，并注入每一章的写作提示。

章节生成会读取故事圣经、硬规则、人物知识边界、当前状态、持久对象账本、资源账本、伏笔池、章节摘要、最近卷末检查点和上一章全文。生成结果必须提交 `consistencyDelta`；本地规则先验证跨章顺序、实体准入、删除目标和不可变冲突，再由独立模型联合审核正文、候选 Delta 和应用后的连续性索引。

章节 Delta 的时间线只描述衍生作自身进度，普通生成、修订和人工设定中的 `sourceDay`/`sourceChapter` 会在归一化时清空；只有原著正典抽取可以写入这两个原著坐标。模型把 statement、label、description 等字符串误包成小 JSON 对象或 JSON 字符串时，核心按字段解包成正文文本；投影同步也会清理旧数据中的同类 wrapper。未知的必填容器不会以 JSON 字符串混入后续提示词，而是作为可重试的 Delta 格式错误处理。

审核模型对每个 `[hard]` 问题标注修复范围：`[delta]` 只需补登记，无需动正文；`[prose]` 需要改动正文。未打标签的问题由启发式判定（引用正文作为证据不算需要改正文，"正文与既有记录矛盾"才算）。初审发现的 `[hard]` 若全是 delta 问题，核心单独修复 Delta 并复审，正文不变；一旦有 `[prose]` 问题或 delta-only 修复仍未通过，进入全文自动修改循环，每轮把上一轮审核意见喂回重写模型，最多重写 `maxAutoRevisionRounds` 轮（默认 3），任一轮通过即交人工终审。人工「驳回修改」同样汇入这条流程。正文未过本地篇幅/写法校验时不进循环，直接保留完整草稿并落 `revision_failed` 等人工驳回。

写作响应的 JSON 外壳损坏时，完整正文同样不会被丢弃。核心先记录 `chapter.invalidJson`，再逐字段解码 `title`/`content`/`summary`，不依赖整个对象可解析；只有 `content` 能确认闭合（未转义引号后必须紧跟 `}` 或 `,` 加下一个 `"key":`，因此对白里的裸引号不会截断正文）才算恢复成功，记录 `chapter.proseRecovered`，丢弃损坏外壳里的 Delta 并只补请求 Delta。只有正文本身在字符串中途被截断时，才追加严格格式要求重试整章。

章节链路的全部模型调用都走流式，包括没有实时预览的节拍卡、审核和两处 Delta 补登。这是传输层要求而非界面选择：推理模型在非流式请求下要等思考结束才发第一个字节，而 `URLRequest.timeoutInterval` 计的是数据静默间隔，思考一旦超过上限就会以 `URLError -1001` 中断。同一节拍卡提示实测非流式首字节 113.9s、流式 2.4s。超时上限统一为 900s，覆盖实测最慢的节拍卡批次（899s）。回归测试在传输模式不匹配时失败，因此改回非流式会直接测出来。

Delta 补登的每条失败路径都会记录 `chapter.deltaRepair.failed` 和具体 `reason`：`requestFailed`（带 statusCode）、`invalidJson`（带首尾片段）、`missingDeltaField`（带实际返回的键）。补登失败时正文保持已恢复的内容，章节落 `revision_failed` 等人工重试。此时本章还没有一致性文件，复校验和 Delta-only 修复都按空 Delta 起步并记录 `chapter.delta.missingForRepair`，不再因为读不到文件而退化成整章重写；人工审核通过与连续性投影仍然要求一致性文件存在。

## 写法治理

分卷目标不足以约束单章内容，因此生成前先规划章节节拍卡。写作阶段只接收当前章的节拍卡，而不是整卷概要。

- 节拍卡按卷内每 10 章一批生成，写入 `story/runtime/chapter-beats.json`，包含本章目标、入场点、场景、必须发生的事件、必须出现的挫折、**禁止提前出现或提前解决的内容**、时间跨度、新增具名人物上限和章末钩子。人工审核每章时会在同一事务内保留本章及历史节拍、清除所有后续节拍；只有当前批次末章审核通过后，才使用新的连续性投影后台预排下一批。失败会连同章节状态、投影和节拍文件一起回滚。
- 规划模型收到本批次在卷内的进度百分比，并被要求把排期更晚的剧情写入禁止清单，防止开篇章吞掉后续几十章的内容。
- 节拍提示中的未回收伏笔最多保留 24 条、总计 4,800 字符，单条描述最多 180 字符；已到期和临近到期者优先，同等优先级保留最近开启者，并以完整行和省略计数收口。连续性上下文也按字符预算输出完整、可解析的紧凑 JSON，保留 policy，优先实体身份、到期伏笔和最近时间线，并在 `_truncation` 中记录省略数与字段裁剪数。
- 写法内核在 Swift 侧固定生效，覆盖场景纪律、入场方式、信息节奏、对话承载、场面完成度、视角、时间尺度、章末处理和篇幅来源；前三章附加开篇规则，限制单章线索数量并禁止金手指在本章内完成完整闭环。
- `story/craft_rules.md` 是本书可编辑的写法约束，在设置页“世界与卷纲”分组中紧随文风指南维护，只能叠加在内核之上。
- 篇幅按 `long-form-plan.json` 的每章 `minWords`/`maxWords` 校验，窗口按平台字数（含标点）计算，另设中文字符密度下限，防止靠标点凑数。模型已返回完整正文时，篇幅、写法或 Delta 本地校验失败不会丢弃草稿：正文会以 `revision_failed` 落盘，并附带本地审核意见进入“待修改”。
- 生成与修订在送审前先过本地确定性校验：清单式条目铺陈、总结或淡出式收尾直接退稿；前三章作为开篇段整体至少建立一次核心能力异常锚点，前章已经建立后不要求后续章重复，且节拍卡的禁止清单优先于重复锚点。这些规则与审核模型的同类 `[hard]` 规则互为兜底。
- 审核区分严重级别，并要求每条 `[hard]` 附带修复范围标签：`[delta]` 表示正文无需改动、只补候选 Delta 登记；`[prose]` 表示必须改正文。全部 `[hard]` 都是 `[delta]` 时先走登记单独修复、正文一字不动；出现任一 `[prose]` 才进入全文修订。模型漏标时按措辞推断，并按"引用正文作为登记依据"与"正文本身有缺陷"区分：`正文明确写出伤势，但 ENT-004 的 attributes 为空` 判为 `[delta]`，`正文数字与已登记消耗矛盾` 判为 `[prose]`。判定偏向 `[delta]` 是有意的——登记修复不动正文，复审仍不过会自动落回重写循环，而误判成 `[prose]` 会让模型重写一篇本来正确的正文、触发停滞检测。本地篇幅/写法校验结论固定标 `[prose]`，本地连续性差量冲突固定标 `[delta]`。
- 本地校验失败稿按默认意见再次提交时先重新校验并复审原正文，仍未通过才进入全文自动修改；正文、排期与篇幅问题最多执行 `maxAutoRevisionRounds` 轮（默认 3）重写+复审。两类情况提前终止而不耗尽轮次：模型两次返回逐字相同的正文（第一次会抬高温度并给出强化指令重试），以及服务端以 4xx 拒绝请求（429 除外，那已由传输层重试过）——重发同一调用不会成功。模型停滞时，章节记录的失败原因是当前真正的阻断项，不是"输出与原文完全相同"这类机制信息。
- `[soft]` 写法问题记入 `llmReview.craftAdvisories` 并进入人工审核；所有提交和轮次都在 `llmReview.attempts` 中连续追加，后一轮异常也会把完整历史与最新错误写回章节。`attempts` 是这条流程的完整台账，本地校验、原稿复审、Delta 单独修复和每轮重写各占一条，所以它的条数通常大于自动重写轮数。审核工作台的进度视图会按实际上限显示当前自动修改轮次和流式正文。
- 章节通过人工审核后，`current_state.md`、`pending_hooks.md` 和 `current_focus.md` 由核心基于审核后的新投影自动回写，不再停留在创建时的占位内容；这三个文件在设置页标记为自动重写并给出覆盖提示，人工修改会在下次审核后失效，连续性事实的人工调整走「长篇计划 · 连续性」覆盖层，单章内容调整走节拍卡。
- 章节重新修订时，其后续章节的节拍卡自动失效并在下次生成时重新规划。

人工审核通过后，章节 `consistencyDelta` 会自动投影到 `long-form-plan.json.continuity`。章节重新修订时旧贡献自动退出，重新审核后由新 Delta 替换；设置页的人工修改以覆盖层保存。投影记录位于 `story/runtime/continuity-projection.json`，可供调试面板和自动化 Agent 直接解析与重放。

一致性策略均参与运行：`requireContinuousVolumes` 阻止跳章和跨越未审核章节；`allowUnplannedEntities` 控制正文能否新增未登记实体；`requireConsistencyDelta` 是强制章节契约；`checkpointAtVolumeEnd` 在每卷全部通过后生成 `story/runtime/checkpoints/volume-XXXX.canon.json`，章节重新修订时自动失效并在再次审核后重建。

## 数据目录

- Debug 构建使用 Xcode 工程目录中的现有 `book/` 和 `data/`，便于开发调试。
- Release 构建使用 `~/Library/Application Support/MacInkostomo/`。
- Release 首次运行会从旧工作区复制已有书籍与配置，之后由应用数据目录独立持久化。
- `MACINKOSTOMO_WORKSPACE` 可显式指定数据工作区，主要用于测试和受控迁移；空目录也会直接采用，并跳过 Release 首次旧工作区迁移。

## 构建

环境要求：macOS 13 或更高版本、Xcode 14 或更高版本。

```bash
open ChapterPublisher.xcodeproj
```

命令行构建：

```bash
xcodebuild \
  -project ChapterPublisher.xcodeproj \
  -scheme ChapterPublisher \
  -configuration Debug \
  -derivedDataPath /tmp/MacInkostomo-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

发布前把配置换成 `Release` 再构建一次。

## 原生核心测试

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
  -o /tmp/macingkostomo-native-core-smoke

/tmp/macingkostomo-native-core-smoke
```

测试在临时目录验证创建小说、精确预算、设定读取、原子备份恢复、连续性投影、策略执行、卷末检查点和删除，不接触真实用户数据。

## 项目结构

- `macos/ChapterPublisher/`: SwiftUI 界面、状态模型和原生 InkOSCore。
- `ChapterPublisher.xcodeproj/`: Xcode 工程与共享 scheme。
- `book/`: Debug 工作区的小说工程，属于私有用户数据。
- `data/`: Debug 工作区的状态、密钥、备份和调试数据，属于私有用户数据。
- `macos/ChapterPublisher/InkOSCoreDerivative.swift`: 同人文原著检索核心（编码识别、章节切分、BM25 + 语义混合检索）。新建小说选“同人”并上传原著后由界面触发，检索结果在写章节时注入提示词。
- `macos/ChapterPublisher/InkOSCoreCanon.swift`: 把原著批量抽成正典（不可变事实、世界规则、实体、知识边界、时间线、伏笔），断点续跑，客户设定以 overlay 形式压过原著。
- `macos/ChapterPublisher/InkOSCoreTimeline.swift`: 同人时间进度系统。以原著锚点事件为 0 天，按节拍卡的 `storyDays` 累加推算本章故事日期，把原著事件分成已发生／尚未发生／时间点未确定三类写进节拍与正文提示词，用来防止同人文时间线错乱。
- `test/NativeCoreSmoke.swift`: 原生核心临时工作区回归测试。
- `inkos/`: 上游源码与许可证迁移对照，不进入 App runtime。

## 模型角色

设置页按角色配置三套模型，各自有独立的 Base URL、API Key 和模型名：

- 章节生成（`model` / `baseUrl` / `apiKey`）：主模型，其余角色的回退目标。
- 设定与初审（`reviewModel` / `reviewBaseUrl` / `reviewApiKey`）。
- 原著抽取 RAG（`extractionModel` / `extractionBaseUrl` / `extractionApiKey`）：用于把同人文原著抽成正典设定，建议选长上下文模型。

任一角色的字段留空即继承章节生成的对应值，所以只想换模型名时不必重填端点和密钥。原著抽取是可选角色：三个字段全空时不参与保存校验；一旦填写，保存前同样要求测速通过。

## 原著正典抽取

同人创作只需要客户提供两样东西：一份原著 txt 和一段作者设定文本。

- `importDerivativeSource` 导入原著：识别编码、切分章节并建立 SQLite/FTS 词法索引；准备流程再按创建时的意图完成端侧语义向量。
- `extractDerivativeCanon` 把原著抽成正典：按字数预算分批（默认每批 1.5 万字符）交给原著抽取模型，逐批合并进连续性投影的 `baseContinuity`。数字章节之前保留的 index 0 卷首/序章也会纳入抽取，并以独立状态位检查点化；进度写在 `source/canon-progress.json`，每批落一次盘，中断后可续跑，旧进度会从已完成批次恢复序章状态。某一批失败不影响之前已完成的批次。换了原著文件会同时清掉旧进度和旧 `baseContinuity`，但保留作者 overlay 与已审核章节贡献。
- `extractDerivativeSettingsOverlay` 把作者设定文本写进 `manualOverlay`。这一层在投影时最后应用且允许覆盖不可变字段，所以设定文本与原著冲突时以设定文本为准。
- 原著章号会统一改写成衍生作自己的章号，原始出处保留在 `markers` 里（`source-chapter-N`）。
- 同名原著实体跨批次生成不同 ID 时按规范化名称归并：首个实体保留 ID 与 type，后续批次补充属性；type 冲突写入 `canon.entity.type_conflict`，不会生成第二个同名实体。恢复旧检查点时会先按同一规则去重并重建 source-only `baseContinuity`，保留人工 overlay 与已审核章节贡献。
- `source/preparation.json` 保存作者设定文本和是否建立语义索引的意图。App 重启后会恢复未完成横幅；即使正典已完成，overlay 或索引失败也可以继续处理。旧版本没有该文件时，核心会复用现有原著、正典游标和索引合成可续跑记录；原作者设定文本已无持久副本时按空 overlay 恢复，并继续完成正典与语义索引。
- `sourceDay` 只接受相对整部原著全局锚点的日期。未直接包含锚点的批次不保留模型输出的批次局部日期；作者 overlay 的时间线也不带原著坐标。

导入与抽取由新建小说流程调用（`WorkspaceModel.prepareDerivativeSource`），抽取进度显示在工作区顶部。`generateChapter`、`reviseChapter` 和 `approveChapter` 都会先确认正典、作者 overlay、所请求的语义索引以及可解析的时间锚点已经准备完成；准备不完整时不会启动写作任务或批准章节。

生成、全文修订和独立审校共用同一套同人时间线与原文检索组装。检索 key 只取节拍目标、场景和必写事件中已登记的原著正典实体；即使没有 key，只要节拍或回退 query 非空仍执行检索。时间线同时给检索设置原著章号上界：锚点前最多读到锚点前一章，锚点后最多读到已经发生事件中的最晚原著章；FTS 与向量候选都在 SQL 查询阶段过滤，未来原文不会先进入候选再被截掉。审校提示明确要求：正文提前发生、知晓、预言或议论未来原著事件时必须输出 `[hard][prose]`。

## 密钥

模型密钥保存在私有配置文件中并收紧为 `0600`。设置页只显示遮罩预览。远程模型地址默认要求 HTTPS；已有配置明确启用 HTTP 时，原生核心仍会执行同一配置约束。三个角色的密钥都不会随配置读取返回界面，编码时固定写空串。

## 许可

项目按 GNU Affero General Public License v3.0 only 发布。InkOS 来源与基准版本见 [NOTICE](NOTICE)，迁移边界见 [INKOS_COMPATIBILITY_AUDIT.md](INKOS_COMPATIBILITY_AUDIT.md)。
