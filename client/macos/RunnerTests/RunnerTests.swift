import Cocoa
import CFNetwork
import FlutterMacOS
import XCTest
@testable import aiplayer

@MainActor
class RunnerTests: XCTestCase {
  func testSystemProxyUsesHTTPAndHTTPSConfiguration() async throws {
    let routes = try await Task.detached {
      let settings: [String: Any] = [
        kCFNetworkProxiesHTTPEnable as String: 1,
        kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
        kCFNetworkProxiesHTTPPort as String: 7890,
        kCFNetworkProxiesHTTPSEnable as String: 1,
        kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
        kCFNetworkProxiesHTTPSPort as String: 7891,
      ]
      return try ["http://example.com/video", "https://example.com/video"].map {
        try AppleSystemProxyLookup(url: $0).resolve(settings: settings as CFDictionary)
      }
    }.value
    XCTAssertEqual(routes, ["PROXY 127.0.0.1:7890", "PROXY 127.0.0.1:7891"])
  }

  func testSystemProxyUsesHTTPWhenHTTPHTTPSAndSOCKSAreAllEnabled() async throws {
    // Typical desktop proxy tools enable all three system proxy settings.
    // Exercise CFNetwork's real selection, rather than constructing its output.
    let routes = try await Task.detached {
      let settings: [String: Any] = [
        kCFNetworkProxiesHTTPEnable as String: 1,
        kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
        kCFNetworkProxiesHTTPPort as String: 7890,
        kCFNetworkProxiesHTTPSEnable as String: 1,
        kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
        kCFNetworkProxiesHTTPSPort as String: 7891,
        kCFNetworkProxiesSOCKSEnable as String: 1,
        kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
        kCFNetworkProxiesSOCKSPort as String: 7892,
      ]
      return try ["http://example.com/video", "https://example.com/video"].map {
        try AppleSystemProxyLookup(url: $0).resolve(settings: settings as CFDictionary)
      }
    }.value
    XCTAssertEqual(routes, ["PROXY 127.0.0.1:7890", "PROXY 127.0.0.1:7891"])
  }

  func testSystemProxyAppliesBypassAndDirectSettings() async throws {
    let routes = try await Task.detached {
      let settings: [String: Any] = [
        kCFNetworkProxiesHTTPEnable as String: 1,
        kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
        kCFNetworkProxiesHTTPPort as String: 7890,
        kCFNetworkProxiesExceptionsList as String: ["*.internal"],
        kCFNetworkProxiesExcludeSimpleHostnames as String: 1,
      ]
      var values = try ["http://nas.internal/video", "http://nas/video"].map {
        try AppleSystemProxyLookup(url: $0).resolve(settings: settings as CFDictionary)
      }
      values.append(try AppleSystemProxyLookup(url: "https://example.com")
        .resolve(settings: [:] as CFDictionary))
      return values
    }.value
    XCTAssertEqual(routes, ["DIRECT", "DIRECT", "DIRECT"])
  }

  func testSystemProxyEvaluatesPACForEachFullURL() async throws {
    let routes = try await Task.detached {
      let settings: [String: Any] = [
        kCFNetworkProxiesProxyAutoConfigEnable as String: 1,
        kCFNetworkProxiesProxyAutoConfigJavaScript as String:
          "function FindProxyForURL(url, host) { return url.indexOf('/private') >= 0 ? " +
          "'DIRECT' : 'PROXY 127.0.0.1:7890; DIRECT'; }",
      ]
      return try ["http://example.com/public", "http://example.com/private"].map {
        try AppleSystemProxyLookup(url: $0).resolve(settings: settings as CFDictionary)
      }
    }.value
    XCTAssertEqual(routes, ["PROXY 127.0.0.1:7890; DIRECT", "DIRECT"])
  }

  func testSystemProxyRejectsSOCKSInsteadOfConnectingDirectly() {
    XCTAssertThrowsError(try AppleSystemProxyLookup.route([
      kCFProxyTypeKey as String: kCFProxyTypeSOCKS,
      kCFProxyHostNameKey as String: "127.0.0.1",
      kCFProxyPortNumberKey as String: 7890,
    ]))
  }

