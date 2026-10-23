import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if let window = mainFlutterWindow as? MainFlutterWindow,
      window.prepareForTermination({ sender.reply(toApplicationShouldTerminate: true) }) {
      return .terminateLater
    }
    return .terminateNow
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls { ExternalVideoInbox.shared.accept(url) }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

// The OS grants access to the opened document. Copy it while that grant is
// active; Dart imports the copy and explicitly releases this incoming file.
final class ExternalVideoInbox {
  static let shared = ExternalVideoInbox()
  private let worker = DispatchQueue(label: "app.aiplayer.external-video", qos: .userInitiated)
  private let lock = NSLock()
  private var generation = 0
  private var channel: FlutterMethodChannel?
  private var ready = false
  private var pending: [[String: Any]] = []
  private var lastURL: URL?
  private var lastOpen = Date.distantPast
  private let incoming = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("external-incoming", isDirectory: true)
  private let extensions = Set(["mp4", "mkv", "mov", "m4v", "avi", "webm", "ts", "m2ts", "mpeg", "mpg", "wmv", "flv", "rmvb", "ogv", "3gp", "vob", "asf", "mts"])

  private init() {
    worker.async {
      try? FileManager.default.createDirectory(at: self.incoming, withIntermediateDirectories: true)
      let files = (try? FileManager.default.contentsOfDirectory(at: self.incoming,
        includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      for file in files where file.lastPathComponent.hasPrefix("open-") {
        if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
          date.timeIntervalSinceNow < -86400 {
          try? FileManager.default.removeItem(at: file)
        }
      }
    }
  }

  func bind(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "app.aiplayer/external_video", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "getPending":
        self.ready = true
        let values = self.pending
        self.pending.removeAll()
        result(values)
      case "cancel":
        self.cancelPending()
        self.lock.lock(); self.generation += 1; self.lock.unlock()
        result(nil)
      case "releaseIncoming":
        guard let path = (call.arguments as? String) ?? ((call.arguments as? [String: Any])?["path"] as? String) else { result(nil); return }
        self.worker.async {
          let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
          let folder = self.incoming.standardizedFileURL.resolvingSymlinksInPath()
          if file.deletingLastPathComponent() == folder && file.lastPathComponent.hasPrefix("open-") {
            try? FileManager.default.removeItem(at: file)
          }
          DispatchQueue.main.async { result(nil) }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  func accept(_ url: URL) {
    // Scene and application delegates may both deliver the same initial URL.
    if lastURL == url && Date().timeIntervalSince(lastOpen) < 1 { return }
    lastURL = url; lastOpen = Date()
    cancelPending()
    lock.lock(); generation += 1; let request = generation; lock.unlock()
    if url.scheme == "http" || url.scheme == "https" {
      deliver(["uri": url.absoluteString, "name": url.lastPathComponent], request: request)
      return
    }
    guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()) else {
      deliver(["error": "文件类型不受支持，请选择视频文件。"], request: request)
      return
    }
    worker.async { self.copy(url, request: request) }
  }

  private func cancelPending() {
    for value in pending {
      if let path = value["path"] as? String { try? FileManager.default.removeItem(atPath: path) }
    }
    pending.removeAll()
  }

  private func current(_ request: Int) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return request == generation
  }

  private func copy(_ url: URL, request: Int) {
    guard current(request) else { return }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let name = String(url.lastPathComponent.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0)
    }.map(String.init).joined().prefix(180))
    let target = incoming.appendingPathComponent("open-\(UUID().uuidString).\(url.pathExtension.lowercased())")
    let partial = target.appendingPathExtension("part")
    defer { try? FileManager.default.removeItem(at: partial) }
    var coordinationError: NSError?
    var copyError: Error?
    var copied = false
    let coordinator = NSFileCoordinator(filePresenter: nil)
    coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
      do {
        try FileManager.default.createDirectory(at: self.incoming, withIntermediateDirectories: true)
        guard let input = InputStream(url: readable), let output = OutputStream(url: partial, append: false) else {
          throw CocoaError(.fileReadUnknown)
        }
        input.open(); output.open()
        defer { input.close(); output.close() }
        let bufferSize = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var total = 0
        while self.current(request) {
          let count = input.read(&buffer, maxLength: bufferSize)
          if count < 0 { throw input.streamError ?? CocoaError(.fileReadUnknown) }
          if count == 0 { break }
          try buffer.withUnsafeBufferPointer { bytes in
            var offset = 0
            while offset < count && self.current(request) {
              let written = output.write(bytes.baseAddress!.advanced(by: offset), maxLength: count - offset)
              if written <= 0 { throw output.streamError ?? CocoaError(.fileWriteUnknown) }
              offset += written
            }
          }
          total += count
        }
        guard self.current(request) else { return }
        guard total > 0 else { throw CocoaError(.fileReadCorruptFile) }
        output.close()
        try FileManager.default.moveItem(at: partial, to: target)
        copied = true
      } catch { copyError = error }
    }
    guard current(request) else {
      try? FileManager.default.removeItem(at: target)
      return
    }
    if copied {
      deliver(["path": target.path, "name": name, "temporary": true], request: request)
    } else {
      let error = (copyError as NSError?) ?? coordinationError
      let message: String
      if error?.code == NSFileReadNoPermissionError {
        message = "没有此视频的读取权限，请从原应用重新选择“打开方式”或“分享”。"
      } else if error?.code == NSFileWriteOutOfSpaceError {
        message = "存储空间不足，无法接收此视频。"
      } else {
        message = "无法读取视频，请确认文件已下载且仍可访问。"
      }
      deliver(["error": message], request: request)
    }
  }

  private func deliver(_ value: [String: Any], request: Int) {
    DispatchQueue.main.async {
      guard self.current(request) else {
        if let path = value["path"] as? String { try? FileManager.default.removeItem(atPath: path) }
        return
      }
      if self.ready { self.channel?.invokeMethod("onOpen", arguments: value) }
      else { self.pending.append(value) }
    }
  }
}
