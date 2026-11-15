# Example: Automating Safari Navigation & Web Interaction

This workflow demonstrates how to focus Safari, navigate to a website, inspect elements, and interact.

---

## 1. Focus Safari and Open URL

```bash
# Bring Safari to front
mcu window focus "Safari"

# Focus location bar via hotkey Cmd+L
mcu keyboard hotkey "cmd+l"

# Type target URL
mcu keyboard type "https://news.ycombinator.com"

# Press Return
mcu keyboard key "return"
```

---

## 2. Capture Normalized Screenshot with Grid

```bash
# Wait for page to render (1-2s), then capture with coordinate grid:
sleep 2
mcu screen capture --scale-1x --grid --output /tmp/safari_view.png
```

The resulting `/tmp/safari_view.png` is normalized to 1x logical points. You can inspect the image or coordinate numbers directly.

---

## 3. Find and Click Links / Buttons

### Method A: Semantic Accessibility
```bash
# Find buttons or links on the page
mcu ax find --app "Safari" --role "AXLink" --contains "Comments"

# Click first match directly via AX
mcu ax click --app "Safari" --title "comments"
```

### Method B: Coordinate Click
```bash
# Click coordinate identified from grid image (e.g., x=450, y=320)
mcu mouse click 450 320
```

---

## 4. Scroll and Read

```bash
# Scroll down
mcu mouse scroll 0 -8

# Take new snapshot to verify scroll
mcu screen capture --scale-1x --output /tmp/safari_after_scroll.png
```
