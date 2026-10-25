import Cocoa
import FlutterMacOS
import Darwin

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var windowModeChannel: FlutterMethodChannel?
  private var floatingFrame: NSRect?
  private var originalLevel: NSWindow.Level = .normal
  private var originalCollectionBehavior: NSWindow.CollectionBehavior = []
  private var originalHidesOnDeactivate = false
  private var fileChannel: FlutterMethodChannel?
  private var discoveryChannel: FlutterMethodChannel?
  private var systemProxy: SystemProxyHandler?
  private let discovery = LocalServiceDiscovery()
  private var accessed: [URL] = []
  private var desktopPlayerChannel: FlutterMethodChannel?
  private var desktopReady = false
  private var closeRequested = false
  private var closeApproved = false
  private var fullscreenFrame: NSRect?
  private var fullscreenStyle: NSWindow.StyleMask = []
  private var fullscreenLevel: NSWindow.Level = .normal
  private var lastWindowState: [String: Bool]?
  private var dragMouseDown: NSEvent?
  private var nativeFullscreenTransition = false
  private var nativeFullscreenEntering = false
  private enum PendingWindowAction {
    case fullscreen(Bool)
    case floating(Double)
  }
  private var pendingWindowAction: PendingWindowAction?
  private var terminationCompletion: (() -> Void)?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // Keep hover delivery alive while AppKit changes the key window during
    // fullscreen transitions. Tracking still stops when another app is active.
    flutterViewController.mouseTrackingMode = .inActiveApp
    acceptsMouseMovedEvents = true
    self.contentViewController = flutterViewController
    configureImmersiveTitlebar()
    // Flutter draws through the title bar and reserves space for the native
    // traffic lights; there is no separate strip above the application.
    var contentSize = NSSize(width: 1280, height: 720)
    if let display = screen ?? NSScreen.main {
      let work = display.visibleFrame
      let outer = frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
      let scale = max(0, min(1,
        (work.width * 0.9 - (outer.width - contentSize.width)) / contentSize.width,
        (work.height * 0.9 - (outer.height - contentSize.height)) / contentSize.height))
      contentSize = NSSize(width: max(1, floor(contentSize.width * scale)),
                           height: max(1, floor(contentSize.height * scale)))
      setContentSize(contentSize)
      setFrameOrigin(NSPoint(x: work.midX - frame.width / 2,
                             y: work.midY - frame.height / 2))
    } else {
      setContentSize(contentSize)
    }
    self.title = "映库"

    RegisterGeneratedPlugins(registry: flutterViewController)
    systemProxy?.close()
    systemProxy = SystemProxyHandler(messenger: flutterViewController.engine.binaryMessenger)
    ExternalVideoInbox.shared.bind(flutterViewController.engine.binaryMessenger)
    delegate = self
    desktopPlayerChannel = FlutterMethodChannel(name: "app.aiplayer/desktop_player",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    desktopPlayerChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(false); return }
      if call.method == "getDeviceInfo" {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var hardware = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &hardware, &size, nil, 0)
        result(["name": Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                "platform": "macOS", "model": String(cString: hardware)])
        return
      }
      switch call.method {
      case "ready":
        self.desktopReady = true
        self.lastWindowState = self.desktopWindowState
        result(self.desktopWindowState)
      case "startDrag":
        if self.desktopWindowState["fullscreen"] != true,
           NSEvent.pressedMouseButtons & 1 != 0,
           let event = self.dragMouseDown {
          self.dragMouseDown = nil
          self.releaseFlutterMouseBeforeDrag(event)
          self.performDrag(with: event)
        }
        result(nil)
      case "minimize":
        self.miniaturize(nil)
        result(nil)
      case "toggleMaximize":
        self.performTitlebarDoubleClick()
        result(nil)
      case "requestClose":
        self.performClose(nil)
        result(nil)
      case "closeWindow":
        self.closeApproved = true
        result(nil)
        DispatchQueue.main.async {
          if let completion = self.terminationCompletion {
            self.terminationCompletion = nil
            completion()
          } else {
            self.close()
          }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
    windowModeChannel = FlutterMethodChannel(name: "app.aiplayer/window_mode",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    windowModeChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "supported": result(true)
      case "setVideoFullscreen":
        self.exitFloating()
        let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
        self.setVideoFullscreen(enabled)
        result(enabled && (self.nativeFullscreenTransition ||
          self.desktopWindowState["fullscreen"] == true))
      case "enter":
        let value = ((call.arguments as? [String: Any])?["aspectRatio"] as? NSNumber)?.doubleValue ?? 16.0 / 9
        self.enterFloating(aspectRatio: value)
        result(true)
      case "exit": self.exitFloating(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }


    discoveryChannel = FlutterMethodChannel(name: "app.aiplayer/discovery", binaryMessenger: flutterViewController.engine.binaryMessenger)
    discoveryChannel?.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async {
        guard let self = self else {
          result(nil)
          return
        }
        switch call.method {
        case "interfaces": result(LocalServiceDiscovery.interfaces())
        case "scan": self.discovery.scan(call.arguments as? [String: Any] ?? [:], result: result)
        case "cancel":
          self.discovery.cancel()
          result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
    }

    fileChannel = FlutterMethodChannel(name: "app.aiplayer/files", binaryMessenger: flutterViewController.engine.binaryMessenger)
    fileChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      self.handleFileCall(call, result: result)
    }

    super.awakeFromNib()
    restoreFlutterInput()
    initialFirstResponder = firstResponder as? NSView
  }

  func windowWillClose(_ notification: Notification) {
    pendingWindowAction = nil
    systemProxy?.close()
    systemProxy = nil
  }

  deinit { systemProxy?.close() }

  func configureImmersiveTitlebar() {
    styleMask.insert(.fullSizeContentView)
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    if #available(macOS 11.0, *) { titlebarSeparatorStyle = .none }
    // Leave AppKit's traffic lights, resize edges and titlebar gestures intact.
    // Background dragging outside the dedicated strip would steal player input.
    isMovableByWindowBackground = false
  }

  var desktopWindowState: [String: Bool] {
    ["fullscreen": fullscreenFrame != nil || nativeFullscreenEntering ||
       styleMask.contains(.fullScreen),
     "maximized": isZoomed]
  }

  private func publishWindowState() {
    guard desktopReady else { return }
    let state = desktopWindowState
    guard state != lastWindowState else { return }
    lastWindowState = state
    desktopPlayerChannel?.invokeMethod("windowStateChanged", arguments: state)
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown {
      dragMouseDown = event
    } else if event.type == .leftMouseUp {
      dragMouseDown = nil
    }
    super.sendEvent(event)
  }

  private func releaseFlutterMouseBeforeDrag(_ down: NSEvent) {
    // AppKit may consume the final mouse-up during performDrag. End Flutter's
    // gesture before handing off, or the next click can remain part of the old
    // drag. Deliver only to Flutter; the Window Server still gets the original
    // down event and the real button state for its native drag operation.
    guard let controller = contentViewController as? FlutterViewController,
          let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: mouseLocationOutsideOfEventStream,
            modifierFlags: down.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber, context: nil,
            eventNumber: down.eventNumber, clickCount: down.clickCount,
            pressure: 0) else { return }
    controller.mouseUp(with: up)
  }

  private func performTitlebarDoubleClick() {
    guard desktopWindowState["fullscreen"] != true else { return }
    // Match the system titlebar action in the additional Flutter drag area.
    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")?.lowercased() {
    case "minimize": miniaturize(nil)
    case "none": break
    default: zoom(nil)
    }
    publishWindowState()
  }

  func windowDidResize(_ notification: Notification) {
    publishWindowState()
  }

  func windowWillEnterFullScreen(_ notification: Notification) {
    nativeFullscreenTransition = true
    nativeFullscreenEntering = true
    publishWindowState()
  }

  func windowDidEnterFullScreen(_ notification: Notification) {
    nativeFullscreenTransition = false
    nativeFullscreenEntering = false
    publishWindowState()
    applyPendingWindowAction()
  }

  func windowWillExitFullScreen(_ notification: Notification) {
    nativeFullscreenTransition = true
  }

  func windowDidExitFullScreen(_ notification: Notification) {
    nativeFullscreenTransition = false
    nativeFullscreenEntering = false
    publishWindowState()
    restoreFlutterInput()
    applyPendingWindowAction()
  }

  func windowDidFailToEnterFullScreen(_ window: NSWindow) {
    nativeFullscreenTransition = false
    nativeFullscreenEntering = false
    publishWindowState()
    applyPendingWindowAction()
  }

  func windowDidFailToExitFullScreen(_ window: NSWindow) {
    nativeFullscreenTransition = false
    if case .floating? = pendingWindowAction {
      pendingWindowAction = nil
      windowModeChannel?.invokeMethod("changed", arguments: false)
    }
    publishWindowState()
    applyPendingWindowAction()
  }

  private func applyPendingWindowAction() {
    guard !nativeFullscreenTransition, !closeRequested,
          let action = pendingWindowAction else { return }
    pendingWindowAction = nil
    switch action {
    case .fullscreen(let enabled): setVideoFullscreen(enabled)
    case .floating(let ratio): enterFloating(aspectRatio: ratio)
    }
  }

  fileprivate func handleFileCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    var bookmarks = UserDefaults.standard.dictionary(forKey: "aiplayerBookmarks") as? [String: Data] ?? [:]
    do {
      if call.method == "remember", let path = call.arguments as? String {
        let url = URL(fileURLWithPath: path)
        bookmarks[path] = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmarks, forKey: "aiplayerBookmarks")
        result(nil)
      } else if call.method == "restore" {
        for (path, data) in bookmarks {
          var stale = false
          guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
          if !self.accessed.contains(url), url.startAccessingSecurityScopedResource() { self.accessed.append(url) }
          if stale { bookmarks[path] = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) }
        }
        UserDefaults.standard.set(bookmarks, forKey: "aiplayerBookmarks")
        result(nil)
      } else { result(FlutterMethodNotImplemented) }
    } catch { result(FlutterError(code: "file_access", message: "无法保存文件访问授权，请重新选择文件。", details: nil)) }
  }

  private func requestClose() {
    guard !closeRequested else { return }
    closeRequested = true
    pendingWindowAction = nil
    desktopPlayerChannel?.invokeMethod("closeRequested", arguments: nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if !desktopReady || closeApproved { return true }
    requestClose()
    return false
  }

  func prepareForTermination(_ completion: @escaping () -> Void) -> Bool {
    if !desktopReady || closeApproved { return false }
    terminationCompletion = completion
    requestClose()
    return true
  }

  func enterFloating(aspectRatio value: Double) {
    // AppKit must finish leaving its fullscreen Space before changing window
    // collection behavior or geometry. Continue from the delegate event.
    if nativeFullscreenTransition || styleMask.contains(.fullScreen) {
      pendingWindowAction = .floating(value)
      if !nativeFullscreenTransition { toggleFullScreen(nil) }
      return
    }
    setVideoFullscreen(false)
    let ratio = value.isFinite ? min(2.39, max(0.42, value)) : 16.0 / 9
    if floatingFrame == nil {
      floatingFrame = frame
      originalLevel = level
      originalCollectionBehavior = collectionBehavior
      originalHidesOnDeactivate = hidesOnDeactivate
    }
    // The same Flutter view keeps playing while this window follows the user
    // between desktops and full-screen Spaces. These flags must replace their
    // mutually exclusive primary-window counterparts, rather than be appended.
    var behavior = originalCollectionBehavior
    behavior.subtract([.moveToActiveSpace, .fullScreenPrimary,
                       .fullScreenNone, .fullScreenAllowsTiling])
    behavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary,
                        .fullScreenDisallowsTiling])
    collectionBehavior = behavior
    hidesOnDeactivate = false
    level = .floating
    let height = min(540.0, 480.0 / ratio)
    setContentSize(NSSize(width: height * ratio, height: height))
  }

  func exitFloating() {
    if case .floating? = pendingWindowAction { pendingWindowAction = nil }
    guard let saved = floatingFrame else { return }
    floatingFrame = nil
    collectionBehavior = originalCollectionBehavior
    hidesOnDeactivate = originalHidesOnDeactivate
    level = originalLevel
    setFrame(saved, display: true)
  }

  func setVideoFullscreen(_ enabled: Bool) {
    // Do not replace AppKit's fullscreen style with a second borderless mode.
    // AppKit transitions cannot be interrupted: keep only the latest intent
    // and apply it from the completion event, never a timer or frame callback.
    if nativeFullscreenTransition {
      pendingWindowAction = .fullscreen(enabled)
      return
    }
    if styleMask.contains(.fullScreen) {
      if !enabled { toggleFullScreen(nil) }
      return
    }
    guard enabled != (fullscreenFrame != nil) else { return }
    let responder = firstResponder
    if enabled {
      guard let display = screen ?? NSScreen.main else { return }
      fullscreenFrame = frame
      fullscreenStyle = styleMask
      fullscreenLevel = level
      styleMask = [.borderless, .resizable]
      level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
      setFrame(display.frame, display: true)
    } else if let saved = fullscreenFrame {
      fullscreenFrame = nil
      styleMask = fullscreenStyle
      level = fullscreenLevel
      setFrame(saved, display: true)
    }
    makeKeyAndOrderFront(nil)
    restoreFlutterInput(preferredResponder: responder)
    publishWindowState()
  }

  func restoreFlutterInput(preferredResponder: NSResponder? = nil) {
    acceptsMouseMovedEvents = true
    // AppKit can reset the first responder when the window's style changes.
    // Preserve attached editors and other valid responders before recovering
    // the Flutter view; makeKeyAndOrderFront alone does not restore its focus.
    for candidate in [preferredResponder, firstResponder] {
      guard let candidate = candidate, candidate.acceptsFirstResponder else { continue }
      let attached: Bool
      if let view = candidate as? NSView {
        attached = view.window === self
      } else {
        attached = candidate === contentViewController
      }
      if attached && (firstResponder === candidate ||
          (makeFirstResponder(candidate) && firstResponder === candidate)) {
        return
      }
    }

    guard let controller = contentViewController else { return }
    func acceptingView(in view: NSView) -> NSView? {
      guard !view.isHiddenOrHasHiddenAncestor else { return nil }
      if view.acceptsFirstResponder { return view }
      for child in view.subviews {
        if let candidate = acceptingView(in: child) { return candidate }
      }
      return nil
    }
    // Current Flutter versions wrap FlutterView in a non-focusable NSView.
    // Select the accepting child rather than making that wrapper first responder.
    if let view = acceptingView(in: controller.view), makeFirstResponder(view),
       firstResponder === view {
      return
    }
    if controller.acceptsFirstResponder { makeFirstResponder(controller) }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  func windowDidResignKey(_ notification: Notification) {
    if fullscreenFrame != nil { level = .normal }
  }

  func windowDidBecomeKey(_ notification: Notification) {
    if fullscreenFrame != nil {
      level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    }
    restoreFlutterInput()
  }
}

