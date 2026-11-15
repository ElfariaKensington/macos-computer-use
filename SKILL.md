---
name: macos-computer-use
description: >-
  Comprehensive desktop computer use toolkit for macOS. Controls the desktop, inspects active windows,
  captures normalized screenshots with coordinate grids, interacts with native UI via the Accessibility API (AXUIElement),
  executes pixel-accurate mouse and keyboard actions, manages windows, and controls screensharing/streaming.
  Use this skill whenever the user asks to control the Mac, click buttons, interact with desktop apps (Safari, Finder, Settings, etc.),
  take and analyze screenshots, automate UI tasks, or inspect macOS accessibility trees.
---

# macOS Native Computer Use Skill

This skill equips the agent with complete, low-latency, native desktop control on macOS using built-in operating system APIs: **CoreGraphics / Quartz**, **Accessibility (`AXUIElement`)**, **ScreenCaptureKit**, **AppleScript**, and **Screen Sharing**.

---

## Quick Reference / Executable Toolkit

The core compiled binary is located at:
`~/.gemini/config/skills/macos-computer-use/scripts/bin/mcu` (or wrapped by the helper scripts in `scripts/`).

| Action | Command | Purpose |
| :--- | :--- | :--- |
| **Inspect Displays** | `mcu screen info` | Get screen resolution, scale factor (Retina), mouse position (JSON). |
| **Capture Screen (1x Grid)** | `mcu screen capture --scale-1x --grid` | Capture screenshot downsampled to 1x point space with coordinate grid overlay. |
| **Capture Window** | `mcu screen capture --window <wid> -o /tmp/win.png` | Capture a specific window cleanly by its Window ID. |
| **Isolated Window Capture** | `mcu window capture <app\|wid> [--output <path>]` | Capture background/overshadowed window upright without shadows or occlusions. |
| **Apple Vision OCR** | `mcu ocr [--app <name>] [--window <wid>] [--fast]` | On-device text recognition with exact bounding boxes & centers (JSON supported). |
| **Semantic Click-by-Text** | `mcu click text <query> [--app <name>] [--done]` | Find and click text in background windows with virtual cursor glide & ripple. |
| **Background Scroll** | `mcu mouse scroll <dy> [--app <name>] [--window <wid>]` | Scroll background window without stealing focus. |
| **Background Range Select** | `mcu select range <x1> <y1> <x2> <y2> [--app <name>]` | Drag/select text range in background without stealing focus. |
| **List Windows** | `mcu window list` | Get on-screen windows, titles, owners, bounds `[x,y,w,h]` (JSON). |
| **Focus App / Window** | `mcu window focus <app|pid|wid>` | Bring target app or window to the foreground. |
| **Move / Resize Window** | `mcu window move <wid> <x> <y> <w> <h>` | Reposition and size a window in points. |
| **Search UI Elements** | `mcu ax find --app <name> --role <role>` | Find buttons, text fields, or labels via Accessibility tree (semantic). |
| **Semantic Click** | `mcu ax click --app <name> --title <title>` | Trigger `AXPress` action directly without moving the mouse. |
| **Inspect Coordinate** | `mcu ax inspect <x> <y>` | Identify which UI element is located at point `(x, y)`. |
| **Mouse Click** | `mcu mouse click <x> <y>` | Click at exact coordinates (`--button right`, `--count 2`, `--done` supported). |
| **Mouse Drag** | `mcu mouse drag <x1> <y1> <x2> <y2>` | Smooth drag-and-drop between points. |
| **Mouse Scroll** | `mcu mouse scroll <dx> <dy>` | Hardware scroll wheel event (negative `dy` scrolls down). |
| **Type Unicode Text** | `mcu keyboard type "<text>"` | Type arbitrary text including emojis and unicode symbols. |
| **Keyboard Hotkey** | `mcu keyboard hotkey "<combo>"` | Trigger shortcut combinations (e.g. `cmd+space`, `cmd+c`, `cmd+t`). |
| **Clipboard Sync** | `mcu clipboard get` / `mcu clipboard set "<text>"` | Read from or write to the macOS pasteboard. |
| **PiP Live Oversight** | `mcu pip show --app <name>` / `mcu pip hide` | Edge-to-edge live floating preview with frosted-glass hover controls. |
| **Virtual Cursor** | `mcu cursor start` / `mcu cursor done` | Independent delta arrow pointer (zero disruption to hardware mouse). |
| **Complete & Cleanup** | `mcu done` | Automatically dismiss all PiP previews and virtual cursor overlay. |
| **Native MCP Server** | `mcu mcp` | stdio JSON-RPC 2.0 server for OpenChamber, OpenCode, Claude Code, Cursor. |
| **Emergency Halt** | `mcu emergency stop` / `mcu emergency resume` | Instant deadman kill switch freezing all agent activity. |
| **Screenshare & Video** | `mcu screenshare status` / `mcu record start <out.mp4>` | Monitor screen sharing services or record action video. |

---

## Non-Disruptive Virtual Cursor & Access Controls

The skill incorporates a dedicated **delta arrow cursor pointer** (matching the modern collaborative/multiplayer cursor design: solid black delta body, rounded corners, white/grey halo outline):

- **Non-Activating Panel**: Runs in a borderless AppKit panel (`.nonactivatingPanel`) that never steals window focus or disrupts user keyboard focus.
- **100% Click-Through**: `panel.ignoresMouseEvents = true` guarantees the user can click, select, and type right through the virtual cursor with zero disruption.
- **Hardware Mouse Preservation**: Physical clicks save user mouse coordinates and restore them in <5ms so the user's hand on the trackpad is never interrupted.
- **Tactile Click Animation**: When clicking, the cursor arrow compresses slightly (scale 0.88 towards the tip) and emits a subtle ripple ring.
- **Multi-Tier Access Controls**: App boundaries (`blocked_apps`), screen region geofencing, blocked hotkeys, rate limiting, and an emergency deadman kill switch (`mcu emergency stop`).

