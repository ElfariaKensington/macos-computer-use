# macOS Permissions & TCC Troubleshooting

macOS security enforces Transparency, Consent, and Control (TCC) permissions for desktop interaction and screen capture.

---

## 1. Required Permissions

| Permission | TCC Service Identifier | Purpose | How to Verify |
| :--- | :--- | :--- | :--- |
| **Screen Recording** | `kTCCServiceScreenCapture` | Capturing full-screen and off-app window pixels | `screencapture -x -m /tmp/test.png` |
| **Accessibility** | `kTCCServiceAccessibility` | Inspecting UI trees (`AXUIElement`) and posting input events (`CGEvent`) | `swift -e 'print(AXIsProcessTrusted())'` |

---

## 2. Diagnosing Issues

### Check Accessibility Trust
Run:
```bash
~/.gemini/config/skills/macos-computer-use/scripts/bin/mcu mouse pos
```
If the command prints coordinates without error, Accessibility is authorized.
If it fails or returns `(0, 0)`:
1. Open **System Settings** > **Privacy & Security** > **Accessibility**.
2. Ensure the calling application (e.g., Terminal, iTerm2, Antigravity) is enabled in the list.

### Check Screen Recording
Run:
```bash
~/.gemini/config/skills/macos-computer-use/scripts/bin/mcu screen capture --output /tmp/test_perm.png
```
If `screencapture` reports `could not create image from display`:
1. Open **System Settings** > **Privacy & Security** > **Screen & System Audio Recording**.
2. Add and toggle ON the host application (Terminal, iTerm, Antigravity).
3. In macOS Sequoia / Sonoma, toggling requires relaunching the terminal or process once to take effect.

---

## 3. Screen Sharing & Remote Management

To verify if macOS Screen Sharing is active:
```bash
~/.gemini/config/skills/macos-computer-use/scripts/macos_screenshare.sh status
```
To enable Screen Sharing in System Settings:
1. Go to **System Settings** > **General** > **Sharing**.
2. Toggle ON **Screen Sharing** (or **Remote Management**).
3. Use `mcu screenshare open localhost` to view or test local screen mirroring.
