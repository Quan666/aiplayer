import Foundation
import CFNetwork
#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif

/// Shared by the macOS and iOS Runner targets. CFNetwork applies the system's
/// per-URL bypass rules before returning HTTP(S) proxies or a PAC configuration.
/// Settings, DNS and PAC execution never run on Flutter's platform/UI thread.
final class SystemProxyHandler {
  private let channel: FlutterMethodChannel
  private let state = SystemProxyQueue()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "app.aiplayer/system_proxy", binaryMessenger: messenger)
    channel.setMethodCallHandler { [state] call, result in
      state.handle(call, result: result)
    }
  }

  func close() {
    channel.setMethodCallHandler(nil)
    state.close()
  }

  deinit { state.close() }
}

private enum SystemProxyFailure: String, Error {
  case invalid = "proxy_resolution_failed"
  case unsupported = "proxy_unsupported"
  case cancelled = "proxy_cancelled"
  case disposed = "proxy_disposed"
  case busy = "proxy_busy"
  case timeout = "proxy_timeout"

  var flutterError: FlutterError {
    FlutterError(code: rawValue, message: "系统代理查询失败，请检查网络设置。", details: nil)
  }
}

/// Only this serial queue owns the backlog. Cancelled active jobs retain their
/// concurrency slot until native work exits, so rapid cancel/retry cannot grow
/// an unbounded OperationQueue. No idle timer or network-settings cache.
private final class SystemProxyQueue {
  private let queue = DispatchQueue(label: "app.aiplayer.system-proxy.control")
  private let workers: OperationQueue = {
    let value = OperationQueue()
    value.name = "app.aiplayer.system-proxy"
    value.qualityOfService = .userInitiated
    value.maxConcurrentOperationCount = 2
    return value
  }()
  private var closed = false
  private var requests: [String: Pending] = [:]
  private var waiting: [Pending] = []
  private var active = 0

  private final class Pending {
    let id: String
    let lookup: AppleSystemProxyLookup
    let result: FlutterResult

    init(id: String, url: String, result: @escaping FlutterResult) {
      self.id = id
      lookup = AppleSystemProxyLookup(url: url)
      self.result = result
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    queue.async {
      let arguments = call.arguments as? [String: Any]
      switch call.method {
      case "resolve":
        guard !self.closed else { self.reply(result, SystemProxyFailure.disposed.flutterError); return }
        guard let id = arguments?["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
          let url = arguments?["url"] as? String, url.utf8.count <= 16384,
          self.requests[id] == nil
        else { self.reply(result, SystemProxyFailure.invalid.flutterError); return }
        guard self.requests.count < 32 else {
          self.reply(result, SystemProxyFailure.busy.flutterError); return
        }
        let pending = Pending(id: id, url: url, result: result)
        self.requests[id] = pending
        self.waiting.append(pending)
        self.startNext()
      case "cancel":
        if let id = arguments?["id"] as? String,
          let pending = self.requests.removeValue(forKey: id) {
          self.waiting.removeAll { $0 === pending }
          pending.lookup.cancel()
          self.reply(pending.result, SystemProxyFailure.cancelled.flutterError)
        }
        self.reply(result, nil)
      default: self.reply(result, FlutterMethodNotImplemented)
      }
    }
  }

  func close() {
    queue.async {
      guard !self.closed else { return }
      self.closed = true
      for pending in self.requests.values {
        pending.lookup.cancel()
        self.reply(pending.result, SystemProxyFailure.disposed.flutterError)
      }
      self.requests.removeAll()
      self.waiting.removeAll()
    }
  }

  private func startNext() {
    while !closed && active < 2 && !waiting.isEmpty {
      let pending = waiting.removeFirst()
      active += 1
      workers.addOperation {
        let value: Any
        do { value = try pending.lookup.resolve() }
        catch let failure as SystemProxyFailure { value = failure.flutterError }
        catch { value = SystemProxyFailure.invalid.flutterError }
        self.queue.async {
          self.active -= 1
          if self.requests[pending.id] === pending {
            self.requests.removeValue(forKey: pending.id)
            self.reply(pending.result, value)
          }
          self.startNext()
        }
      }
    }
  }

  private func reply(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }
}

/// A lookup has one monotonic deadline including queue wait. Cancellation wakes
/// its private worker run loop without polling, and invalidates CFNetwork's PAC
/// source (which also cancels an in-flight PAC download).
final class AppleSystemProxyLookup {
  private let rawURL: String
  private let deadline: TimeInterval
  private let lock = NSLock()
  private var cancelled = false
  private var runLoop: CFRunLoop?
  private var pacSource: CFRunLoopSource?
  private var cancellationSource: CFRunLoopSource?
  // Accessed only on the lookup's worker/run-loop thread.
  private var pacResult: Result<[[String: Any]], SystemProxyFailure>?

