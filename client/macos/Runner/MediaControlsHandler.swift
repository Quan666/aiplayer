import Foundation
import MediaPlayer
import AVFoundation
#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif

/// One event-driven Now Playing owner for both Apple runners. All mutable
/// state and Flutter channel delivery stay on the platform main queue.
final class MediaControlsHandler {
  private let channel: FlutterMethodChannel
  private var sessionID: Int64?
  private var latestSessionID: Int64 = 0
  private var clearedThroughSessionID: Int64 = 0
  private var closed = false
  private var values: [String: Any] = [:]
  private var targets: [(MPRemoteCommand, Any)] = []
  private var commandRevision = 0
  private var audioObservers: [NSObjectProtocol] = []
  private var playerObservations: [NSKeyValueObservation] = []
  private var jumpObserver: NSObjectProtocol?
  private weak var nativePlayer: AVPlayer?
  private var nativeSessionID: Int64?
  private var nativeCommand: ((String, Double?) -> Bool)?
  private var pendingNativeIntent: Bool?
  private var nativeTransferPreparing = false

  var seekStepSeconds: Double {
    let value = (values["seekStepSeconds"] as? NSNumber)?.doubleValue ?? 10
    return value.isFinite && value > 0 ? value : 10
  }

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "app.aiplayer/media_controls", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      let handle = {
        guard let self = self else { result(nil); return }
        let arguments = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "update": self.update(arguments); result(nil)
        case "clear":
          if let identifier = (arguments["sessionId"] as? NSNumber)?.int64Value,
            identifier > 0 {
            self.latestSessionID = max(self.latestSessionID, identifier)
            self.clearedThroughSessionID = max(self.clearedThroughSessionID, identifier)
            if let current = self.sessionID, current <= identifier { self.clear() }
          }
          result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
      if Thread.isMainThread { handle() } else { DispatchQueue.main.async(execute: handle) }
    }
  }

  private func update(_ state: [String: Any]) {
    guard !closed, let identifier = (state["sessionId"] as? NSNumber)?.int64Value,
      identifier > clearedThroughSessionID, identifier >= latestSessionID else { return }
    if identifier > latestSessionID {
      latestSessionID = identifier
      clear()
    }
    guard state["active"] as? Bool == true else {
      if identifier == sessionID { clear() }
      return
    }
    let previousPip = values["nativePip"] as? Bool == true
    let previousPauseRevision = (values["pauseRevision"] as? NSNumber)?.int64Value ?? 0
    if identifier != sessionID {
      clear()
      sessionID = identifier
    }
    values = state
    let pip = state["nativePip"] as? Bool == true
    let pauseRevision = (state["pauseRevision"] as? NSNumber)?.int64Value ?? 0
    if pip != previousPip {
      nativeTransferPreparing = pip
      pendingNativeIntent = nil
    }
    if pauseRevision != previousPauseRevision { pendingNativeIntent = nil }
    if targets.isEmpty || pip != previousPip || pauseRevision != previousPauseRevision {
      refreshCommands()
    }
    updateNavigationCommands()
    publish()
  }

  private func updateNavigationCommands() {
    let pip = values["nativePip"] as? Bool == true
    let commands = MPRemoteCommandCenter.shared()
    commands.skipForwardCommand.preferredIntervals = [NSNumber(value: seekStepSeconds)]
    commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: seekStepSeconds)]
    commands.nextTrackCommand.isEnabled = !pip && values["canGoNext"] as? Bool == true
    commands.previousTrackCommand.isEnabled = !pip && values["canGoPrevious"] as? Bool == true
  }

  private func removeCommands() {
    commandRevision += 1
    for (command, target) in targets {
      command.removeTarget(target)
      command.isEnabled = false
    }
    targets.removeAll()
    for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
    audioObservers.removeAll()
  }

  private func refreshCommands() {
    removeCommands()
    guard let identifier = sessionID, !closed else { return }
    registerCommands(identifier)
    observeAudioChanges(identifier)
    updateNavigationCommands()
  }

  private func registerCommands(_ identifier: Int64) {
    let commands = MPRemoteCommandCenter.shared()
    add(commands.playCommand, "play", identifier)
    add(commands.pauseCommand, "pause", identifier)
    add(commands.togglePlayPauseCommand, "toggle", identifier)
    add(commands.stopCommand, "stop", identifier)
    add(commands.nextTrackCommand, "next", identifier)
    add(commands.previousTrackCommand, "previous", identifier)
    commands.skipForwardCommand.preferredIntervals = [10]
    commands.skipBackwardCommand.preferredIntervals = [10]
    add(commands.skipForwardCommand, "seekForward", identifier)
    add(commands.skipBackwardCommand, "seekBackward", identifier)
    add(commands.changePlaybackPositionCommand, "seek", identifier)
  }

  private func add(_ command: MPRemoteCommand, _ action: String, _ identifier: Int64) {
    command.isEnabled = true
    let revision = commandRevision
    let pauseRevision = (values["pauseRevision"] as? NSNumber)?.int64Value ?? 0
    let target = command.addTarget { [weak self] event in
      let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
      // The target captures its session when registered, not when this block
      // eventually reaches the main queue after a track change or disposal.
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.commandRevision == revision else { return }
        self.send(action, position: position, identifier: identifier, pauseRevision: pauseRevision)
      }
      return .success
    }
    targets.append((command, target))
  }

  private func send(_ action: String, position: Double? = nil, identifier: Int64, pauseRevision: Int64) {
    guard !closed, sessionID == identifier,
      pauseRevision == ((values["pauseRevision"] as? NSNumber)?.int64Value ?? 0) else { return }
    if action == "next" && values["canGoNext"] as? Bool != true { return }
    if action == "previous" && values["canGoPrevious"] as? Bool != true { return }
    if values["nativePip"] as? Bool == true {
      guard nativeSessionID == identifier, nativePlayer != nil else {
        guard nativeTransferPreparing else { return }
        // A button can arrive while Dart is handing the source to AVKit.
        // Keep only the latest play intent until the native player attaches.
        switch action {
        case "play": pendingNativeIntent = true
        case "pause", "stop": pendingNativeIntent = false
        case "toggle": pendingNativeIntent = !(pendingNativeIntent ?? (values["playing"] as? Bool == true))
        default: break
        }
        return
      }
      _ = nativeCommand?(action, position)
      publish()
      return
    }
    var arguments: [String: Any] = [
      "sessionId": identifier, "action": action, "pauseRevision": pauseRevision,
    ]
    if let position = position {
      guard position.isFinite, position >= 0, position < Double(Int64.max) / 1000 else { return }
      arguments["positionMs"] = Int64(position * 1000)
    }
    channel.invokeMethod("command", arguments: arguments)
  }

  private func observeAudioChanges(_ identifier: Int64) {
    #if os(iOS)
    let revision = commandRevision
    let pauseRevision = (values["pauseRevision"] as? NSNumber)?.int64Value ?? 0
    audioObservers.append(NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let self = self, self.commandRevision == revision,
        let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue,
        reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
      self.send("pause", identifier: identifier, pauseRevision: pauseRevision)
    })
    audioObservers.append(NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let self = self, self.commandRevision == revision,
        let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
        type == AVAudioSession.InterruptionType.began.rawValue else { return }
      // An interruption ending is not a user request to resume playback.
      self.send("pause", identifier: identifier, pauseRevision: pauseRevision)
    })
    #endif
  }

  /// PiP owns a temporary AVPlayer rather than the mpv texture. Its commands
  /// must update the native preparation intent as well as the ready player.
  func attachNativePlayer(_ player: AVPlayer, command: @escaping (String, Double?) -> Bool) {
    let pending = pendingNativeIntent
    detachNativePlayer()
    guard !closed, let identifier = sessionID else { return }
    nativePlayer = player
    nativeSessionID = identifier
    nativeCommand = command
    let changed = { [weak self, weak player] in
      DispatchQueue.main.async { [weak self, weak player] in
        guard let self = self, let player = player, self.nativePlayer === player,
          self.sessionID == identifier else { return }
        self.publish()
      }
    }
    playerObservations = [
      player.observe(\.rate, options: [.new]) { _, _ in changed() },
      player.observe(\.timeControlStatus, options: [.new]) { _, _ in changed() },
    ]
    if let item = player.currentItem {
      playerObservations.append(item.observe(\.duration, options: [.new]) { _, _ in changed() })
      jumpObserver = NotificationCenter.default.addObserver(
        forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main
      ) { _ in changed() }
    }
    if let playing = pending {
      _ = command(playing ? "play" : "pause", nil)
    }
    publish()
  }

  func detachNativePlayer() {
    let attached = nativePlayer != nil
    for observation in playerObservations { observation.invalidate() }
    playerObservations.removeAll()
    if let observer = jumpObserver { NotificationCenter.default.removeObserver(observer) }
    jumpObserver = nil
    nativePlayer = nil
    nativeSessionID = nil
    nativeCommand = nil
    pendingNativeIntent = nil
    nativeTransferPreparing = false
    // Invalidate commands queued for the outgoing AVPlayer before an immediate
    // second PiP attempt can attach another player with the same media ID.
    if attached && sessionID != nil { refreshCommands() }
    publish()
  }

  private func publish() {
    guard sessionID != nil else { return }
    var position = max(0, (values["positionMs"] as? NSNumber)?.doubleValue ?? 0) / 1000
    var duration = max(0, (values["durationMs"] as? NSNumber)?.doubleValue ?? 0) / 1000
    var speed = (values["speed"] as? NSNumber)?.doubleValue ?? 1
    var playing = values["playing"] as? Bool == true && values["buffering"] as? Bool != true
    if values["nativePip"] as? Bool == true {
      playing = false
      if let player = nativePlayer, nativeSessionID == sessionID {
        let time = player.currentTime().seconds
        let length = player.currentItem?.duration.seconds ?? 0
        if time.isFinite { position = max(0, time) }
        if length.isFinite { duration = max(0, length) }
        playing = player.timeControlStatus == .playing
        if player.rate > 0 { speed = Double(player.rate) }
      }
    }
    if !speed.isFinite || speed <= 0 { speed = 1 }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: values["title"] as? String ?? "",
      MPMediaItemPropertyPlaybackDuration: duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : 0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
    ]
    #if os(macOS)
    MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    #endif
  }

  private func clear() {
    let owned = sessionID != nil
    sessionID = nil
    values.removeAll()
    pendingNativeIntent = nil
    detachNativePlayer()
    removeCommands()
    if owned {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      #if os(macOS)
      MPNowPlayingInfoCenter.default().playbackState = .stopped
      #endif
    }
  }

  func close() {
    closed = true
    channel.setMethodCallHandler(nil)
    clear()
  }

  deinit { clear() }
}