// Kept local to each Runner so neither target needs an extra project-file entry.
private final class LocalServiceDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  private var browsers: [NetServiceBrowser] = []
  private var services: [String: NetService] = [:]
  private var records: [String: [String: Any]] = [:]
  private var completion: FlutterResult?
  private var timer: Timer?

  func scan(_ arguments: [String: Any], result: @escaping FlutterResult) {
    cancel()
    let allowed = ["_smb._tcp", "_webdav._tcp", "_webdavs._tcp"]
    let requested = arguments["types"] as? [String] ?? allowed
    let types = Set(requested.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
      .filter { allowed.contains($0) }
    guard !types.isEmpty else {
      result([])
      return
    }
    completion = result
    let milliseconds = (arguments["timeoutMs"] as? NSNumber)?.doubleValue ?? 6000
    let seconds = milliseconds.isFinite ? min(15, max(0.5, milliseconds / 1000)) : 6
    timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      self?.finish()
    }
    for type in types {
      let browser = NetServiceBrowser()
      browser.delegate = self
      browser.includesPeerToPeer = false
      browsers.append(browser)
      browser.searchForServices(ofType: type + ".", inDomain: "local.")
    }
  }

  func cancel() {
    finish()
  }

  private func finish(_ error: FlutterError? = nil) {
    let callback = completion
    completion = nil
    timer?.invalidate()
    timer = nil
    for browser in browsers {
      browser.delegate = nil
      browser.stop()
    }
    for service in services.values {
      service.delegate = nil
      service.stop()
    }
    browsers.removeAll()
    services.removeAll()
    let value = records.values.sorted {
      ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "")
    }
    records.removeAll()
    if let error = error { callback?(error) } else { callback?(value) }
  }

  private func key(_ service: NetService) -> String {
    "\(service.type)|\(service.domain)|\(service.name)"
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    guard completion != nil, browsers.contains(where: { $0 === browser }) else { return }
    let id = key(service)
    guard services[id] == nil else { return }
    services[id] = service
    service.delegate = self
    service.resolve(withTimeout: 5)
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
    guard browsers.contains(where: { $0 === browser }) else { return }
    let id = key(service)
    if let existing = services.removeValue(forKey: id) {
      existing.delegate = nil
      existing.stop()
    }
    records.removeValue(forKey: id)
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
    guard browsers.contains(where: { $0 === browser }) else { return }
    finish(discoveryError(errorDict))
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard completion != nil, services[key(sender)] === sender, sender.port > 0,
      sender.port <= 65535
    else { return }
    let type = sender.type.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let kind: String
    switch type {
    case "_smb._tcp": kind = "smb"
    case "_webdav._tcp": kind = "webdav"
    case "_webdavs._tcp": kind = "webdavs"
    default: return
    }
    let host = Self.ipv4Address(sender.addresses ?? [])
      ?? sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard let host = host, !host.isEmpty else { return }
    var path = "/"
    if let data = sender.txtRecordData(),
      let rawPath = NetService.dictionary(fromTXTRecord: data)["path"],
      let text = String(data: rawPath, encoding: .utf8),
      text.hasPrefix("/"), text.utf8.count <= 2048,
      !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    {
      path = text
    }
    records[key(sender)] = [
      "kind": kind, "name": sender.name, "host": host, "port": sender.port, "path": path
    ]
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    guard services[key(sender)] === sender else { return }
    let code = errorDict[NetService.errorCode]?.intValue ?? 0
    if code == -65570 || code == -65571 || code == -72008 {
      finish(discoveryError(errorDict))
    }
  }

  private func discoveryError(_ dictionary: [String: NSNumber]) -> FlutterError {
    let code = dictionary[NetService.errorCode]?.intValue ?? 0
    if code == -65570 || code == -65571 {
      return FlutterError(code: "permission_denied", message: "请在系统设置中允许访问本地网络。", details: nil)
    }
    if code == -72008 {
      return FlutterError(code: "discovery_configuration", message: "应用缺少本地服务发现配置。", details: nil)
    }
    return FlutterError(code: "discovery_failed", message: "本地网络服务发现暂不可用。", details: nil)
  }

  private static func ipv4Address(_ addresses: [Data]) -> String? {
    for data in addresses {
      let host: String? = data.withUnsafeBytes { raw in
        guard data.count >= MemoryLayout<sockaddr_in>.size, let base = raw.baseAddress else { return nil }
        let address = base.assumingMemoryBound(to: sockaddr.self)
        guard Int32(address.pointee.sa_family) == AF_INET else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size),
          &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        return String(cString: buffer)
      }
      if let host = host { return host }
    }
    return nil
  }

  static func interfaces() -> [[String: Any]] {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0, let first = first else { return [] }
    defer { freeifaddrs(first) }
    var results: [[String: Any]] = []
    var seen = Set<String>()
    var current: UnsafeMutablePointer<ifaddrs>? = first
    while let pointer = current {
      let item = pointer.pointee
      current = item.ifa_next
      guard let address = item.ifa_addr, let mask = item.ifa_netmask,
        Int32(address.pointee.sa_family) == AF_INET,
        Int32(mask.pointee.sa_family) == AF_INET,
        item.ifa_flags & UInt32(IFF_UP) != 0,
        item.ifa_flags & UInt32(IFF_RUNNING) != 0,
        item.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0
      else { continue }
      let name = String(cString: item.ifa_name)
      guard !["utun", "tun", "ppp", "ipsec", "awdl", "llw"].contains(where: { name.hasPrefix($0) })
      else { continue }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size),
        &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
      else { continue }
      let host = String(cString: buffer)
      let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
      }
      let prefix = bits.nonzeroBitCount
      let expected: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
      guard bits == expected, seen.insert(host).inserted else { continue }
      results.append(["address": host, "prefixLength": prefix])
    }
    return results
  }
}