  init(url: String, timeout: TimeInterval = 4.5) {
    rawURL = url
    deadline = ProcessInfo.processInfo.systemUptime + timeout
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let source = pacSource
    let wake = cancellationSource
    let loop = runLoop
    lock.unlock()
    if let source = source { CFRunLoopSourceInvalidate(source) }
    if let wake = wake { CFRunLoopSourceSignal(wake) }
    if let loop = loop { CFRunLoopWakeUp(loop) }
  }

  func resolve(settings: CFDictionary? = nil) throws -> String {
    precondition(!Thread.isMainThread, "System proxy resolution must run on a worker")
    try checkCurrent()
    guard let url = URL(string: rawURL), let host = url.host, !host.isEmpty,
      url.scheme == "http" || url.scheme == "https" else { throw SystemProxyFailure.invalid }
    guard let configuration = settings ?? CFNetworkCopySystemProxySettings()?.takeRetainedValue()
    else { throw SystemProxyFailure.invalid }
    let proxies = CFNetworkCopyProxiesForURL(url as CFURL, configuration).takeRetainedValue()
    guard let entries = proxies as? [[String: Any]] else { throw SystemProxyFailure.invalid }
    let routes = try expand(entries, url: url, depth: 0)
    try checkCurrent()
    guard !routes.isEmpty, routes.count <= 32 else { throw SystemProxyFailure.invalid }
    let value = routes.joined(separator: "; ")
    guard value.utf8.count <= 16384 else { throw SystemProxyFailure.invalid }
    return value
  }

  private func checkCurrent() throws {
    lock.lock(); let stopped = cancelled; lock.unlock()
    if stopped { throw SystemProxyFailure.cancelled }
    if ProcessInfo.processInfo.systemUptime >= deadline { throw SystemProxyFailure.timeout }
  }

  func expand(_ entries: [[String: Any]], url: URL, depth: Int = 0) throws -> [String] {
    var routes: [String] = []
    _ = try appendRoutes(entries, url: url, depth: depth, routes: &routes)
    return routes
  }

  // CFNetwork candidates are ordered. Retain only the usable prefix before an
  // unsupported candidate; never skip it to expose a later DIRECT fallback.
  // Share the prefix through PAC expansion so a nested stop also stops its
  // parent list, rather than accidentally appending the parent's fallbacks.
  private func appendRoutes(_ entries: [[String: Any]], url: URL, depth: Int,
                            routes: inout [String]) throws -> Bool {
    guard depth <= 4, entries.count <= 32 else { throw SystemProxyFailure.invalid }
    for proxy in entries {
      try checkCurrent()
      let type = proxy[kCFProxyTypeKey as String] as? String
      if type == kCFProxyTypeAutoConfigurationURL as String ||
        type == kCFProxyTypeAutoConfigurationJavaScript as String {
        if try !appendRoutes(evaluatePAC(proxy, url: url), url: url,
          depth: depth + 1, routes: &routes) { return false }
      } else {
        do {
          routes.append(try Self.route(proxy))
        } catch SystemProxyFailure.unsupported {
          guard !routes.isEmpty else { throw SystemProxyFailure.unsupported }
          return false
        }
      }
      guard routes.count <= 32 else { throw SystemProxyFailure.invalid }
    }
    return true
  }

