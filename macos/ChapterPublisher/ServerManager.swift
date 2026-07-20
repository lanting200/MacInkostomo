import AppKit
import Darwin
import Foundation

@MainActor
final class ServerManager: ObservableObject {
  enum Phase {
    case idle
    case starting(title: String, detail: String)
    case ready
    case failed(title: String, detail: String)
  }

  @Published private(set) var phase: Phase = .idle
  @Published private var capturedLog = ""

  var logExcerpt: String {
    String(capturedLog.suffix(8_000)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static let port = 3456
  private static let serviceName = "chapter-publisher"
  private static let repositoryRootDefaultsKey = "MacInkostomoRepositoryRoot"
  private static let healthURL = URL(string: "http://127.0.0.1:3456/api/health")!

  private let healthSession: URLSession
  private var launchTask: Task<Void, Never>?
  private var serverProcess: Process?
  private var stdoutPipe: Pipe?
  private var stderrPipe: Pipe?
  private var ownsServer = false
  private var attempt = 0
  private var isTerminating = false

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 1.5
    configuration.timeoutIntervalForResource = 2
    healthSession = URLSession(configuration: configuration)
  }

  func startIfNeeded() {
    guard case .idle = phase else { return }
    start()
  }

  func retry() {
    guard !isTerminating else { return }
    launchTask?.cancel()
    stopOwnedServer()
    phase = .idle
    start()
  }

  func selectRepositoryRoot() {
    guard !isTerminating else { return }
    let panel = NSOpenPanel()
    panel.title = "选择 MacInkostomo 项目目录"
    panel.message = "请选择包含 server.js、package.json 和 inkos 目录的项目根目录。"
    panel.prompt = "选择项目"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false

    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let root = try validateRepositoryRoot(url.path, source: "所选目录")
      UserDefaults.standard.set(root.path, forKey: Self.repositoryRootDefaultsKey)
      retry()
    } catch let issue as StartupIssue {
      phase = .failed(title: issue.title, detail: issue.detail)
    } catch {
      phase = .failed(title: "项目目录无效", detail: error.localizedDescription)
    }
  }

  func applicationWillTerminate() {
    isTerminating = true
    attempt += 1
    launchTask?.cancel()
    launchTask = nil
    stopOwnedServer()
  }

  private func start() {
    attempt += 1
    let currentAttempt = attempt
    capturedLog = ""
    phase = .starting(
      title: "正在连接本地服务",
      detail: "正在检查 127.0.0.1:\(Self.port)"
    )

    launchTask = Task { [weak self] in
      guard let self else { return }
      await self.startServer(attempt: currentAttempt)
    }
  }

  private func startServer(attempt currentAttempt: Int) async {
    do {
      switch await probeHealth() {
      case .matching:
        guard currentAttempt == attempt else { return }
        ownsServer = false
        phase = .ready
        return
      case .foreign(let statusCode):
        throw StartupIssue(
          title: "端口已被其他服务占用",
          detail: portConflictDetail(statusCode: statusCode)
        )
      case .unreachable:
        break
      }

      try Task.checkCancellation()
      phase = .starting(
        title: "正在检查运行环境",
        detail: "正在定位项目目录和 Node.js"
      )

      let root = try resolveRepositoryRoot()
      let node = try resolveNodeExecutable()
      try Task.checkCancellation()

      phase = .starting(
        title: "正在启动章节工作台",
        detail: "Node.js 正在加载 Express 与 InkOS"
      )

      let process = try launchServer(root: root, node: node, attempt: currentAttempt)

      for _ in 0..<80 {
        try Task.checkCancellation()
        guard currentAttempt == attempt else { return }

        switch await probeHealth() {
        case .matching:
          phase = .ready
          return
        case .foreign(let statusCode):
          throw StartupIssue(
            title: "端口响应不匹配",
            detail: portConflictDetail(statusCode: statusCode)
          )
        case .unreachable:
          if !process.isRunning {
            throw processExitIssue(process)
          }
        }

        try await Task.sleep(nanoseconds: 250_000_000)
      }

      throw StartupIssue(
        title: "本地服务启动超时",
        detail: "服务在 20 秒内没有通过健康检查。请查看启动日志，处理后重试。"
      )
    } catch is CancellationError {
      return
    } catch {
      guard currentAttempt == attempt, !isTerminating else { return }
      stopOwnedServer()
      if let issue = error as? StartupIssue {
        phase = .failed(title: issue.title, detail: issue.detail)
      } else {
        phase = .failed(
          title: "章节工作台启动失败",
          detail: error.localizedDescription
        )
      }
    }
  }

