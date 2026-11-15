# Non-Disruptive Virtual Cursor & Access Control Engine

This guide details the non-disruptive execution model, the custom floating virtual cursor overlay, and the multi-tier access control engine built into `mcu`.

---

## 1. The Fancy Virtual Cursor Overlay

Automating desktop actions usually causes disruption when the agent hijacks the hardware mouse, violently moving the user's pointer away from what they are working on.

`mcu` eliminates this friction using an independent **Virtual Cursor Overlay Daemon**:

### Architecture & Non-Disruptive Properties
- **Non-Activating Window (`.nonactivatingPanel`)**:
  The cursor runs in a borderless AppKit panel that **never steals focus** from active windows or typing fields.
- **Click-Through (`ignoresMouseEvents = true`)**:
  The overlay is 100% transparent to user interactions. The user can click right through the cursor, drag files under it, or select text without any interference.
- **Visual Design**:
  - Glowing cyan-violet gradient pointer disc with electric cyan hotspot.
  - Outer breathing glow ring pulsing gently.
  - Attached subtle capsule pill: `✦ AGY`.
  - **Click Ripple Animation**: When clicking, emits an expanding concentric wave (electric cyan for left-click, amber for right-click).
  - **Dynamic Glow Themes**: Can switch themes dynamically (`mcu cursor glow cyan|emerald|violet|amber|crimson`).
  - **Idle Auto-Dim**: Dims to 25% opacity after 5 seconds of inactivity so it remains unobtrusive.

### Cursor & PiP Commands
```bash
mcu cursor start                                    # Launch virtual cursor & PiP daemon
mcu cursor stop                                     # Terminate virtual cursor daemon
mcu cursor move <x> <y> [--speed slow|normal|fast] # Slower 60fps glide without moving hardware mouse
mcu cursor done                                     # Dismiss virtual cursor and PiP window cleanly
mcu cursor hide / show                              # Toggle cursor visibility

mcu pip show --app <AppName>                        # Open edge-to-edge PiP live preview with hover controls
mcu pip hide                                        # Close PiP live preview
```

### PiP (Picture-in-Picture) Live Window Oversight
When controlling an application (e.g. Safari), `mcu pip show --app Safari` displays an edge-to-edge floating window of the target app:
- **Aspect-Ratio Locked**: Fills 100% of the panel with zero black letterbox or pillarbox bars.
- **Wide-Radius Frosted Glass Capsule**: Hovering over the top-left reveals a `22pt` radius frosted glass capsule (`NSVisualEffectView` with `.hudWindow` blur) containing:
  - `X`: Emergency abort / close button.
  - `PiP Dock`: Return / toggle button.
- **Hover Transitions**: The frosted glass capsule fades in smoothly on mouse enter, and fades out on mouse leave.
- **Auto-Dismiss**: Calling `mcu cursor done` automatically fades out both the virtual cursor and the PiP window.

---

## 2. Non-Disruptive Hardware Mouse Preservation

When physical mouse clicks are required:
1. `mcu` samples the user's current hardware mouse position `userPos = getMousePosition()`.
2. Teleports to the target coordinates and emits the click.
3. Automatically restores the user's mouse pointer back to `userPos` within <5 milliseconds!
4. Concurrently, the virtual cursor glides to the target point and displays the click ripple.

**Result**: The user never experiences their cursor jumping or losing their place.

---

## 3. Multi-Tier Access Control Engine

All actions (`mouse click`, `mouse move`, `window focus`, `ax click`, `keyboard hotkey`) pass through the **Access Control Engine** before execution.

Configuration file:
[`~/.gemini/config/skills/macos-computer-use/config/access_control.json`](../config/access_control.json)

### Access Control Layers

1. **Application Boundaries (Allowlist & Blocklist)**:
   - `blocked_apps`: Prohibits interaction with sensitive applications (e.g., `1Password`, `Keychain Access`, `Passwords`, `Bitwarden`, `Disk Utility`).
   - `allowed_apps`: Restricts actions to specific permitted applications (or `["*"]` for all non-blocked apps).

2. **Geofencing & Screen Region Constraints**:
   - `blocked_screen_regions`: Restricts clicks from landing inside protected areas (e.g. Apple menu, menu bar, or specific monitor quadrants).
   - `allowed_screen_regions`: Constrains all cursor actions to designated bounding boxes.

3. **Restricted Destructive Hotkeys**:
   - Blocks destructive shortcuts such as `cmd+opt+esc` (Force Quit), `cmd+shift+delete` (Empty Trash), or `cmd+ctrl+q` (Lock Screen).

4. **Rate Limiting & Throttling**:
   - Caps actions per minute (`max_actions_per_minute: 180`) and enforces minimum delay (`min_delay_ms: 25`) to prevent runaway automated loops.

5. **Emergency Deadman Kill Switch**:
   - Instant freeze trigger via `/tmp/mcu_kill.lock`.
   - Any agent command arriving while the lock exists immediately aborts with an emergency halt error code and turns the cursor crimson red.
   - Controlled via:
     ```bash
     mcu emergency stop     # Instantly halts all agent automation
     mcu emergency resume   # Clears halt lock and resumes normal operation
     mcu emergency status   # Checks whether kill switch is engaged
     ```

6. **Tamper-Evident Security Audit Log**:
   - Structured JSON Lines appended to [`logs/audit.jsonl`](../logs/audit.jsonl).
   - Records: timestamp, action, targetApp, coordinates/details, decision (`ALLOWED`, `BLOCKED`, `KILL_SWITCH_ENGAGED`), and reason.
   - Inspect via:
     ```bash
     mcu audit tail --n 20
     ```
