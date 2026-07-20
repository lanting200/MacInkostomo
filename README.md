# MacInkostomo

MacInkostomo 是一个本地 macOS 小说工作台。Xcode 应用使用原生 SwiftUI 界面，不嵌入网页或 `WKWebView`；macOS 26 使用 Liquid Glass，macOS 13 至 25 使用 Material 兼容样式。应用通过本地 API 调用 Node.js 工作流引擎，负责小说创建、章节生成与审核、连续性设定、长篇规划、结构化调试，以及番茄作者端的只读内容对照。

服务只监听 `127.0.0.1:3456`。应用启动时会连接已经运行且身份匹配的服务；端口空闲时会自行启动本仓库中的服务，并在应用退出时结束自己创建的服务进程。

## 架构

- `inkos/packages/core` 是框架内置源码模块，不是外部工具适配层。默认调用路径为 SwiftUI -> 本地 API -> `inkos.pipeline` -> `PipelineRunner`。
- 模块注册表提供依赖检查、并发隔离、超时、熔断和结构化故障；工作流引擎提供分步执行、重试和补偿接口。新增功能应通过模块 port 或工作流 step 接入。
- Publisher 通过进程级 runtime 执行创建、生成、修订、整章重写、同步、审核通过和驳回；任务之间复用模块生命周期、bulkhead 与熔断状态，配置更新时按租约平滑轮换 runtime。
- CLI 不是默认架构边界，仅在显式兼容/诊断模式或内置 core 构建产物缺失时使用，并继续调用同一套框架 core。
- 小说正文、章节索引、设定、运行状态和快照以 `book/books/<bookId>/` 为权威；`data/state.json` 只保存工作台及外部服务元数据。
- 各模块通过显式接口和结构化诊断交互，单个模块故障由 bulkhead/circuit breaker 限定，不应令整个工作台失去响应。
- 章节提交使用 book-scoped rollback journal，把正文、truth、index、book metadata、runtime、long-form、canon checkpoint 和快照纳入同一恢复边界；进程中断后在下一次取得书锁时自动恢复 prepared transaction。

## 长篇小说治理

新建小说必须提供目标总字数、分卷数、目标单章字数、字数容差和至少一条特殊约束。系统支持 `1,000` 至 `3,000,000` 字、最多 100 卷、最多 10,000 章，并把精确逐章和逐卷预算写入 `long-form-plan.json`。

每章结算会更新 `story/state/long_form_state.json`，跟踪时间线、实体状态、人物知识边界、世界规则、随机设定值和伏笔状态。卷末生成 canon checkpoint；修订、修复和重同步从第 N-1 章快照重放，避免把旧的第 N 章聚合状态带回正文。上述产物与章节正文通过同一提交事务落盘，失败会恢复提交前版本。原生设置页可以分别编辑结构预算与 continuity，使用 revision 乐观并发控制，并保护已经影响正文的不可变事实。

## 调试系统

原生 Debug 工作区和浏览器兼容面板读取同一份结构化事件。事件持久化在 `data/debug/events.jsonl`，同时提供：

- `GET /api/debug/events`: 分页、过滤和下载事件
- `GET /api/debug/schema`: 事件字段与版本契约
- `GET /api/debug/health`: 日志文件和框架健康状态
- `GET /api/debug/stream`: SSE 实时事件流

日志包含 trace、book、chapter、module、operation、phase、fault code 和结构化 data，既可供人查看，也可供 Codex 等 agent 直接解析。

## 环境要求

- macOS 13 或更高版本
- Xcode 14 或更高版本
- Node.js 20 或更高版本
- pnpm 9 或更高版本

## 首次准备

```bash
git clone https://github.com/lanting200/MacInkostomo.git
cd MacInkostomo
npm ci
pnpm --dir inkos install --frozen-lockfile
pnpm --dir inkos build
```

