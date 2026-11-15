# Semantic Accessibility Automation (`AXUIElement`)

Visual Computer Use (taking screenshots and predicting click coordinates) can be brittle when UI layouts shift, windows resize, or fonts render dynamically. 

macOS provides a native, deterministic alternative: the **Accessibility Object Model** (`AXUIElement`).

---

## 1. Why Use Accessibility Over Visual Clicking?

| Visual Automation (Screenshots) | Semantic Accessibility (`AXUIElement`) |
| :--- | :--- |
| Susceptible to visual occlusions and font shifts | Deterministic tree lookup by element role and title |
| Requires guessing pixel coordinates | Provides exact bounding boxes and center coordinates |
| Must bring window to front and physically move cursor | Can trigger `AXPress` directly without moving cursor |
| Slow: takes image, runs vision inference | Fast: runs in ~2-5 milliseconds |
| Hard to read dynamic values in text fields | Directly reads `kAXValueAttribute` |

---

## 2. Common Accessibility Roles

| Role | Description | Typical Actions |
| :--- | :--- | :--- |
| `AXButton` | Standard push button | `mcu ax click --title "Save"` |
| `AXTextField` | Editable text field | `mcu keyboard type "text"` or read value |
| `AXStaticText` | Label or display text | Read text content |
| `AXPopUpButton` | Dropdown menu button | Click to open menu options |
| `AXMenuItem` | Menu bar or context menu item | Click to trigger menu action |
| `AXCheckBox` | Toggle checkbox | Click to toggle |
| `AXRadioButton` | Radio selection button | Click to select |
| `AXTabGroup` | Tab bar container | Click tab buttons to switch views |
| `AXWindow` | Top-level application window | Move, resize, focus, close |

---

## 3. Workflow Runbook

### Step 1: Dump or Search the Accessibility Tree
Find the exact buttons or text fields in the frontmost window:
```bash
mcu ax find --app "Safari" --role "AXButton"
```
Sample JSON output:
```json
[
  {
    "role": "AXButton",
    "title": "Reload this page",
    "frame": { "x": 1280, "y": 72, "width": 28, "height": 28 },
    "center": { "x": 1294, "y": 86 }
  }
]
```

### Step 2: Trigger Native Action
You have two choices:
1. **Direct AX Action (No mouse movement)**:
   ```bash
   mcu ax click --app "Safari" --title "Reload this page"
   ```
2. **Coordinate Click (Using exact calculated center)**:
   ```bash
   mcu mouse click 1294 86
   ```

### Step 3: Inspect Elements Under Cursor
If you want to know what element exists at a specific coordinate:
```bash
mcu ax inspect 1294 86
```
Returns the role, title, description, and frame of the element directly under that coordinate.