Follow these standard steps whenever performing desktop computer use:

### Step 1: Understand Screen Geometry and Active Windows
Before interacting, inspect the current desktop layout:
```bash
~/.gemini/config/skills/macos-computer-use/scripts/bin/mcu screen info
~/.gemini/config/skills/macos-computer-use/scripts/bin/mcu window list
```
- Note the display bounds (e.g., `2056 x 1329 points`).
- Identify the window ID or PID of the target application.
- If the target application is not active, focus it:
  ```bash
  ~/.gemini/config/skills/macos-computer-use/scripts/bin/mcu window focus "Safari"
  ```

### Step 2: Visual Inspection (Screenshot with 1x Point Scaling & Grid)
Capture the current screen state:
```bash
~/.gemini/config/skills/macos-computer-use/scripts/macos_shot.sh --grid -o /tmp/screen_current.png
```
> [!IMPORTANT]
> **Why `--scale-1x` is Crucial**:
> On Retina displays, raw pixels are 2x the logical points resolution. The `--scale-1x` flag ensures that **1 pixel in the image equals exactly 1 point on the screen**. When you look at `/tmp/screen_current.png`, coordinate `(x, y)` in the image matches the exact click coordinate for `mcu mouse click x y`!
> The `--grid` flag overlays coordinate tick marks and numbers every 100 points, making target identification effortless.

### Step 3: Choose Between Semantic AX vs Coordinate Clicking

#### Preference: Semantic Accessibility (`AXUIElement`)
Whenever possible, prefer semantic interaction because it is immune to layout shifts and window repositioning:
```bash
# 1. Search for buttons or controls:
~/.gemini/config/skills/macos-computer-use/scripts/bin/mcu ax find --app "Safari" --title "Sign In"

# 2. Click it directly:
~/.gemini/config/skills/macos-computer-use/scripts/bin/mcu ax click --app "Safari" --title "Sign In"
```

#### Fallback: Coordinate Clicking (`CGEvent`)
If the element lacks accessibility metadata (e.g. custom canvas, game, or non-standard web element):
```bash
# Move and click at coordinates determined from grid screenshot:
~/.gemini/config/skills/macos-computer-use/scripts/bin/mcu mouse click 420 315
```

### Step 4: Text Input & Keyboard Automation
To type text:
```bash
# Method A: Direct native typing
~/.gemini/config/skills/macos-computer-use/scripts/bin/mcu keyboard type "Hello from macOS Computer Use!"

# Method B: Fast clipboard injection (best for long text or code snippets)
~/.gemini/config/skills/macos-computer-use/scripts/bin/mcu clipboard set "Long text snippet..."
~/.gemini/config/skills/macos-computer-use/scripts/bin/mcu keyboard hotkey "cmd+v"
```

### Step 5: Verification
Always take a follow-up screenshot or check window status to verify that the action achieved the desired state:
```bash
~/.gemini/config/skills/macos-computer-use/scripts/macos_shot.sh -o /tmp/screen_after_action.png
```

### Step 5: Background Overshadowed Interaction & Semantic OCR
You can interact with background windows completely hidden or overshadowed by other apps:
```bash
# 1. Capture isolated window upright without occlusions or shadows:
mcu window capture "iTerm2" --output /tmp/iterm.png

# 2. Run fast on-device Apple Vision OCR:
mcu ocr --app "iTerm2" --fast

# 3. Semantically find and click text inside background app:
mcu click text "delete-blobs" --app "iTerm2" --done

# 4. Scroll background window without stealing focus:
mcu mouse scroll -5 --app "iTerm2" --done

# 5. Select range of text in background without focus:
mcu select range 1120 365 1600 365 --app "iTerm2" --done
```

---

## OpenChamber GUI & MCP Server Integration

`mcu` includes a native stdio MCP server (`mcu mcp`) compatible with OpenChamber, OpenCode, Claude Code, and Cursor.

### Automatic OpenCode / OpenChamber Integration
Configured globally in `~/.config/opencode/opencode.json`:
```json
{
  "mcp": {
    "servers": {
      "macos-computer-use": {
        "type": "local",
        "command": [
          "~/.gemini/config/skills/macos-computer-use/scripts/bin/mcu",
          "mcp"
        ]
      }
    }
  }
}
```

### OpenChamber GUI "New MCP Server" Modal
If adding manually through OpenChamber's **Settings → MCP / Integrations → New MCP server** modal:
- **Server name**: `macos-computer-use`
- **Enable server**: `[x]` Checked
- **Availability**: `Available in every project`
- **How to reach it**: `>_ Command`
- **Command Box** (one argument per line):
  ```
  ~/.gemini/config/skills/macos-computer-use/scripts/bin/mcu
  mcp
  ```
- **Or via "Import from JSON snippet"**:
  ```json
  {
    "macos-computer-use": {
      "command": "~/.gemini/config/skills/macos-computer-use/scripts/bin/mcu",
      "args": ["mcp"]
    }
  }
  ```

---

## Detailed References & Runbooks

- [macOS APIs & System Tools Reference](./references/macos_apis.md)
- [Coordinate Spaces: Points vs Retina Pixels Guide](./references/coordinate_spaces.md)
- [Semantic Accessibility (`AXUIElement`) Guide](./references/accessibility_guide.md)
- [Permissions & TCC Troubleshooting](./references/permissions_troubleshooting.md)
- [Example: Safari Web Navigation](./examples/safari_workflow.md)
- [Example: Finder & Window Management](./examples/finder_workflow.md)
- [Example: System Settings Automation](./examples/settings_workflow.md)