  static func route(_ proxy: [String: Any]) throws -> String {
    guard let type = proxy[kCFProxyTypeKey as String] as? String
    else { throw SystemProxyFailure.invalid }
    if type == kCFProxyTypeNone as String { return "DIRECT" }
    // kCFProxyTypeHTTPS denotes the HTTP CONNECT proxy for HTTPS destinations,
    // not a TLS transport to the proxy. Dart uses CONNECT for those URLs.
    guard type == kCFProxyTypeHTTP as String || type == kCFProxyTypeHTTPS as String
    else { throw SystemProxyFailure.unsupported }
    guard let host = proxy[kCFProxyHostNameKey as String] as? String,
      !host.isEmpty, host.utf8.count <= 1024,
      host.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters).union(CharacterSet(charactersIn: ";/@?#\\"))) == nil,
      let port = proxy[kCFProxyPortNumberKey as String] as? NSNumber,
      (1...65535).contains(port.intValue), port.doubleValue == Double(port.intValue)
    else { throw SystemProxyFailure.invalid }
    let endpoint = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    guard let parsed = URLComponents(string: "http://\(endpoint):\(port.intValue)"),
      parsed.host?.isEmpty == false, parsed.port == port.intValue,
      parsed.path.isEmpty, parsed.user == nil, parsed.password == nil,
      parsed.query == nil, parsed.fragment == nil
    else { throw SystemProxyFailure.invalid }
    return "PROXY \(endpoint):\(port.intValue)"
  }

  private func evaluatePAC(_ proxy: [String: Any], url: URL) throws -> [[String: Any]] {
    try checkCurrent()
    pacResult = nil
    var context = CFStreamClientContext(version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let callback: CFProxyAutoConfigurationResultCallback = { info, proxies, error in
      guard let info = info else { return }
      let lookup = Unmanaged<AppleSystemProxyLookup>.fromOpaque(info).takeUnretainedValue()
      if error == nil, let proxies = proxies, let entries = proxies as? [[String: Any]] {
        lookup.pacResult = .success(entries)
      } else { lookup.pacResult = .failure(.invalid) }
      CFRunLoopStop(CFRunLoopGetCurrent())
    }
    let source: CFRunLoopSource
    if proxy[kCFProxyTypeKey as String] as? String == kCFProxyTypeAutoConfigurationURL as String {
      guard let pacURL = proxy[kCFProxyAutoConfigurationURLKey as String] as? URL,
        let scheme = pacURL.scheme, ["http", "https", "file"].contains(scheme)
      else { throw SystemProxyFailure.invalid }
      source = CFNetworkExecuteProxyAutoConfigurationURL(pacURL as CFURL, url as CFURL, callback, &context)
    } else {
      guard let script = proxy[kCFProxyAutoConfigurationJavaScriptKey as String] as? String,
        script.utf8.count <= 1024 * 1024 else { throw SystemProxyFailure.invalid }
      source = CFNetworkExecuteProxyAutoConfigurationScript(script as CFString, url as CFURL, callback, &context)
    }
    let loop = CFRunLoopGetCurrent()!
    var wakeContext = CFRunLoopSourceContext(version: 0, info: nil, retain: nil,
      release: nil, copyDescription: nil, equal: nil, hash: nil, schedule: nil,
      cancel: nil, perform: { _ in CFRunLoopStop(CFRunLoopGetCurrent()) })
    guard let wake = CFRunLoopSourceCreate(nil, 0, &wakeContext) else {
      CFRunLoopSourceInvalidate(source)
      throw SystemProxyFailure.invalid
    }
    lock.lock()
    if cancelled {
      lock.unlock()
      CFRunLoopSourceInvalidate(source)
      CFRunLoopSourceInvalidate(wake)
      throw SystemProxyFailure.cancelled
    }
    runLoop = loop; pacSource = source; cancellationSource = wake
    CFRunLoopAddSource(loop, source, .defaultMode)
    CFRunLoopAddSource(loop, wake, .defaultMode)
    lock.unlock()
    defer {
      CFRunLoopSourceInvalidate(source)
      CFRunLoopSourceInvalidate(wake)
      CFRunLoopRemoveSource(loop, source, .defaultMode)
      CFRunLoopRemoveSource(loop, wake, .defaultMode)
      lock.lock()
      runLoop = nil; pacSource = nil; cancellationSource = nil
      lock.unlock()
    }
    CFRunLoopRunInMode(.defaultMode, max(0, deadline - ProcessInfo.processInfo.systemUptime), false)
    try checkCurrent()
    guard let value = pacResult else { throw SystemProxyFailure.timeout }
    return try value.get()
  }
}
