# macOS Coordinate Spaces: Points vs Retina Pixels

Understanding coordinate spaces is essential for reliable Computer Use on macOS.

---

## 1. The Core Distinction: Points vs Pixels

macOS distinguishes between **Logical Points** and **Physical Device Pixels**:

- **Logical Points**:
  - The coordinate system used by macOS user interface APIs, window managers, and input events (`CGEvent`, `cliclick`, `AXUIElement`).
  - Standard display resolution on a 14" MacBook Pro might be **2056 x 1329 points**.
  - A click command sent to `(1000, 500)` means 1000 points from the left, 500 points from the top.

- **Physical Device Pixels**:
  - The actual physical hardware pixels rendered by the display.
  - On Retina displays, macOS uses HiDPI scaling, commonly **2x** (`backingScaleFactor = 2.0`).
  - Raw screenshots taken by `screencapture` are saved in physical pixels: **4112 x 2658 pixels**!

> [!WARNING]
> **The Retina Trap**:
> If an AI vision model looks at a raw 4112x2658 Retina screenshot and picks coordinate `(2000, 1000)` based on the pixel image, a mouse click at `(2000, 1000)` will land in the wrong place or miss the target completely because input events expect **points**!

---

## 2. The Solution: Normalized 1x Point Scaling

The `mcu screen capture --scale-1x` tool solves this problem permanently:
1. It reads the backing scale factor of the active display.
2. It resamples the raw screenshot down to the exact **1x logical points dimensions** (e.g. 2056x1329) using high-quality bicubic downsampling.
3. **Result**: 1 pixel in the resulting PNG image equals EXACTLY 1 point for mouse coordinates!
   - Pixel coordinate `(x, y)` in the image = `mcu mouse click x y`!
   - No mental math, no division by 2, zero coordinate drift.

---

## 3. Coordinate Origins

Different macOS subsystems use different origins:

| Subsystem | Coordinate Origin | Y-Axis Direction | Used By |
| :--- | :--- | :--- | :--- |
| **Window / Input Space** | **Top-Left** `(0, 0)` | **Downwards** (+Y goes down) | `CGEvent`, `screencapture`, `cliclick`, `AXUIElement`, `mcu` |
| **AppKit / Cocoa Space** | **Bottom-Left** `(0, 0)` | **Upwards** (+Y goes up) | `NSScreen`, `NSWindow`, raw `CGContext` |

`mcu` automatically handles the coordinate conversion and uses the standard **Top-Left origin** everywhere:
- `(0, 0)` is the upper-left corner of the primary display.
- Positive `X` moves right.
- Positive `Y` moves down towards the bottom of the screen.

---

## 4. Multi-Monitor Coordinate Layouts

When multiple monitors are connected, macOS arranges them in a virtual desktop space:
- The **Primary Display** always has its top-left at `(0, 0)`.
- A secondary monitor placed to the **left** of the main monitor will have **negative X coordinates** (e.g., `x: -1920 to 0`).
- A secondary monitor placed **above** the main monitor will have **negative Y coordinates**.
- Use `mcu screen info` to inspect the exact bounds of each display before targeting secondary screens.
