# macOS Computer Use (`mcu`)

A native Swift CLI and stdio **MCP server** that gives AI agents low-latency, non-disruptive desktop control on macOS — with a floating virtual cursor, live Picture-in-Picture (PiP) oversight, on-device Apple Vision OCR, and zero-focus background interaction.

---

## What It Is & What It Does

`mcu` compiles to a single native macOS binary using Apple's built-in frameworks (**CoreGraphics**, **Accessibility / `AXUIElement`**, **AppKit**, **ScreenCaptureKit**, and **Vision**). Unlike browser-only extensions or naive input injectors that hijack your mouse and pull windows to the front, `mcu` lets agents inspect and operate background windows cleanly while you keep working:

- **Non-Disruptive Virtual Cursor**: Renders a smooth, click-through floating pointer overlay (`.nonactivatingPanel`) with click ripples — your physical trackpad/mouse pointer is never displaced.
- **Live ScreenCaptureKit PiP Oversight**: Streams the target window in a persistent floating Picture-in-Picture preview with frosted-glass controls, edge docking, and mirrored virtual cursor movement.
- **Zero-Focus Background Click, Type & Scroll**: Sends targeted clicks (`AXPress` hit-testing + PID-scoped events), text input, hotkeys, range selections, and smooth scrolling to background apps (including Safari/WebKit) **without stealing window focus**.
- **Isolated Background Window Capture (`mcu window capture`)**: Captures occluded or background windows upright at 1:1 Retina logical point resolution without shadows or overlapping windows.
- **On-Device Apple Vision OCR (`mcu ocr`, `mcu click text`)**: Extracts text and exact screen bounding boxes in ~200ms and lets the agent click UI text semantically.
- **Native Stdio MCP Server (`mcu mcp`)**: Exposes 16 ready-to-use tools (`click`, `move`, `type`, `key`, `hotkey`, `scroll`, `select_range`, `click_text`, `ocr`, `screen_capture`, `window_capture`, `window_list`, `pip_show`, `pip_hide`, `browser_open`, `done`) over JSON-RPC 2.0.
- **Safety Guardrails**: Configurable app blocklists (`config/access_control.json`), blocked system hotkeys, screen-region geofencing, rate limiting, JSONL audit logs, and an instant kill switch (`mcu emergency stop`).

---

## 1. Prerequisites & Build

### Requirements
- macOS 13.0+ (Apple Silicon or Intel)
- Xcode Command Line Tools (`xcode-select --install`) for building from source (not required if downloading a prebuilt Release binary)

### Build from Source (Recommended)

```bash
git clone git@github.com:ElfariaKensington/macos-computer-use.git ~/.config/macos-computer-use
cd ~/.config/macos-computer-use
./scripts/build.sh
```

This compiles the binary to:
```text
~/.config/macos-computer-use/scripts/bin/mcu
```

*(Optional)* Download a prebuilt Universal (`arm64` + `x86_64`) archive from the **Releases** page, extract it to `~/.config/macos-computer-use`, and ensure `scripts/bin/mcu` is executable (`chmod +x ~/.config/macos-computer-use/scripts/bin/mcu`).

### Grant macOS Permissions
The first time `mcu` runs, grant these permissions in **System Settings → Privacy & Security** to the host app running `mcu` (your terminal, Codex, Claude, DeepSeek Harness, or OpenChamber):
1. **Accessibility** (required for `AXUIElement` inspection, clicking, typing, and scrolling)
2. **Screen & System Audio Recording** (required for screenshots, OCR, and live ScreenCaptureKit PiP previews)

Quick self-test:
```bash
~/.config/macos-computer-use/scripts/bin/mcu screen info
~/.config/macos-computer-use/scripts/bin/mcu window list
```

---

## 2. Step-by-Step Client Setup

Replace `$HOME` below with your actual home directory path (for example `/Users/yourname`) when writing JSON/TOML config files that do not expand `~`.

### Codex GUI

