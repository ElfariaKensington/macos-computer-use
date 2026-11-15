# Example: System Settings & Permissions Verification

This runbook demonstrates how to inspect and toggle controls inside macOS System Settings.

---

## 1. Focus System Settings

```bash
# Launch or focus System Settings
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
mcu window focus "System Settings"
```

---

## 2. Inspect Accessibility Tree

```bash
# Dump the visible controls in System Settings
mcu ax dump --app "System Settings" --depth 3
```

---

## 3. Find Specific Controls & Toggles

```bash
# Search for switches or checkboxes
mcu ax find --app "System Settings" --role "AXCheckBox"
```

---

## 4. Toggle via Semantic Click

```bash
# Click the target toggle directly
mcu ax click --app "System Settings" --title "Antigravity"
```