  private func resolveRepositoryRoot() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    if let override = environment["CHAPTER_PUBLISHER_ROOT"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !override.isEmpty
    {
      return try validateRepositoryRoot(override, source: "CHAPTER_PUBLISHER_ROOT")
    }

    if let saved = UserDefaults.standard.string(forKey: Self.repositoryRootDefaultsKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !saved.isEmpty
    {
      if let root = try? validateRepositoryRoot(saved, source: "已保存的项目目录") {
        return root
      }
      UserDefaults.standard.removeObject(forKey: Self.repositoryRootDefaultsKey)
    }

    guard
      let configured = Bundle.main.object(forInfoDictionaryKey: "ChapterPublisherRoot") as? String,
      !configured.isEmpty,
      !configured.contains("$(")
    else {
      throw StartupIssue(
        title: "没有找到项目目录",
        detail: "请选择本仓库的项目目录，或在 Scheme 中设置 CHAPTER_PUBLISHER_ROOT。"
      )
    }

    return try validateRepositoryRoot(configured, source: "Xcode SRCROOT")
  }

  private func validateRepositoryRoot(_ rawPath: String, source: String) throws -> URL {
    let expanded = (rawPath as NSString).expandingTildeInPath
    let root = URL(fileURLWithPath: expanded, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw StartupIssue(
        title: "项目目录不存在",
        detail: "\(source) 指向：\(root.path)\n请修正该路径后重试。"
      )
    }

    let requiredFiles = [
      "server.js",
      "package.json",
      "public/index.html",
      "node_modules/express/package.json",
      "inkos/packages/cli/dist/index.js",
    ]
    let missing = requiredFiles.filter {
      !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
    }

    guard missing.isEmpty else {
      let list = missing.map { "- \($0)" }.joined(separator: "\n")
      throw StartupIssue(
        title: "项目运行文件不完整",
        detail: "项目目录：\(root.path)\n缺少：\n\(list)\n\n请在项目目录安装依赖并构建 InkOS 后重试。"
      )
    }

    return root
  }

  private func resolveNodeExecutable() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    if let override = environment["CHAPTER_PUBLISHER_NODE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !override.isEmpty
    {
      guard let node = executableURL(at: override) else {
        throw StartupIssue(
          title: "Node.js 路径无效",
          detail: "CHAPTER_PUBLISHER_NODE 指向：\(override)\n请设置为可执行的 Node.js 文件。"
        )
      }
      return node
    }

    let candidates = [
      "/usr/local/bin/node",
      "/opt/homebrew/bin/node",
      "/opt/homebrew/opt/node/bin/node",
    ]
    for candidate in candidates {
      if let node = executableURL(at: candidate) {
        return node
      }
    }

    if let discovered = loginShellValue(
      marker: "__CHAPTER_PUBLISHER_NODE__",
      command:
        "candidate=\"$(command -v node 2>/dev/null)\"; printf '__CHAPTER_PUBLISHER_NODE__%s\\n' \"$candidate\""
    ), let node = executableURL(at: discovered) {
      return node
    }

    throw StartupIssue(
      title: "没有找到 Node.js",
      detail: "请安装 Node.js，或在 Scheme 中将 CHAPTER_PUBLISHER_NODE 设置为 Node.js 的完整路径。"
    )
  }

  private func executableURL(at rawPath: String) -> URL? {
    let expanded = (rawPath as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/"),
      FileManager.default.isExecutableFile(atPath: expanded)
    else {
      return nil
    }
    return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
  }

  private func launchServer(root: URL, node: URL, attempt currentAttempt: Int) throws -> Process {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()

    process.executableURL = node
    process.arguments = [root.appendingPathComponent("server.js").path]
    process.currentDirectoryURL = root
    process.environment = runtimeEnvironment(root: root, node: node)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout
    process.standardError = stderr

    consume(stdout, label: "stdout")
    consume(stderr, label: "stderr")

    process.terminationHandler = { [weak self] completedProcess in
      Task { @MainActor [weak self] in
        self?.serverDidExit(completedProcess, attempt: currentAttempt)
      }
    }

    serverProcess = process
    stdoutPipe = stdout
    stderrPipe = stderr
    ownsServer = true

    do {
      try process.run()
      appendLog("[launcher] \(node.path) \(root.appendingPathComponent("server.js").path)\n")
      return process
    } catch {
      clearProcessReferences(process)
      throw StartupIssue(
        title: "Node.js 启动失败",
        detail: "执行文件：\(node.path)\n项目目录：\(root.path)\n错误：\(error.localizedDescription)"
      )
    }
  }

  private func runtimeEnvironment(root: URL, node: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    var entries: [String] = []

    func appendPath(_ value: String?) {
      guard let value else { return }
      for entry in value.split(separator: ":").map(String.init) where !entry.isEmpty {
        if !entries.contains(entry) {
          entries.append(entry)
        }
      }
    }

    appendPath(node.deletingLastPathComponent().path)
    appendPath(environment["PATH"])
    appendPath(
      loginShellValue(
        marker: "__CHAPTER_PUBLISHER_PATH__",
        command: "printf '__CHAPTER_PUBLISHER_PATH__%s\\n' \"$PATH\""
      ))
    appendPath("/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")

    environment["PATH"] = entries.joined(separator: ":")
    environment["PORT"] = String(Self.port)
    environment["CHAPTER_PUBLISHER_ROOT"] = root.path
    return environment
  }

  private func loginShellValue(marker: String, command: String) -> String? {
    let environment = ProcessInfo.processInfo.environment
    let configuredShell = environment["SHELL"] ?? "/bin/zsh"
    let shell =
      FileManager.default.isExecutableFile(atPath: configuredShell)
      ? configuredShell
      : "/bin/zsh"

    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-lic", command]
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }

      let text = String(decoding: data, as: UTF8.self)
      guard let markerRange = text.range(of: marker, options: .backwards) else { return nil }
      let value = text[markerRange.upperBound...]
        .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        .first
        .map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return value?.isEmpty == false ? value : nil
    } catch {
      return nil
    }
  }