随后打开 `ChapterPublisher.xcodeproj`，选择 `ChapterPublisher` scheme，直接运行。生成的产品名称是 `MacInkostomo.app`，Bundle ID 是 `com.lanting200.MacInkostomo`。

Xcode 应用会使用当前源码检出目录中的后端、内置 InkOS core 构建产物、CLI 兼容入口和用户数据，因此首次运行前必须完成上述依赖安装与 InkOS 构建。需要覆盖自动检测路径时，可在 Xcode Scheme 环境变量中设置：

- `CHAPTER_PUBLISHER_ROOT`: 本仓库的绝对路径
- `CHAPTER_PUBLISHER_NODE`: Node.js 可执行文件的绝对路径

Debug 构建会自动使用当前 Xcode 工程目录。Release 产物不会写入构建机的绝对路径；首次启动时可在错误页选择本仓库目录，应用会在本机保存该选择。

## 浏览器兼容模式

不使用 Xcode 时也可以直接运行本地服务：

```bash
npm start
```

然后访问 <http://127.0.0.1:3456>。该界面用于本地兼容和诊断，不是 Xcode 应用的渲染实现。

## 数据与密钥

- `book/` 保存本机 InkOS 小说工程。
- `data/state.json` 保存工作台审核元数据。
- `data/workflow-jobs.json` 保存长任务状态，供应用重启后恢复显示。
- `data/inkos-config.json` 是工作台读取 LLM 密钥的私密来源，文件权限会收紧为 `0600`。
- `data/`、`book/`、`.env`、依赖目录和构建产物均已从 Git 排除。

请在应用设置面板中填写模型端点和密钥。不要把本地服务暴露到公网，也不要把运行数据或密钥加入提交。

LLM 端点默认要求 HTTPS。仅在明确需要连接本机或受控网络中的 HTTP 端点时，设置 `PUBLISHER_ALLOW_INSECURE_LLM_HTTP=true`。

## 验证

运行后端回归测试：

```bash
npm test
```

运行内置 InkOS core 与 CLI 验证：

```bash
pnpm --dir inkos --filter @actalk/inkos-core typecheck
pnpm --dir inkos --filter @actalk/inkos-core test
pnpm --dir inkos --filter @actalk/inkos-core build
pnpm --dir inkos --filter @actalk/inkos typecheck
pnpm --dir inkos --filter @actalk/inkos test
```

检查项目 JavaScript 语法：

```bash
find server.js lib public test -type f -name '*.js' -print0 | xargs -0 -n1 node --check
```

从命令行验证 macOS 工程：

```bash
xcodebuild \
  -project ChapterPublisher.xcodeproj \
  -scheme ChapterPublisher \
  -configuration Debug \
  -derivedDataPath /tmp/MacInkostomo-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  clean build
```

发布前还应把 `-configuration Debug` 替换为 `-configuration Release` 再构建一次，并执行 `git diff --check` 与敏感信息扫描。

## 项目结构

- `server.js`: Express 服务、API 与工作流入口
- `lib/`: Publisher 状态、内置 InkOS runtime、LLM、番茄及持久化模块
- `public/`: 浏览器兼容界面
- `macos/ChapterPublisher/`: 原生 SwiftUI 应用与本地 API 客户端
- `ChapterPublisher.xcodeproj/`: Xcode 工程与共享 scheme
- `inkos/packages/core/src/framework/`: 模块注册、隔离、工作流和结构化诊断框架
- `inkos/`: 已重构并内置于框架的 InkOS 源码
- `test/`: Node.js 回归测试

## 开源许可

本项目按 GNU Affero General Public License v3.0 only 发布，完整条款见 [LICENSE](LICENSE)。仓库包含经本项目适配的 InkOS 源码，来源与基准版本见 [NOTICE](NOTICE)，兼容性改造边界见 [INKOS_COMPATIBILITY_AUDIT.md](INKOS_COMPATIBILITY_AUDIT.md)。