  func testSystemProxyStopsSupportedPrefixBeforeSOCKSWithoutDirectFallback() async throws {
    let routes = try await Task.detached {
      let url = URL(string: "https://example.com/video")!
      let http: [String: Any] = [
        kCFProxyTypeKey as String: kCFProxyTypeHTTP,
        kCFProxyHostNameKey as String: "127.0.0.1",
        kCFProxyPortNumberKey as String: 7890,
      ]
      let socks: [String: Any] = [
        kCFProxyTypeKey as String: kCFProxyTypeSOCKS,
        kCFProxyHostNameKey as String: "127.0.0.1",
        kCFProxyPortNumberKey as String: 7892,
      ]
      let direct: [String: Any] = [kCFProxyTypeKey as String: kCFProxyTypeNone]
      let lookup = AppleSystemProxyLookup(url: url.absoluteString)
      let prefix = try lookup.expand([http, socks, direct], url: url)
      XCTAssertThrowsError(try lookup.expand([socks, http, direct], url: url))
      // A malformed supported candidate is an error, even after a valid one.
      let malformed: [String: Any] = [kCFProxyTypeKey as String: kCFProxyTypeHTTP]
      XCTAssertThrowsError(try lookup.expand([http, malformed, direct], url: url))
      XCTAssertThrowsError(try lookup.expand([http, [:], direct], url: url))
      return prefix
    }.value
    XCTAssertEqual(routes, ["PROXY 127.0.0.1:7890"])
  }

  func testSystemProxyPreservesIPv6AndRejectsMalformedEndpoints() throws {
    XCTAssertEqual(try AppleSystemProxyLookup.route([
      kCFProxyTypeKey as String: kCFProxyTypeHTTP,
      kCFProxyHostNameKey as String: "::1",
      kCFProxyPortNumberKey as String: 7890,
    ]), "PROXY [::1]:7890")
    for host in ["127.0.0.1; DIRECT", "user@127.0.0.1", "127.0.0.1/path"] {
      XCTAssertThrowsError(try AppleSystemProxyLookup.route([
        kCFProxyTypeKey as String: kCFProxyTypeHTTP,
        kCFProxyHostNameKey as String: host,
        kCFProxyPortNumberKey as String: 7890,
      ]))
    }
  }

  func testSystemProxyCancellationAndExpiredDeadlineStopBeforeLookup() async {
    let cancelled = await Task.detached {
      let lookup = AppleSystemProxyLookup(url: "https://example.com")
      lookup.cancel()
      return (try? lookup.resolve(settings: [:] as CFDictionary)) == nil
    }.value
    let expired = await Task.detached {
      let lookup = AppleSystemProxyLookup(url: "https://example.com", timeout: 0)
      return (try? lookup.resolve(settings: [:] as CFDictionary)) == nil
    }.value
    XCTAssertTrue(cancelled)
    XCTAssertTrue(expired)
  }