  private func consume(_ pipe: Pipe, label: String) {
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      let text = String(decoding: data, as: UTF8.self)
      Task { @MainActor [weak self] in
        self?.appendLog("[\(label)] \(text)")
      }
    }
  }

  private func appendLog(_ text: String) {
    capturedLog.append(text)
    if capturedLog.count > 64_000 {
      capturedLog = String(capturedLog.suffix(64_000))
    }
  }

  private func serverDidExit(_ process: Process, attempt currentAttempt: Int) {
    guard currentAttempt == attempt, serverProcess === process else { return }
    let wasOwned = ownsServer
    clearProcessReferences(process)

    guard wasOwned, !isTerminating else { return }
    phase = .failed(
      title: "本地服务已退出",
      detail: "Node.js 已结束（退出码 \(process.terminationStatus)）。请查看启动日志，处理后重试。"
    )
  }

  private func stopOwnedServer() {
    guard ownsServer, let process = serverProcess else { return }
    process.terminationHandler = nil
    if process.isRunning {
      process.terminate()
      let deadline = Date().addingTimeInterval(2)
      while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
      }
      if process.isRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
      }
    }
    clearProcessReferences(process)
  }

  private func clearProcessReferences(_ process: Process) {
    guard serverProcess === process else { return }
    stdoutPipe?.fileHandleForReading.readabilityHandler = nil
    stderrPipe?.fileHandleForReading.readabilityHandler = nil
    stdoutPipe = nil
    stderrPipe = nil
    serverProcess = nil
    ownsServer = false
  }

  private func processExitIssue(_ process: Process) -> StartupIssue {
    StartupIssue(
      title: "本地服务启动后退出",
      detail: "Node.js 已结束（退出码 \(process.terminationStatus)）。请查看启动日志，处理后重试。"
    )
  }

  private func portConflictDetail(statusCode: Int?) -> String {
    let status = statusCode.map { "（HTTP \($0)）" } ?? ""
    return
      "127.0.0.1:\(Self.port) 返回了非 \(Self.serviceName) 服务的响应\(status)。\n请先检查端口占用：lsof -nP -iTCP:\(Self.port) -sTCP:LISTEN"
  }

  private enum HealthProbe {
    case matching
    case unreachable
    case foreign(statusCode: Int?)
  }

  private struct HealthResponse: Decodable {
    let ok: Bool
    let service: String
    let port: Int?
  }

  private func probeHealth() async -> HealthProbe {
    var request = URLRequest(
      url: Self.healthURL,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: 1.5
    )
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
      let (data, response) = try await healthSession.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .foreign(statusCode: nil)
      }
      guard (200..<300).contains(http.statusCode) else {
        return .foreign(statusCode: http.statusCode)
      }
      guard let health = try? JSONDecoder().decode(HealthResponse.self, from: data),
        health.ok,
        health.service == Self.serviceName,
        health.port == nil || health.port == Self.port
      else {
        return .foreign(statusCode: http.statusCode)
      }
      return .matching
    } catch {
      return .unreachable
    }
  }

  private struct StartupIssue: Error {
    let title: String
    let detail: String
  }
}
