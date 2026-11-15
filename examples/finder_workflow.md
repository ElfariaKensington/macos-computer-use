# Example: Finder Navigation and Window Management

This runbook demonstrates listing Finder windows, moving files, focusing windows, and resizing.

---

## 1. List All Active Windows

```bash
# Query all visible windows on screen
mcu window list
```

Example JSON element:
```json
{
  "id": 11806,
  "app": "Finder",
  "title": "Downloads",
  "bounds": { "x": 397, "y": 721, "width": 920, "height": 436 }
}
```

---

## 2. Focus and Reposition Window

```bash
# Bring Finder window to front
mcu window focus 11806

# Move and resize window to (x: 100, y: 100, w: 1000, h: 700)
mcu window move 11806 100 100 1000 700
```

---

## 3. Interact with Files

```bash
# Select an item by typing its name in Finder
mcu keyboard type "report"

# Open item with Cmd+O
mcu keyboard hotkey "cmd+o"

# Or reveal inspector with Cmd+I
mcu keyboard hotkey "cmd+i"
```
