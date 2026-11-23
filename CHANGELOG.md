# Changelog

## v0.2.0

### Zero-focus background input, rebuilt on SkyLight

Clicking, typing and keys no longer bring apps to the front or move your cursor. The old path
fell back to HID for Chromium/CEF (which drop public `CGEvent.postToPid` clicks): it called
`activate()`, raised the window and warped the real mouse. That fallback is gone from the default
path.

- **New `BGInput` delivery layer.** Mouse and keyboard events go to the target pid through
  SkyLight's `SLEventPostToPid`, stamped with the target pid (field 40), window id (51/91/92) and a
  `CGEventSetWindowLocation` point (window-local on macOS 27+). Chromium accepts these as trusted.
  Keyboard events carry an `SLSEventAuthenticationMessage` (macOS 15+).
- **Focus without raise.** For background apps a yabai-style focus record is posted to the target
  process only, so it routes clicks and keys to the right window without becoming frontmost.
  This also fixes AppKit text views ignoring the first click (caret placement) and menu key
  equivalents such as `cmd+s` being dropped in background apps.
- **Chromium user-activation primer.** Left clicks send an off-screen (-1, -1) primer pair before
  the real click, so web pages treat background clicks as user gestures (menus, dialogs, popups).
- **Sibling windows.** When the target app is frontmost but you are working in another of its
  windows, the click/keys land in the target window and your key window is handed back afterwards.
- **Correct window routing.** App-only targets now route to the window actually under the point
  instead of the app's topmost window; keyboard input follows the window of the last click.
- **Text fields get real clicks.** Inputs are clicked (not `AXPress`ed) so they take caret and DOM
  focus before typing.
- **Hover works.** `move` now delivers a pid-routed `mouseMoved`, so hover states and tooltips fire.
- **Drag, select_range and scroll** use the same routed delivery.
- **No double submit.** Return no longer also fires `AXConfirm` when keys are delivered reliably.
- `hid: true` (explicit opt-in) is unchanged and still the only path that activates or moves the
  real cursor.

Not stamped on purpose: event fields 0 (phase) and 58 (click group). With them, a navigating
click crashes Chrome's renderer ("Aw, Snap!", error 5).

Tested in the background with another app frontmost: Google Chrome (Gemini: menus, settings,
Developer Mode, filling the "Connect to an MCP server" dialog), Steam (CEF: tabs, library search,
clear button), TextEdit (AppKit: caret placement, typing, Return, `cmd+s`), a SwiftUI app,
Antigravity (Electron: typing, `cmd+a`, delete), the sibling-window case in Chrome, and a Windows
game run from Steam under Wine / Game Porting Toolkit (Funnel Runners, UE5 D3D12: menu click,
hover, Escape).