1. Open `~/.codex/config.toml` in your editor (create it if it does not exist).
2. Add the `[mcp_servers.macos-computer-use]` block:
   ```toml
   [mcp_servers.macos-computer-use]
   command = "/Users/<YOUR_USER>/.config/macos-computer-use/scripts/bin/mcu"
   args = ["mcp"]
   startup_timeout_sec = 30
   ```
3. Save `~/.codex/config.toml` and restart **Codex** (or reload MCP servers from Codex settings).
4. Verify `macos-computer-use` appears as enabled in the Codex MCP servers list.

---

### Claude Code GUI

1. Open a terminal and register `mcu` globally via the Claude CLI (or edit `~/.claude.json` directly):
   ```bash
   claude mcp add --scope user --transport stdio macos-computer-use -- \
     "$HOME/.config/macos-computer-use/scripts/bin/mcu" mcp
   ```
   Or add this manually inside the `"mcpServers"` object in `~/.claude.json`:
   ```json
   {
     "mcpServers": {
       "macos-computer-use": {
         "type": "stdio",
         "command": "/Users/<YOUR_USER>/.config/macos-computer-use/scripts/bin/mcu",
         "args": ["mcp"],
         "env": {}
       }
     }
   }
   ```
2. Restart the **Claude Code GUI** / **Claude** app.
3. Confirm `macos-computer-use` shows up under connected MCP servers with its 16 tools.

---

### DeepSeek Harness

DeepSeek Harness reads its runtime & MCP server definitions from the Codex configuration directory (`~/.codex/config.toml` alongside `~/.codex/deepseek.config.toml`).

1. Ensure your DeepSeek model profile exists in `~/.codex/deepseek.config.toml`:
   ```toml
   model = "deepseek/deepseek-r1-0528-qwen3-8b"
   model_provider = "lmstudio"
   ```
2. Add `mcu` to `~/.codex/config.toml`:
   ```toml
   [mcp_servers.macos-computer-use]
   command = "/Users/<YOUR_USER>/.config/macos-computer-use/scripts/bin/mcu"
   args = ["mcp"]
   startup_timeout_sec = 30
   ```
3. Restart **DeepSeek Harness.app**.
4. Verify in the DeepSeek Harness tool/MCP inspector that `macos-computer-use` is online and selectable.

---

### OpenChamber

OpenChamber uses OpenCode's configuration file at `~/.config/opencode/opencode.json`.

1. Open or create `~/.config/opencode/opencode.json`.
2. Register `macos-computer-use` under `mcp.servers`:
   ```json
   {
     "mcp": {
       "servers": {
         "macos-computer-use": {
           "type": "local",
           "command": [
             "/Users/<YOUR_USER>/.config/macos-computer-use/scripts/bin/mcu",
             "mcp"
           ]
         }
       }
     }
   }
   ```
3. Restart **OpenChamber.app**.
4. Open the MCP status panel in OpenChamber to confirm `macos-computer-use` is connected.

---

## Quick CLI Reference

```bash
# Inspect windows and displays
mcu screen info
mcu window list

# Open live PiP monitor for a background window (stays pinned until hidden or `mcu done`)
mcu pip show --app "Safari"

# Capture background window without occlusions or shadows (1:1 points)
mcu window capture "Safari" --output /tmp/safari.png

# Run on-device Apple Vision OCR or click text semantically
mcu ocr --app "Safari" --fast
mcu click text "Search" --app "Safari"

# Interact with a background window without stealing focus
mcu mouse click 450 110 --app "Safari"
mcu keyboard type "green hell" --app "Safari"
mcu mouse scroll -15 --app "Safari"

# Clean up virtual cursor and close PiP previews
mcu done

# Emergency deadman kill switch
mcu emergency stop
mcu emergency resume
```

---

## Security & Access Control

Edit `config/access_control.json` to customize:
- `blocked_apps`: Password managers and disk tools blocked by default
- `blocked_hotkeys`: Restricted destructive system shortcuts
- `allowed_screen_regions` / `blocked_screen_regions`: Coordinate geofencing
- `rate_limiting`: Action rate throttle (`max_actions_per_minute`, `min_delay_ms`)
- `audit_logging`: Structured JSONL log of every action
