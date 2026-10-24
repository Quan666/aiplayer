import Flutter
import UIKit
import Darwin
import AVFoundation
import AVKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var deviceInfoChannel: FlutterMethodChannel?
  private var displayChannel: FlutterMethodChannel?
  private var discoveryChannel: FlutterMethodChannel?
  private var systemProxy: SystemProxyHandler?
  private let discovery = LocalServiceDiscovery()
  private let pictureInPicture = PlayerPictureInPicture()
  private var originalBrightness: CGFloat?
  private var displayObservers: [NSObjectProtocol] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Scene-based apps do not consistently use the application delegate's
    // background callbacks, so observe both application and scene transitions.
    for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
      displayObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          self?.restoreBrightness()
        }
      )
    }
    // Permission prompts may temporarily deactivate the scene. Keep discovery
    // alive through those prompts; only stop it when the app enters background.
    for name in [UIApplication.didEnterBackgroundNotification, UIScene.didEnterBackgroundNotification] {
      displayObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in self?.discovery.cancel()
        }
      )
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    systemProxy?.close()
    systemProxy = SystemProxyHandler(messenger: engineBridge.applicationRegistrar.messenger())
    ExternalVideoInbox.shared.bind(engineBridge.applicationRegistrar.messenger())
    pictureInPicture.bind(engineBridge.applicationRegistrar.messenger())
    let deviceInfo = FlutterMethodChannel(
      name: "app.aiplayer/device_info",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    deviceInfoChannel = deviceInfo
    deviceInfo.setMethodCallHandler { call, result in
      guard call.method == "getDeviceInfo" else { result(FlutterMethodNotImplemented); return }
      let device = UIDevice.current
      var systemInfo = utsname()
      uname(&systemInfo)
      let hardware = withUnsafePointer(to: &systemInfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
      }
      result(["name": device.name, "model": hardware, "platform": device.systemName])
    }
    let channel = FlutterMethodChannel(
      name: "app.aiplayer/display",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    displayChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      let handle = {
        guard let self = self else {
          result(nil)
          return
        }
        switch call.method {
        case "readBrightness":
          result(Double(UIScreen.main.brightness))
        case "setBrightness":
          if UIApplication.shared.applicationState == .active,
            let value = call.arguments as? NSNumber,
            value.doubleValue.isFinite
          {
            if self.originalBrightness == nil {
              self.originalBrightness = UIScreen.main.brightness
            }
            UIScreen.main.brightness = CGFloat(min(1, max(0, value.doubleValue)))
          }
          result(nil)
        case "restoreBrightness", "dispose":
          self.restoreBrightness()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      if Thread.isMainThread {
        handle()
      } else {
        DispatchQueue.main.async(execute: handle)
      }
    }
    let discoveryChannel = FlutterMethodChannel(
      name: "app.aiplayer/discovery",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    self.discoveryChannel = discoveryChannel
    discoveryChannel.setMethodCallHandler { [weak self] call, result in
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
  }

  override func application(
    _ app: UIApplication, open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if url.isFileURL || url.scheme == "https" || url.scheme == "http" {
      ExternalVideoInbox.shared.accept(url)
      return true
    }
    return super.application(app, open: url, options: options)
  }

  private func restoreBrightness() {
    guard let value = originalBrightness else { return }
    originalBrightness = nil
    UIScreen.main.brightness = value
  }

  deinit {
    systemProxy?.close()
    for observer in displayObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }
}


/// AVKit cannot display the mpv texture. For system-supported media only, a
/// temporary AVPlayer receives the current URI/time and returns its final
/// state to Dart. No remux, upload, or remote playback service is involved.
private final class PlayerPictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
  private var channel: FlutterMethodChannel?
  private var player: AVPlayer?
  private var controller: AVPictureInPictureController?
  private var host: PictureInPictureHost?
  private var statusObservation: NSKeyValueObservation?
  private var possibleObservation: NSKeyValueObservation?
  private var displayObservation: NSKeyValueObservation?
  private var timeObserver: Any?
  private var timeout: Timer?
  private var enterResult: FlutterResult?
  private var exitResults: [FlutterResult] = []
  private var requestID: Int64 = 0
  private var startPosition = 0.0, requestedRate: Float = 1
  private var requestedPlaying = false, prepared = false, seekCompleted = false, starting = false
  private var started = false, restoreInline = false

  func bind(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "app.aiplayer/window_mode", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async {
        guard let self = self else { result(nil); return }
        switch call.method {
        case "supported": result(AVPictureInPictureController.isPictureInPictureSupported())
        case "enter": self.enter(call.arguments as? [String: Any] ?? [:], result: result)
        case "exit": self.exit(call.arguments as? [String: Any] ?? [:], result: result)
        default: result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  private func enter(_ values: [String: Any], result: @escaping FlutterResult) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      result(FlutterError(code: "pip_unsupported", message: "此设备不支持系统画中画。", details: nil)); return
    }
    guard controller == nil, enterResult == nil else {
      result(FlutterError(code: "pip_busy", message: "系统画中画正在切换，请稍后重试。", details: nil)); return
    }
    guard let raw = values["uri"] as? String, let url = URL(string: raw),
      ["file", "http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.user == nil, url.password == nil,
      let identifier = values["requestId"] as? NSNumber,
      let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        .filter({ $0.activationState == .foregroundActive })
        .flatMap({ $0.windows }).first(where: { $0.isKeyWindow }),
      let root = window.rootViewController
    else {
      result(FlutterError(code: "pip_unavailable", message: "当前视频或播放界面尚未准备好。", details: nil)); return
    }
    do {
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(.playback, mode: .moviePlayback)
      try audio.setActive(true)
    } catch {
      result(FlutterError(code: "pip_audio", message: "系统音频会话不可用，请稍后重试。", details: nil)); return
    }

    requestID = identifier.int64Value
    let time = (values["position"] as? NSNumber)?.doubleValue ?? 0
    startPosition = time.isFinite ? max(0, time) : 0
    let speed = (values["rate"] as? NSNumber)?.floatValue ?? 1
    requestedRate = speed.isFinite ? min(4, max(0.25, speed)) : 1
    requestedPlaying = values["playing"] as? Bool ?? false
    prepared = false; seekCompleted = false; starting = false; started = false; restoreInline = false
    enterResult = result

    let item = AVPlayerItem(url: url)
    let player = AVPlayer(playerItem: item)
    let volume = (values["volume"] as? NSNumber)?.floatValue ?? 1
    player.volume = volume.isFinite ? min(1, max(0, volume)) : 1
    self.player = player
    let host = PictureInPictureHost(frame: root.view.bounds)
    host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    host.playerLayer.player = player
    host.cancel = { [weak self] in self?.fail("已取消系统小窗，应用内播放已恢复。", code: "pip_cancelled") }
    root.view.addSubview(host)
    self.host = host
    guard let controller = AVPictureInPictureController(playerLayer: host.playerLayer) else {
      fail("系统暂时无法创建画中画。", code: "pip_unavailable"); return
    }
    self.controller = controller
    controller.delegate = self
    if #available(iOS 14.2, *) {
      controller.canStartPictureInPictureAutomaticallyFromInline = false
    }
    let ticket = requestID
    timeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
      guard let self = self, self.requestID == ticket else { return }
      self.fail("系统小窗准备超时。此视频可能不受系统播放器支持，或网络读取超时。", code: "pip_timeout")
    }
    statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      DispatchQueue.main.async {
        guard let self = self, self.requestID == ticket, self.player?.currentItem === item else { return }
        if item.status == .failed {
          // AVFoundation descriptions can include credential-bearing URLs.
          self.fail("系统播放器无法打开此视频，请检查网络或视频格式。应用内播放已恢复。", code: "pip_media", status: (item.error as NSError?)?.code)
        } else if item.status == .readyToPlay && !self.prepared {
          self.prepared = true
          player.seek(to: CMTime(seconds: self.startPosition, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
              guard let self = self, self.requestID == ticket, self.player === player else { return }
              guard finished else { self.fail("系统播放器无法定位到当前播放位置。", code: "pip_seek"); return }
              self.seekCompleted = true
              if self.requestedPlaying { player.playImmediately(atRate: self.requestedRate) }
              self.tryStart()
            }
          }
        }
      }
    }
    possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
      DispatchQueue.main.async { [weak self] in self?.tryStart() }
    }
    displayObservation = host.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
      DispatchQueue.main.async { [weak self] in self?.tryStart() }
    }
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
      guard let self = self, self.requestID == ticket, self.started else { return }
      self.channel?.invokeMethod("progress", arguments: self.snapshot())
    }
  }

  private func tryStart() {
    guard prepared, seekCompleted, !starting, !started, enterResult != nil,
      host?.playerLayer.isReadyForDisplay == true,
      let controller = controller, controller.isPictureInPicturePossible else { return }
    starting = true
    controller.startPictureInPicture()
  }

  private func snapshot() -> [String: Any] {
    let time = player?.currentTime().seconds ?? startPosition
    let duration = player?.currentItem?.duration.seconds ?? 0
    let speed = player?.rate ?? requestedRate
    return [
      "requestId": requestID,
      "position": time.isFinite && time >= 0 ? time : startPosition,
      "duration": duration.isFinite && duration > 0 ? duration : 0,
      "playing": (player?.timeControlStatus ?? .paused) != .paused,
      "rate": speed > 0 ? speed : requestedRate,
    ]
  }

  private func exit(_ values: [String: Any], result: @escaping FlutterResult) {
    guard (values["requestId"] as? NSNumber)?.int64Value == requestID else { result(nil); return }
    guard let controller = controller else { result(nil); return }
    exitResults.append(result)
    restoreInline = true
    if controller.isPictureInPictureActive {
      timeout?.invalidate()
      let ticket = requestID
      timeout = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
        guard let self = self, self.requestID == ticket else { return }
        self.finish()
      }
      controller.stopPictureInPicture()
    } else {
      finish()
    }
  }

  private func fail(_ message: String, code: String, status: Int? = nil) {
    let error = FlutterError(code: code, message: message, details: status)
    finish(error: error)
  }

  private func finish(error: FlutterError? = nil) {
    guard controller != nil || enterResult != nil else { return }
    var state = snapshot()
    if !started {
      state["position"] = startPosition
      state["playing"] = requestedPlaying
      state["rate"] = requestedRate
    }
    if let error = error { state["error"] = error.message }
    if !restoreInline && started { state["playing"] = false }
    let callback = enterResult
    enterResult = nil
    let exits = exitResults
    exitResults.removeAll()
    let emitRestore = started
    timeout?.invalidate(); timeout = nil
    statusObservation?.invalidate(); statusObservation = nil
    possibleObservation?.invalidate(); possibleObservation = nil
    displayObservation?.invalidate(); displayObservation = nil
    if let observer = timeObserver { player?.removeTimeObserver(observer) }
    timeObserver = nil
    controller?.delegate = nil
    if starting || started || controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
    controller = nil
    player?.pause(); host?.playerLayer.player = nil; player = nil
    host?.removeFromSuperview(); host = nil
    prepared = false; seekCompleted = false; starting = false; started = false
    if let callback = callback {
      callback(error ?? FlutterError(code: "pip_cancelled", message: "系统画中画已取消。", details: nil))
    }
    if emitRestore { channel?.invokeMethod("restored", arguments: state) }
    for result in exits { result(state) }
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard pictureInPictureController === controller else { return }
    started = true
    timeout?.invalidate(); timeout = nil
    host?.isHidden = true
    let callback = enterResult; enterResult = nil
    callback?(true)
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    guard pictureInPictureController === controller else { return }
    fail("系统未允许进入画中画，请检查系统设置或稍后重试。", code: "pip_start", status: (error as NSError).code)
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    guard pictureInPictureController === controller else { completionHandler(false); return }
    // Flutter's player route remains mounted underneath the native handoff.
    restoreInline = true
    completionHandler(true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard pictureInPictureController === controller else { return }
    finish()
  }
}

private final class PictureInPictureHost: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
  var cancel: (() -> Void)?
  private let spinner = UIActivityIndicatorView(style: .large)
  private let closeButton = UIButton(type: .system)

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    playerLayer.videoGravity = .resizeAspect
    spinner.color = .white
    spinner.startAnimating()
    addSubview(spinner)
    closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
    closeButton.tintColor = .white
    closeButton.accessibilityLabel = "取消小窗"
    closeButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    addSubview(closeButton)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  override func layoutSubviews() {
    super.layoutSubviews()
    spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
    closeButton.frame = CGRect(x: safeAreaInsets.left + 12, y: safeAreaInsets.top + 8, width: 44, height: 44)
  }
  @objc private func cancelTapped() { cancel?() }
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
