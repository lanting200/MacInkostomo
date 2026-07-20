# MacInkostomo

MacInkostomo 是一个本地 macOS 小说工作台。Xcode 应用使用原生 SwiftUI 界面，并通过本地 API 调用 Node.js 工作流引擎，负责章节导入、InkOS 生成与审核、设定管理，以及番茄作者端的只读内容对照。macOS 26 使用 Liquid Glass，macOS 13 至 25 使用 Material 兼容样式。

服务只监听 `127.0.0.1:3456`。应用启动时会连接已经运行且身份匹配的服务；端口空闲时会自行启动本仓库中的服务，并在应用退出时结束自己创建的服务进程。

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

Xcode 应用会使用当前源码检出目录中的后端、InkOS CLI 和用户数据，因此首次运行前必须完成上述依赖安装与 InkOS 构建。需要覆盖自动检测路径时，可在 Xcode Scheme 环境变量中设置：

- `CHAPTER_PUBLISHER_ROOT`: 本仓库的绝对路径
- `CHAPTER_PUBLISHER_NODE`: Node.js 可执行文件的绝对路径

Debug 构建会自动使用当前 Xcode 工程目录。Release 产物不会写入构建机的绝对路径；首次启动时可在错误页选择本仓库目录，应用会在本机保存该选择。

## 浏览器模式

不使用 Xcode 时也可以直接运行本地服务：

```bash
npm start
```

然后访问 <http://127.0.0.1:3456>。

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

## 项目结构

- `server.js`: Express 服务、API 与工作流入口
- `lib/`: 状态、InkOS、LLM、番茄及持久化模块
- `public/`: 浏览器界面
- `macos/ChapterPublisher/`: 原生 SwiftUI 应用与本地 API 客户端
- `ChapterPublisher.xcodeproj/`: Xcode 工程与共享 scheme
- `inkos/`: 随仓库发布的 InkOS 源码快照
- `test/`: Node.js 回归测试

## 开源许可

本项目按 GNU Affero General Public License v3.0 only 发布，完整条款见 [LICENSE](LICENSE)。仓库包含经本项目适配的 InkOS 源码，来源与基准版本见 [NOTICE](NOTICE)，兼容性改造边界见 [INKOS_COMPATIBILITY_AUDIT.md](INKOS_COMPATIBILITY_AUDIT.md)。