  private func makeWindow() -> (MainFlutterWindow, InputView) {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 100, y: 100, width: 640, height: 360),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let controller = NSViewController()
    controller.view = NSView(frame: window.contentView!.bounds)
    let input = InputView(frame: controller.view.bounds)
    controller.view.addSubview(input)
    window.contentViewController = controller
    return (window, input)
  }

  func testKeyWindowRecoversInputThroughNonFocusableWrapper() {
    let (window, input) = makeWindow()
    defer { window.close() }
    XCTAssertTrue(window.makeFirstResponder(nil))
    window.acceptsMouseMovedEvents = false

    window.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))

    XCTAssertTrue(window.firstResponder === input)
    XCTAssertTrue(window.acceptsMouseMovedEvents)
  }

  func testRecoveryPreservesAttachedTextEditor() {
    let (window, _) = makeWindow()
    defer { window.close() }
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
    window.contentView!.addSubview(editor)
    XCTAssertTrue(window.makeFirstResponder(editor))

    window.restoreFlutterInput()

    XCTAssertTrue(window.firstResponder === editor)
  }

  func testRecoveryIgnoresDetachedPreferredResponder() {
    let (window, input) = makeWindow()
    defer { window.close() }
    XCTAssertTrue(window.makeFirstResponder(nil))
    let detached = InputView(frame: .zero)

    window.restoreFlutterInput(preferredResponder: detached)

    XCTAssertTrue(window.firstResponder === input)
  }

  func testFullscreenRestoresInputAndWindowFrame() throws {
    guard NSScreen.main != nil else { throw XCTSkip("Fullscreen needs a display") }
    let (window, input) = makeWindow()
    defer { window.close() }
    let originalFrame = window.frame
    let originalStyle = window.styleMask
    XCTAssertTrue(window.makeFirstResponder(input))

    window.setVideoFullscreen(true)
    XCTAssertFalse(window.styleMask.contains(.titled))
    XCTAssertTrue(window.firstResponder === input)

    // Recovery also works if AppKit leaves the window itself as first responder.
    XCTAssertTrue(window.makeFirstResponder(nil))
    window.setVideoFullscreen(false)
    XCTAssertEqual(window.styleMask, originalStyle)
    XCTAssertEqual(window.frame, originalFrame)
    XCTAssertTrue(window.firstResponder === input)
  }

  func testApplicationTracksHoverWhileItsWindowChangesFocus() throws {
    let window = try XCTUnwrap(NSApp.windows.compactMap { $0 as? MainFlutterWindow }
      .first { $0.contentViewController is FlutterViewController })
    let controller = try XCTUnwrap(window.contentViewController as? FlutterViewController)

    XCTAssertTrue(window.acceptsMouseMovedEvents)
    XCTAssertEqual(controller.mouseTrackingMode, .inActiveApp)
  }

  func testFloatingWindowFollowsSpacesWithoutLosingItsOriginalWindowState() {
    let (window, input) = makeWindow()
    defer { window.close() }
    window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary,
                                 .fullScreenAllowsTiling]
    window.hidesOnDeactivate = true
    let originalFrame = window.frame
    let originalBehavior = window.collectionBehavior
    let originalLevel = window.level
    let originalController = window.contentViewController
    XCTAssertTrue(window.makeFirstResponder(input))

    window.enterFloating(aspectRatio: 16.0 / 9)
    XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
    XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
    XCTAssertFalse(window.collectionBehavior.contains(.moveToActiveSpace))
    XCTAssertFalse(window.collectionBehavior.contains(.fullScreenPrimary))
    XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAllowsTiling))
    XCTAssertFalse(window.hidesOnDeactivate)
    XCTAssertEqual(window.level, .floating)

    // Clicking another app must not lower or hide the floating player.
    window.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
    XCTAssertEqual(window.level, .floating)
    XCTAssertFalse(window.hidesOnDeactivate)
    // Repeated entries resize the same view and retain the initial snapshot.
    window.enterFloating(aspectRatio: 4.0 / 3)
    XCTAssertTrue(window.contentViewController === originalController)
    XCTAssertTrue(window.firstResponder === input)
    window.exitFloating()
    window.exitFloating()
    XCTAssertEqual(window.frame, originalFrame)
    XCTAssertEqual(window.level, originalLevel)
    XCTAssertEqual(window.collectionBehavior, originalBehavior)
    XCTAssertTrue(window.hidesOnDeactivate)
  }

  func testFloatingFromFullscreenRestoresTheOriginalRegularWindow() throws {
    guard NSScreen.main != nil else { throw XCTSkip("Fullscreen needs a display") }
    let (window, input) = makeWindow()
    defer { window.close() }
    let originalFrame = window.frame
    let originalStyle = window.styleMask
    let originalBehavior = window.collectionBehavior
    XCTAssertTrue(window.makeFirstResponder(input))

    window.setVideoFullscreen(true)
    window.enterFloating(aspectRatio: 16.0 / 9)
    XCTAssertEqual(window.styleMask, originalStyle)
    XCTAssertEqual(window.level, .floating)
    XCTAssertTrue(window.firstResponder === input)
    window.exitFloating()
    XCTAssertEqual(window.frame, originalFrame)
    XCTAssertEqual(window.styleMask, originalStyle)
    XCTAssertEqual(window.collectionBehavior, originalBehavior)
    XCTAssertEqual(window.level, .normal)
  }
}

private final class InputView: NSView {
  override var acceptsFirstResponder: Bool { true }
}
