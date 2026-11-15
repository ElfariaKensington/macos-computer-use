# macOS Native APIs & System Tools Reference

This guide covers the underlying macOS APIs and command-line utilities used for Computer Use, desktop automation, screen capture, and accessibility navigation.

---

## 1. CoreGraphics (Quartz Display Services)

### Screen & Window Geometry
- `CGMainDisplayID()`: Returns the display ID for the primary display.
- `CGDisplayBounds(displayID)`: Returns the bounding rectangle of the display in logical points (top-left origin `(0, 0)`).
- `CGDisplayPixelsWide(displayID)` / `CGDisplayPixelsHigh(displayID)`: Returns physical pixel resolution (e.g., 4112x2658 on Retina displays with scale factor 2.0).
- `CGWindowListCopyWindowInfo(options, kCGNullWindowID)`: Retrieves metadata for all on-screen windows:
  - `kCGWindowNumber`: Unique Window ID (wid).
  - `kCGWindowOwnerPID`: Process ID of owner application.
  - `kCGWindowOwnerName`: Application name (e.g., `Safari`, `Finder`).
  - `kCGWindowName`: Window title.
  - `kCGWindowBounds`: Dictionary with `X`, `Y`, `Width`, `Height` in points.
  - `kCGWindowLayer`: Window z-layer (layer 0 represents standard app windows).

### Event Synthesis (`CGEvent`)
`CGEvent` creates low-level hardware input events delivered via `cghidEventTap`:
- **Mouse Movement**:
  ```swift
  let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
  event?.post(tap: .cghidEventTap)
  ```
- **Mouse Clicks**:
  ```swift
  let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)
  down?.setIntegerValueField(.mouseEventClickState, value: 1) // 1=single, 2=double, 3=triple
  down?.post(tap: .cghidEventTap)
  let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)
  up?.post(tap: .cghidEventTap)
  ```
- **Scroll Wheel**:
  ```swift
  // wheel1 = vertical lines, wheel2 = horizontal lines
  let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
  scroll?.post(tap: .cghidEventTap)
  ```
- **Unicode Text Typing**:
  ```swift
  let utf16 = Array(string.utf16)
  let keyEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
  keyEvent?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
  keyEvent?.post(tap: .cghidEventTap)
  ```

---

## 2. Accessibility APIs (`AXUIElement`)

The macOS Accessibility subsystem (`ApplicationServices.framework`) provides a semantic object model of the graphical interface.

- **System-Wide Reference**: `AXUIElementCreateSystemWide()`
- **Application Element**: `AXUIElementCreateApplication(pid)`
- **Query Attributes**:
  - `kAXRoleAttribute`: Role name (`AXButton`, `AXTextField`, `AXStaticText`, `AXWindow`, `AXMenu`, `AXMenuItem`, `AXCheckBox`, `AXSlider`, etc.)
  - `kAXTitleAttribute`: Visible text label or title.
  - `kAXValueAttribute`: Dynamic value of text inputs, sliders, or pickers.
  - `kAXDescriptionAttribute`: Accessible description / tooltip.
  - `kAXPositionAttribute` & `kAXSizeAttribute`: Position and dimensions in global screen points.
  - `kAXChildrenAttribute`: Child elements array.
- **Hit Testing**:
  `AXUIElementCopyElementAtPosition(systemWide, Float(x), Float(y), &element)` directly identifies which UI element is located at any coordinate.
- **Action Invocation**:
  `AXUIElementPerformAction(element, kAXPressAction as CFString)` simulates clicking a button or menu item programmatically without moving the physical mouse cursor.

---

## 3. ScreenCaptureKit (`ScreenCaptureKit.framework`)

Available in macOS 12.3+:
- High-performance, hardware-accelerated screen capture and video streaming.
- `SCShareableContent`: Enumerates shareable displays, applications, and windows.
- `SCContentFilter`: Allows excluding specific apps (e.g. hiding Antigravity or sensitive windows from the captured stream).
- `SCStream`: Real-time frame streaming with customizable frame rates and pixel formats.

---

## 4. Built-in macOS CLI Utilities

- `screencapture`:
  - `screencapture -x -m /tmp/shot.png`: Silent capture of main monitor.
  - `screencapture -x -C -m /tmp/shot.png`: Capture including cursor.
  - `screencapture -x -l<wid> /tmp/win.png`: Capture specific window ID.
  - `screencapture -x -R<x,y,w,h> /tmp/rect.png`: Capture cropped region.
  - `screencapture -v /tmp/video.mp4`: Record video until interrupted.
- `sips`: Scriptable image processing system (e.g., resizing, format conversion, metadata queries).
- `osascript`: Executes AppleScript and JavaScript for Automation (JXA).
- `shortcuts`: Executes macOS Shortcuts from the shell (`shortcuts run "<Name>"`).
- `pbcopy` & `pbpaste`: System clipboard read/write (`pbcopy < file.txt`, `pbpaste`).
- `open`: Launches applications (`open -a "Safari"`) or URL handlers (`open "vnc://localhost"`).
- `cliclick`: Robust open-source CLI for mouse and keyboard simulation.
