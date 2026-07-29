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
- `InkOSCoreContinuity.swift`: 已审核章节连续性投影、旧 Delta 迁移、人工覆盖和不可变冲突保护。
- `InkOSCoreLLM.swift`: 模型配置、创建辅助、章节生成、修订与一致性审核。
- `InkOSCoreCraft.swift`: 写法内核、本书写法约束、章节节拍卡分批规划、篇幅校验和运行时状态回写。
- `InkOSCoreSettings.swift`: 设定文件和原子备份恢复。
- `InkOSCoreFanqie.swift`: 番茄会话、在线作品与章节读取、创建作品、上传章节和替换章节。
- `InkOSLibrary.swift`: SwiftUI 使用的类型化函数入口。

## 长篇治理

新建小说需要目标总字数、分卷数、单章字数、字数容差和特殊约束。原生核心支持 1,000 至 3,000,000 字、最多 100 卷和 10,000 章，并把总字数精确分配到每章与每卷。

章节生成会读取故事圣经、硬规则、人物知识边界、当前状态、持久对象账本、资源账本、伏笔池、章节摘要、最近卷末检查点和上一章全文。生成结果必须提交 `consistencyDelta`；本地规则先验证跨章顺序、实体准入、删除目标和不可变冲突，再由独立模型联合审核正文、候选 Delta 和应用后的连续性索引。任一硬冲突都会令章节进入 `revision_failed`。

## 写法治理

分卷目标不足以约束单章内容，因此生成前先规划章节节拍卡。写作阶段只接收当前章的节拍卡，而不是整卷概要。

- 节拍卡按卷内每 10 章一批懒生成，写入 `story/runtime/chapter-beats.json`，包含本章目标、入场点、场景、必须发生的事件、必须出现的挫折、**禁止提前出现或提前解决的内容**、时间跨度、新增具名人物上限和章末钩子。
- 规划模型收到本批次在卷内的进度百分比，并被要求把排期更晚的剧情写入禁止清单，防止开篇章吞掉后续几十章的内容。
- 写法内核在 Swift 侧固定生效，覆盖场景纪律、入场方式、信息节奏、对话承载、场面完成度、视角、时间尺度、章末处理和篇幅来源；前三章附加开篇规则，限制单章线索数量并禁止金手指在本章内完成完整闭环。
- `story/craft_rules.md` 是本书可编辑的写法约束，在设置页“世界与卷纲”分组中紧随文风指南维护，只能叠加在内核之上。
- 篇幅按 `long-form-plan.json` 的每章 `minWords`/`maxWords` 校验，低于下限或明显超出上限的稿件不予落盘；窗口按平台字数（含标点）计算，另设中文字符密度下限，防止靠标点凑数。
- 生成与修订在送审前先过本地确定性校验：清单式条目铺陈、总结或淡出式收尾直接退稿；前三章正文还必须出现核心能力的异常征兆。这些规则与审核模型的同类 `[hard]` 规则互为兜底。
- 审核区分严重级别：`[hard]` 连续性、排期与篇幅问题阻断章节；`[soft]` 写法问题记入 `llmReview.craftAdvisories` 并进入人工审核，不会把每章都打成 `revision_failed`。
- 章节通过人工审核后，`current_state.md`、`pending_hooks.md` 和 `current_focus.md` 由核心按已审核进度自动回写，不再停留在创建时的占位内容；这三个文件在设置页标记为自动重写并给出覆盖提示，人工修改会在下次审核后失效，连续性事实的人工调整走「长篇计划 · 连续性」覆盖层，单章内容调整走节拍卡。
- 章节重新修订时，其后续章节的节拍卡自动失效并在下次生成时重新规划。

人工审核通过后，章节 `consistencyDelta` 会自动投影到 `long-form-plan.json.continuity`。章节重新修订时旧贡献自动退出，重新审核后由新 Delta 替换；设置页的人工修改以覆盖层保存。投影记录位于 `story/runtime/continuity-projection.json`，可供调试面板和自动化 Agent 直接解析与重放。

一致性策略均参与运行：`requireContinuousVolumes` 阻止跳章和跨越未审核章节；`allowUnplannedEntities` 控制正文能否新增未登记实体；`requireConsistencyDelta` 是强制章节契约；`checkpointAtVolumeEnd` 在每卷全部通过后生成 `story/runtime/checkpoints/volume-XXXX.canon.json`，章节重新修订时自动失效并在再次审核后重建。

## 数据目录

- Debug 构建使用 Xcode 工程目录中的现有 `book/` 和 `data/`，便于开发调试。
- Release 构建使用 `~/Library/Application Support/MacInkostomo/`。
- Release 首次运行会从旧工作区复制已有书籍与配置，之后由应用数据目录独立持久化。
- `MACINKOSTOMO_WORKSPACE` 可显式指定数据工作区，主要用于测试和受控迁移。

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
- `test/NativeCoreSmoke.swift`: 原生核心临时工作区回归测试。
- `inkos/`: 上游源码与许可证迁移对照，不进入 App runtime。

## 密钥

模型密钥保存在私有配置文件中并收紧为 `0600`。设置页只显示遮罩预览。远程模型地址默认要求 HTTPS；已有配置明确启用 HTTP 时，原生核心仍会执行同一配置约束。

## 许可

项目按 GNU Affero General Public License v3.0 only 发布。InkOS 来源与基准版本见 [NOTICE](NOTICE)，迁移边界见 [INKOS_COMPATIBILITY_AUDIT.md](INKOS_COMPATIBILITY_AUDIT.md)。
