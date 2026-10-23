import Cocoa
import FlutterMacOS
import XCTest
@testable import aiplayer

@MainActor
class RunnerTests: XCTestCase {
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
}

private final class InputView: NSView {
  override var acceptsFirstResponder: Bool { true }
}
