import Cocoa
import CoreGraphics
import ApplicationServices
import ImageIO
import CoreText
import QuartzCore
import CoreImage
import ScreenCaptureKit
import CoreMedia
import Vision

// MARK: - Constants & Identifiers

let kCursorNotificationName = "com.antigravity.mcu.cursor.event"
let kMCURootDirectory: String = {
    if let execURL = Bundle.main.executableURL?.resolvingSymlinksInPath() {
        let scriptsOrBin = execURL.deletingLastPathComponent()
        // Case 1: <root>/scripts/bin/mcu
        let rootCandidate1 = scriptsOrBin.deletingLastPathComponent().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: rootCandidate1.appendingPathComponent("resources").path) ||
           FileManager.default.fileExists(atPath: rootCandidate1.appendingPathComponent("config").path) {
            return rootCandidate1.path
        }
        // Case 2: <root>/bin/mcu
        let rootCandidate2 = scriptsOrBin.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: rootCandidate2.appendingPathComponent("resources").path) ||
           FileManager.default.fileExists(atPath: rootCandidate2.appendingPathComponent("config").path) {
            return rootCandidate2.path
        }
    }
    let home = NSHomeDirectory()
    let skillRoot = home + "/.gemini/config/skills/macos-computer-use"
    if FileManager.default.fileExists(atPath: skillRoot) { return skillRoot }
    return home + "/.config/macos-computer-use"
}()
let kDefaultConfigPath = kMCURootDirectory + "/config/access_control.json"
let kDefaultAuditLogPath = kMCURootDirectory + "/logs/audit.jsonl"
let kDefaultKillSwitchPath = "/tmp/mcu_kill.lock"

// MARK: - Keycode Mappings

let keyNameToKeyCode: [String: CGKeyCode] = [
    // Standard keys
    "return": 0x24, "enter": 0x4C, "tab": 0x30, "space": 0x31,
    "delete": 0x33, "backspace": 0x33, "forwarddelete": 0x75,
    "escape": 0x35, "esc": 0x35,
    "command": 0x37, "cmd": 0x37, "shift": 0x38, "capslock": 0x39,
    "option": 0x3A, "opt": 0x3A, "alt": 0x3A, "control": 0x3B, "ctrl": 0x3B,
    "rightshift": 0x3C, "rightoption": 0x3D, "rightcontrol": 0x3E,
    
    // Arrows
    "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    "pageup": 0x74, "pagedown": 0x79, "home": 0x73, "end": 0x77,
    
    // Function keys
    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
    "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
    "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    
    // Letters & Symbols
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
    "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
    "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
    "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
    "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E,
    "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25,
    "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A, ",": 0x2B,
    "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32
]

func parseHotkey(_ combo: String) -> (flags: CGEventFlags, keyCode: CGKeyCode)? {
    let parts = combo.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
    var flags: CGEventFlags = []
    var targetKey: String? = nil
    
    for part in parts {
        switch part {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt", "option", "alt": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        case "fn": flags.insert(.maskSecondaryFn)
        default:
            targetKey = part
        }
    }
    
    guard let key = targetKey, let code = keyNameToKeyCode[key] else {
        return nil
    }
    return (flags, code)
}

// MARK: - Access Control Engine & Audit Logging

struct AccessControlEngine {
    static var config: [String: Any] = loadConfig()
    static var lastActionTimestamp: Date = Date()
    static var actionHistory: [Date] = []
    
    static func loadConfig() -> [String: Any] {
        let path = (kDefaultConfigPath as NSString).expandingTildeInPath
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let policy = json["policy"] as? [String: Any] {
            return policy
        }
        return [
            "mode": "enforcing",
            "blocked_apps": ["Keychain Access", "Passwords", "1Password", "Bitwarden", "KeePassXC", "Disk Utility"],
            "allowed_apps": ["*"],
            "blocked_screen_regions": [],
            "allowed_screen_regions": [],
            "blocked_hotkeys": ["cmd+opt+esc", "cmd+shift+delete"],
            "non_disruptive": ["restore_user_cursor": true, "virtual_cursor_enabled": true],
            "kill_switch": ["lock_file": kDefaultKillSwitchPath]
        ]
    }
    
    static func isKillSwitchActive() -> Bool {
        let killFile = (config["kill_switch"] as? [String: Any])?["lock_file"] as? String ?? kDefaultKillSwitchPath
        return FileManager.default.fileExists(atPath: (killFile as NSString).expandingTildeInPath)
    }
    
    static func validate(action: String, targetApp: String? = nil, point: CGPoint? = nil, hotkey: String? = nil) -> (allowed: Bool, reason: String) {
        // 1. Emergency Kill Switch check
        if isKillSwitchActive() {
            return (false, "EMERGENCY HALT: Kill switch is active (/tmp/mcu_kill.lock). Use 'mcu emergency resume' to unlock.")
        }
        
        let mode = config["mode"] as? String ?? "enforcing"
        if mode == "audit_only" {
            return (true, "Mode: audit_only")
        }
        
        // 2. Target App Boundaries
        if let app = targetApp, !app.isEmpty {
            let blockedApps = config["blocked_apps"] as? [String] ?? []
            for b in blockedApps {
                if app.localizedCaseInsensitiveContains(b) {
                    return (false, "ACCESS DENIED: Application '\(app)' is in blocked_apps list")
                }
            }
            let allowedApps = config["allowed_apps"] as? [String] ?? ["*"]
            if !allowedApps.contains("*") {
                let isAllowed = allowedApps.contains { app.localizedCaseInsensitiveContains($0) }
                if !isAllowed {
                    return (false, "ACCESS DENIED: Application '\(app)' is not in allowed_apps allowlist")
                }
            }
        }
        
        // 3. Geofencing (Screen Regions)
        if let pt = point {
            if let blockedRegions = config["blocked_screen_regions"] as? [[String: Double]], !blockedRegions.isEmpty {
                for r in blockedRegions {
                    let rx = r["x"] ?? 0; let ry = r["y"] ?? 0; let rw = r["width"] ?? 0; let rh = r["height"] ?? 0
                    if pt.x >= rx && pt.x <= (rx + rw) && pt.y >= ry && pt.y <= (ry + rh) {
                        return (false, "ACCESS DENIED: Coordinate (\(Int(pt.x)), \(Int(pt.y))) falls within blocked screen region")
                    }
                }
            }
            if let allowedRegions = config["allowed_screen_regions"] as? [[String: Double]], !allowedRegions.isEmpty {
                var insideAllowed = false
                for r in allowedRegions {
                    let rx = r["x"] ?? 0; let ry = r["y"] ?? 0; let rw = r["width"] ?? 0; let rh = r["height"] ?? 0
                    if pt.x >= rx && pt.x <= (rx + rw) && pt.y >= ry && pt.y <= (ry + rh) {
                        insideAllowed = true
                        break
                    }
                }
                if !insideAllowed {
                    return (false, "ACCESS DENIED: Coordinate (\(Int(pt.x)), \(Int(pt.y))) falls outside permitted screen regions")
                }
            }
        }
        
        // 4. Blocked Hotkeys
        if let hk = hotkey?.lowercased() {
            let blockedHotkeys = (config["blocked_hotkeys"] as? [String] ?? []).map { $0.lowercased() }
            if blockedHotkeys.contains(hk) {
                return (false, "ACCESS DENIED: Hotkey '\(hk)' is restricted by security policy")
            }
        }
        
        // 5. Rate Limiting
        let rateLimit = config["rate_limiting"] as? [String: Any] ?? [:]
        if (rateLimit["enabled"] as? Bool) ?? true {
            let maxPerMin = rateLimit["max_actions_per_minute"] as? Int ?? 180
            let now = Date()
            actionHistory = actionHistory.filter { now.timeIntervalSince($0) < 60.0 }
            if actionHistory.count >= maxPerMin {
                return (false, "RATE LIMIT EXCEEDED: Action throttled (exceeded \(maxPerMin) actions/min)")
            }
            actionHistory.append(now)
            
            let minDelay = Double(rateLimit["min_delay_ms"] as? Int ?? 25) / 1000.0
            let elapsed = now.timeIntervalSince(lastActionTimestamp)
            if elapsed < minDelay {
                usleep(useconds_t((minDelay - elapsed) * 1_000_000))
            }
            lastActionTimestamp = Date()
        }
        
        return (true, "Allowed")
    }
    
    static func logAudit(action: String, targetApp: String? = nil, details: String = "", decision: String = "ALLOWED", reason: String = "") {
        guard let auditConfig = config["audit_logging"] as? [String: Any],
              (auditConfig["enabled"] as? Bool) ?? true else { return }
        
        let rawPath = auditConfig["log_path"] as? String ?? kDefaultAuditLogPath
        let logPath = (rawPath as NSString).expandingTildeInPath
        
        let isoFormatter = ISO8601DateFormatter()
        let timestamp = isoFormatter.string(from: Date())
        
        let entry: [String: Any] = [
            "timestamp": timestamp,
            "action": action,
            "targetApp": targetApp ?? "none",
            "details": details,
            "decision": decision,
            "reason": reason
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: entry),
           let jsonStr = String(data: data, encoding: .utf8) {
            let line = jsonStr + "\n"
            let logURL = URL(fileURLWithPath: logPath)
            
            // Ensure directory exists
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                if let lineData = line.data(using: .utf8) {
                    handle.write(lineData)
                }
                try? handle.close()
            } else {
                try? line.write(to: logURL, atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - Virtual Cursor Client (IPC)

struct VirtualCursorClient {
    static let center = DistributedNotificationCenter.default()
    
    static var isEnabled: Bool {
        let nonDisruptive = AccessControlEngine.config["non_disruptive"] as? [String: Any]
        return (nonDisruptive?["virtual_cursor_enabled"] as? Bool) ?? true
    }
    
    static func ensureDaemonRunning() {
        guard isEnabled else { return }
        // Check if running via pgrep or test file
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "mcu cursor-daemon"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        
        if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Spawn background cursor daemon
            let binPath = CommandLine.arguments[0]
            let daemonTask = Process()
            daemonTask.executableURL = URL(fileURLWithPath: binPath)
            daemonTask.arguments = ["cursor-daemon"]
            try? daemonTask.run()
            // Give the fresh daemon time to register its notification observer, or the first message is lost.
            usleep(700000)
        }
    }
    
    static func send(action: String, extra: [String: Any] = [:]) {
        guard isEnabled else { return }
        ensureDaemonRunning()
        var dict = extra
        dict["action"] = action
        center.postNotificationName(
            NSNotification.Name(kCursorNotificationName),
            object: nil,
            userInfo: dict,
            deliverImmediately: true
        )
        CFRunLoopRunInMode(.defaultMode, 0.002, false)
    }
    
    static func move(to pt: CGPoint, speed: String? = nil, duration: Double? = nil) {
        var extra: [String: Any] = ["x": pt.x, "y": pt.y]
        if let s = speed { extra["speed"] = s }
        if let d = duration { extra["duration"] = d }
        send(action: "move", extra: extra)
    }
    
    static func click(at pt: CGPoint, button: String = "left") {
        send(action: "click", extra: ["x": pt.x, "y": pt.y, "button": button])
    }
    
    static func glow(color: String) {
        send(action: "glow", extra: ["color": color])
    }
    
    static func pipShow(appName: String? = nil, windowID: Int? = nil, anchorPID: pid_t? = nil) {
        var extra: [String: Any] = [:]
        if let a = appName { extra["app"] = a }
        if let w = windowID { extra["windowID"] = w }
        if let pid = anchorPID ?? callerAppPID() { extra["anchorPID"] = Int(pid) }
        // Persist active PiP target PID so subsequent background actions without --window still route without stealing focus
        var resolvedTargetPID: pid_t? = nil
        if let w = windowID {
            try? "\(w)".write(toFile: "/tmp/mcu_active_pip_wid.txt", atomically: true, encoding: .utf8)
            let wins = getWindowsList(allLayers: true)
            if let win = wins.first(where: { ($0["id"] as? Int) == w }),
               let p = (win["pid"] as? Int) ?? (win["pid"] as? Int32).map(Int.init) {
                resolvedTargetPID = pid_t(p)
            }
        } else if let a = appName {
            if let match = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(a) == true }) {
                resolvedTargetPID = match.processIdentifier
            }
        }
        if let tp = resolvedTargetPID {
            try? "\(tp)".write(toFile: "/tmp/mcu_active_pip_pid.txt", atomically: true, encoding: .utf8)
            try? "\(tp)".write(toFile: "/tmp/mcu_last_target_pid.txt", atomically: true, encoding: .utf8)
        }
        send(action: "pip_show", extra: extra)
    }

    static func pipDock(side: String = "right") {
        send(action: "pip_dock", extra: ["side": side])
    }

    static func pipUndock() {
        send(action: "pip_undock")
    }

    /// Walks up the process tree to the GUI app that launched this CLI (terminal, IDE, agent app).
    static func callerAppPID() -> pid_t? {
        var pid = getppid()
        var hops = 0
        while pid > 1 && hops < 64 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                return pid
            }
            pid = parentPID(of: pid)
            hops += 1
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }
    
    static func pipHide(windowID: Int? = nil) {
        if windowID == nil {
            try? FileManager.default.removeItem(atPath: "/tmp/mcu_active_pip_pid.txt")
            try? FileManager.default.removeItem(atPath: "/tmp/mcu_active_pip_wid.txt")
        }
        send(action: "pip_hide", extra: windowID.map { ["windowID": $0] } ?? [:])
    }
    
    static func done() {
        try? FileManager.default.removeItem(atPath: "/tmp/mcu_active_pip_pid.txt")
        try? FileManager.default.removeItem(atPath: "/tmp/mcu_active_pip_wid.txt")
        try? FileManager.default.removeItem(atPath: "/tmp/mcu_last_target_pid.txt")
        send(action: "done")
    }
    
    static func hide() {
        send(action: "hide")
    }
    
    static func show() {
        send(action: "show")
    }
    
    static func stop() {
        send(action: "stop")
    }
}

// MARK: - PiP Preview Surface

// Private WindowServer switch so this background (accessory) process may set the cursor while hovering the PiP.
// Without it, the frontmost app keeps overriding NSCursor.set() and the resize cursor never appears.
@_silgen_name("_CGSDefaultConnection") private func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

private let enableBackgroundCursor: Void = {
    let cid = _CGSDefaultConnection()
    _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
}()

private final class PiPControlButton: NSButton {
    private static let restingAlpha: CGFloat = 0.78
    private static let hoverAlpha: CGFloat = 0.94
    private var hoverTrackingArea: NSTrackingArea?
    var clickHandler: (() -> Void)?

    init(image: NSImage, label: String, onClick: (() -> Void)? = nil) {
        self.clickHandler = onClick
        super.init(frame: .zero)
        setButtonType(.momentaryChange)
        isBordered = false
        focusRingType = .none
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        title = ""
        contentTintColor = .white
        self.image = image
        setAccessibilityLabel(label)
        toolTip = label
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = .zero
        layer?.shadowRadius = 3
        layer?.shadowOpacity = 0.25
    }

    required init?(coder: NSCoder) { fatalError() }

    var resting: CGFloat { Self.restingAlpha }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    // Subtle hover: a small lift in opacity, no glow.
    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = Self.hoverAlpha
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = Self.restingAlpha
        }
    }

    override func mouseDown(with event: NSEvent) {
        animator().alphaValue = 1.0
        window?.trackEvents(matching: [.leftMouseUp, .leftMouseDragged], timeout: 10, mode: .eventTracking) { [weak self] trackEvent, stop in
            guard let self, let trackEvent else { return }
            let loc = self.convert(trackEvent.locationInWindow, from: nil)
            let inside = self.bounds.contains(loc)
            self.animator().alphaValue = inside ? Self.hoverAlpha : Self.restingAlpha
            if trackEvent.type == .leftMouseUp {
                stop.pointee = true
                if inside {
                    if let handler = self.clickHandler {
                        handler()
                    } else if let action = self.action, let target = self.target {
                        NSApp.sendAction(action, to: target, from: self)
                    }
                }
            }
        }
    }
}

enum PiPCorner {
    case topLeft, topRight, bottomLeft, bottomRight
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
}

enum PiPDockSide {
    case left
    case right
}

enum PiPInteraction {
    case move
    case resize(PiPCorner)
}

protocol PiPInteractionDelegate: AnyObject {
    /// The corner pinned to the caller window; it never moves during a resize and has no handle.
    var pinnedCorner: PiPCorner { get }
    /// Only the front card of a stack can be resized.
    var isFrontmost: Bool { get }
    func pipInteractionBegan(_ kind: PiPInteraction)
    func pipInteractionChanged(_ kind: PiPInteraction, delta: CGVector)
    func pipInteractionEnded(_ kind: PiPInteraction)
    /// A card behind the front one was clicked.
    func pipRequestFront()
}

final class HoverPiPView: NSView {
    /// Transparent room around the preview: haze spill (top/left) and the drop shadow (all sides).
    static let margin = NSEdgeInsets(top: 20, left: 22, bottom: 30, right: 24)
    static let cornerRadius: CGFloat = 16
    private static let handleInside: CGFloat = 18
    private static let handleOutside: CGFloat = 6
    private static let ciContext = CIContext()

    private let shadowLayer = CALayer()
    private let previewLayer = CALayer()
    private let captureLayer = CALayer()
    private let hazeLayer = CALayer()
    private let dimLayer = CALayer()
    private var backDim: Float = 0
    private var backHovered = false
    private let shadowCutout = CAShapeLayer()
    private let shadowContainer = CALayer()
    private let shadowCornerMask = CALayer()
    private let shadowCornerCutout = CALayer()
    private let shadowCornerSolid = CALayer()
    private let cornerMaskLayer = CALayer()
    private let cornerCutoutLayer = CALayer()
    private let cornerSolidLayer = CALayer()
    private var currentCapture: CIImage?
    private var lastHazeRender: CFTimeInterval = 0
    private var hazeSize: CGSize = .zero
    private var pendingHaze: DispatchWorkItem?
    private var controlsVisible = false
    private let stopButton: PiPControlButton
    private let dismissButton: PiPControlButton
    private var trackingArea: NSTrackingArea?
    private var activeInteraction: PiPInteraction?
    private var dragStart: NSPoint = .zero
    private var hasDragged = false
    private var pendingRaise = false
    private var pendingFrontClick = false
    private var isFrontCard: Bool { interactionDelegate?.isFrontmost ?? true }

    // Mirror Cursor & Action Projection (Feature 1)
    private let mirrorRippleLayer = CALayer()
    private let mirrorCursorContainer = CALayer()
    private let mirrorCursorImage = CALayer()
    private var isMirrorCursorVisible: Bool = false
    private let mirrorAssetWidth: CGFloat = 18.0
    private var mirrorAssetHeight: CGFloat { mirrorAssetWidth * (1001.0 / 1024.0) }
    private var mirrorTipXRatio: CGFloat { 208.0 / 1024.0 }
    private var mirrorTipYRatio: CGFloat { (1001.0 - 194.0) / 1001.0 }

    // Live Edge Docking (Feature 3)
    private let dockOverlay = CALayer()
    private let dockChevronLayer = CALayer()
    private let dockGrabLayer = CALayer()
    private(set) var dockSide: PiPDockSide? = nil
    var onUndock: (() -> Void)?

    weak var interactionDelegate: PiPInteractionDelegate?
    var onEmergencyClose: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onActivateTarget: (() -> Void)?

    override init(frame: NSRect) {
        _ = enableBackgroundCursor
        let resourceDirectory = URL(fileURLWithPath: kMCURootDirectory).appendingPathComponent("resources")
        let closeImage = NSImage(contentsOf: resourceDirectory.appendingPathComponent("pip_control_close.png"))
            ?? NSImage(systemSymbolName: "xmark", accessibilityDescription: "Stop computer control")!
        let dockImage = NSImage(contentsOf: resourceDirectory.appendingPathComponent("pip_control_dock.png"))
            ?? NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: "Dismiss live preview")!
        stopButton = PiPControlButton(image: closeImage, label: "Stop computer control")
        dismissButton = PiPControlButton(image: dockImage, label: "Dismiss live preview")
        super.init(frame: frame)

        wantsLayer = true
        // Drop shadow only: no body (it would show through the blurred corner) and clipped to outside the window.
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.35
        shadowLayer.shadowRadius = 10
        shadowLayer.shadowOffset = CGSize(width: 0, height: -5)
        shadowCutout.fillRule = .evenOdd
        shadowLayer.mask = shadowCutout
        // The shadow's crisp inner edge would outline the corner under the blur, so it fades out there too.
        shadowCornerCutout.contentsGravity = .resize
        shadowCornerSolid.backgroundColor = NSColor.white.cgColor
        shadowCornerMask.addSublayer(shadowCornerCutout)
        shadowCornerMask.addSublayer(shadowCornerSolid)
        shadowContainer.mask = shadowCornerMask
        shadowContainer.addSublayer(shadowLayer)
        layer?.addSublayer(shadowContainer)

        previewLayer.cornerRadius = Self.cornerRadius
        previewLayer.masksToBounds = true
        previewLayer.backgroundColor = NSColor.black.cgColor
        captureLayer.contentsGravity = .resizeAspectFill
        previewLayer.addSublayer(captureLayer)

        // Agent Action Mirroring (Feature 1)
        mirrorRippleLayer.masksToBounds = true
        mirrorRippleLayer.zPosition = 50
        previewLayer.addSublayer(mirrorRippleLayer)

        mirrorCursorContainer.bounds = CGRect(x: 0, y: 0, width: mirrorAssetWidth, height: mirrorAssetHeight)
        mirrorCursorContainer.anchorPoint = CGPoint(x: mirrorTipXRatio, y: mirrorTipYRatio)
        mirrorCursorContainer.zPosition = 100
        mirrorCursorContainer.opacity = 0.0
        mirrorCursorContainer.shadowColor = NSColor.black.cgColor
        mirrorCursorContainer.shadowOpacity = 0.65
        mirrorCursorContainer.shadowRadius = 2.0
        mirrorCursorContainer.shadowOffset = CGSize(width: 0, height: -1)

        mirrorCursorImage.frame = CGRect(x: 0, y: 0, width: mirrorAssetWidth, height: mirrorAssetHeight)
        let assetPaths = [
            resourceDirectory.appendingPathComponent("cursor.png").path,
            NSHomeDirectory() + "/.config/macos-computer-use/resources/cursor.png",
            NSHomeDirectory() + "/.gemini/config/skills/macos-computer-use/resources/cursor.png"
        ]
        var loaded = false
        for p in assetPaths {
            if let img = NSImage(contentsOfFile: p),
               let cgImg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                mirrorCursorImage.contents = cgImg
                mirrorCursorImage.contentsGravity = .resizeAspect
                loaded = true
                break
            }
        }
        if !loaded {
            let shape = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 2, y: 2))
            path.addLine(to: CGPoint(x: 11, y: 5))
            path.addLine(to: CGPoint(x: 7, y: 7))
            path.addLine(to: CGPoint(x: 5, y: 11))
            path.closeSubpath()
            shape.path = path
            shape.fillColor = NSColor.black.cgColor
            shape.strokeColor = NSColor.white.cgColor
            shape.lineWidth = 1.0
            mirrorCursorImage.addSublayer(shape)
        }
        mirrorCursorContainer.addSublayer(mirrorCursorImage)
        previewLayer.addSublayer(mirrorCursorContainer)

        // Live Edge Docking Tab (Feature 3)
        dockOverlay.opacity = 0.0
        dockOverlay.zPosition = 200
        dockOverlay.backgroundColor = NSColor(white: 0.10, alpha: 0.88).cgColor
        dockOverlay.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        dockOverlay.borderWidth = 1.0
        dockOverlay.cornerRadius = Self.cornerRadius

        dockGrabLayer.backgroundColor = NSColor.white.withAlphaComponent(0.40).cgColor
        dockGrabLayer.cornerRadius = 1.5
        dockOverlay.addSublayer(dockGrabLayer)

        dockChevronLayer.contentsGravity = .resizeAspect
        dockOverlay.addSublayer(dockChevronLayer)
        previewLayer.addSublayer(dockOverlay)

        layer?.addSublayer(previewLayer)
        // Depth shading for cards behind the front one (lifted while hovered).
        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.cornerRadius = Self.cornerRadius
        dimLayer.opacity = 0
        layer?.addSublayer(dimLayer)
        // On hover the sharp corner fades out (solid layer -> 0) exactly where the blurred corner fades in.
        cornerCutoutLayer.contentsGravity = .resize
        cornerSolidLayer.backgroundColor = NSColor.white.cgColor
        cornerMaskLayer.addSublayer(cornerCutoutLayer)
        cornerMaskLayer.addSublayer(cornerSolidLayer)
        previewLayer.mask = cornerMaskLayer

        // The blurred corner of the window itself; its edge melts into whatever is behind the PiP.
        hazeLayer.contentsGravity = .resize
        hazeLayer.opacity = 0
        layer?.addSublayer(hazeLayer)

        for button in [stopButton, dismissButton] {
            button.alphaValue = 0
            button.target = self
            addSubview(button)
        }
        stopButton.action = #selector(stopControl)
        dismissButton.action = #selector(dismissPreview)
        stopButton.clickHandler = { [weak self] in self?.stopControl() }
        dismissButton.clickHandler = { [weak self] in self?.dismissPreview() }
    }

    convenience init(frame: NSRect, image: CGImage?) {
        self.init(frame: frame)
        updatePreview(with: image)
    }

    required init?(coder: NSCoder) { fatalError() }

    var previewRect: CGRect {
        let m = Self.margin
        return CGRect(x: m.left, y: m.bottom,
                      width: max(0, bounds.width - m.left - m.right),
                      height: max(0, bounds.height - m.top - m.bottom))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let preview = previewRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowContainer.frame = bounds
        shadowCornerMask.frame = bounds
        shadowCornerCutout.frame = bounds
        shadowCornerSolid.frame = bounds
        shadowLayer.frame = bounds
        let windowPath = CGPath(roundedRect: preview, cornerWidth: Self.cornerRadius,
                                cornerHeight: Self.cornerRadius, transform: nil)
        shadowLayer.shadowPath = windowPath
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addPath(windowPath)
        shadowCutout.frame = bounds
        shadowCutout.path = outside
        previewLayer.frame = preview
        dimLayer.frame = preview
        captureLayer.frame = previewLayer.bounds
        cornerMaskLayer.frame = previewLayer.bounds
        cornerCutoutLayer.frame = previewLayer.bounds
        cornerSolidLayer.frame = previewLayer.bounds
        hazeLayer.frame = bounds
        mirrorRippleLayer.frame = previewLayer.bounds
        if let side = dockSide {
            layoutDockOverlay(for: side)
        }
        CATransaction.commit()
        stopButton.frame = NSRect(x: preview.minX + 13, y: preview.maxY - 13 - 22, width: 22, height: 22)
        dismissButton.frame = NSRect(x: preview.minX + 42, y: preview.maxY - 13 - 23, width: 25, height: 23)
        // Re-rendering the haze is a Core Image pass; during a live resize, stretch the old one and redo it once settled.
        if bounds.size != hazeSize && activeInteraction == nil { scheduleHazeRefresh(after: 0.12) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if dockSide != nil {
            return bounds.contains(local) ? self : nil
        }
        // Generous hit targets for controls so clicking close/dock is always responsive
        if stopButton.frame.insetBy(dx: -4, dy: -4).contains(local) { return stopButton }
        if dismissButton.frame.insetBy(dx: -4, dy: -4).contains(local) { return dismissButton }
        guard previewRect.contains(local) || resizeCorner(at: local) != nil else { return nil }
        if let hit = super.hitTest(point), hit !== self { return hit }
        return self
    }

    // MARK: Hover

    private var hoverRect: CGRect { previewRect.insetBy(dx: -Self.handleOutside, dy: -Self.handleOutside) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: hoverRect,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if dockSide != nil {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            dockOverlay.backgroundColor = NSColor(white: 0.18, alpha: 0.95).cgColor
            dockGrabLayer.backgroundColor = NSColor.white.withAlphaComponent(0.80).cgColor
            CATransaction.commit()
            NSCursor.pointingHand.set()
            return
        }
        // Back cards light up and show a pointing hand: a click brings them forward (controls hidden).
        if isFrontCard { setControlsVisible(true) } else { setControlsVisible(false); setBackHovered(true) }
        updateCursor(for: event)
    }

    func setBackDim(_ value: Float, animated: Bool) {
        backDim = value
        if value == 0 { backHovered = false }
        applyDim(animated: animated)
    }

    private func setBackHovered(_ hovered: Bool) {
        guard backHovered != hovered else { return }
        backHovered = hovered
        applyDim(animated: true)
    }

    private func applyDim(animated: Bool) {
        let target: Float = backHovered ? 0 : backDim
        if animated {
            animateOpacity(dimLayer, to: target, duration: 0.18)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dimLayer.removeAnimation(forKey: "hoverOpacity")
            dimLayer.opacity = target
            CATransaction.commit()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if dockSide != nil {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            dockOverlay.backgroundColor = NSColor(white: 0.10, alpha: 0.88).cgColor
            dockGrabLayer.backgroundColor = NSColor.white.withAlphaComponent(0.40).cgColor
            CATransaction.commit()
            NSCursor.arrow.set()
            return
        }
        setBackHovered(false)
        guard activeInteraction == nil else { return }
        setControlsVisible(false)
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        guard activeInteraction == nil else { return }
        updateCursor(for: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard activeInteraction == nil else { return }
        updateCursor(for: event)
    }

    private func updateCursor(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !isFrontCard {
            NSCursor.pointingHand.set()
        } else if let corner = resizeCorner(at: point) {
            resizeCursor(for: corner).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    func setControlsVisible(_ visible: Bool) {
        let shouldShow = visible && isFrontCard && dockSide == nil
        guard controlsVisible != shouldShow else { return }
        controlsVisible = shouldShow
        if shouldShow && hazeLayer.contents == nil { renderHaze() }
        let duration = shouldShow ? 0.22 : 0.3
        // Never let both layers be half-transparent at once: the blurred frame fades in over the intact preview,
        // and only once it's nearly opaque does the sharp corner edge (visible under the smoke) drop away.
        // Leaving runs the other way round.
        let on = shouldShow && hazeLayer.contents != nil
        if on {
            animateOpacity(hazeLayer, to: 1, duration: duration)
            animateOpacity(cornerSolidLayer, to: 0, duration: duration * 0.4, delay: duration * 0.6)
            animateOpacity(shadowCornerSolid, to: 0, duration: duration)
        } else {
            animateOpacity(cornerSolidLayer, to: 1, duration: duration * 0.35)
            animateOpacity(shadowCornerSolid, to: 1, duration: duration)
            animateOpacity(hazeLayer, to: 0, duration: duration, delay: duration * 0.15)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            stopButton.animator().alphaValue = shouldShow ? stopButton.resting : 0
            dismissButton.animator().alphaValue = shouldShow ? dismissButton.resting : 0
        }
    }

    /// Animates from what is on screen right now, so a quick hover/dehover reverses smoothly mid-flight.
    private func animateOpacity(_ layer: CALayer, to value: Float, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        let current = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = value
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current
        fade.toValue = value
        fade.duration = duration
        if delay > 0 {
            fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            fade.fillMode = .backwards
        }
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "hoverOpacity")
    }

    /// Tracking areas can miss the exit when the window moves or is re-ordered under a still pointer;
    /// called periodically to drop a stuck hover state.
    func verifyHover() {
        guard activeInteraction == nil, let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let onTop = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
        let over = hoverRect.contains(point) && onTop
        if (over && isFrontCard) != controlsVisible { setControlsVisible(over && isFrontCard) }
        setBackHovered(over && !isFrontCard)
    }

    // MARK: Move / resize

    private func resizeCorner(at point: NSPoint) -> PiPCorner? {
        let p = previewRect
        let inside = Self.handleInside, outside = Self.handleOutside
        func near(_ v: CGFloat, _ edge: CGFloat, inward: CGFloat) -> Bool {
            let d = (v - edge) * inward
            return d >= -outside && d <= inside
        }
        let left = near(point.x, p.minX, inward: 1)
        let right = near(point.x, p.maxX, inward: -1)
        let bottom = near(point.y, p.minY, inward: 1)
        let top = near(point.y, p.maxY, inward: -1)
        let corner: PiPCorner?
        switch (left, right, top, bottom) {
        case (true, _, true, _): corner = .topLeft
        case (_, true, true, _): corner = .topRight
        case (true, _, _, true): corner = .bottomLeft
        case (_, true, _, true): corner = .bottomRight
        default: corner = nil
        }
        guard interactionDelegate?.isFrontmost ?? true else { return nil }
        return corner == interactionDelegate?.pinnedCorner ? nil : corner
    }

    private func resizeCursor(for corner: PiPCorner) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch corner {
            case .topLeft: position = .topLeft
            case .topRight: position = .topRight
            case .bottomLeft: position = .bottomLeft
            case .bottomRight: position = .bottomRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        return .crosshair
    }

    override func mouseDown(with event: NSEvent) {
        if dockSide != nil {
            onUndock?()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let corner = resizeCorner(at: point)
        if event.clickCount >= 2 && corner == nil {
            onActivateTarget?()
            return
        }
        hasDragged = false
        pendingRaise = !isFrontCard
        let kind: PiPInteraction = corner.map { .resize($0) } ?? .move
        activeInteraction = kind
        // Moving keeps the size, so the blur stays; only a resize would stretch the pre-rendered blur.
        if case .resize = kind { suspendHaze() }
        dragStart = NSEvent.mouseLocation
        if case .move = kind { NSCursor.closedHand.set() }
        interactionDelegate?.pipInteractionBegan(kind)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let kind = activeInteraction else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStart.x
        let dy = now.y - dragStart.y
        if hypot(dx, dy) > 4 {
            hasDragged = true
            pendingRaise = false // User is dragging: do NOT trigger bring to front!
        }
        interactionDelegate?.pipInteractionChanged(kind, delta: CGVector(dx: dx, dy: dy))
    }

    override func mouseUp(with event: NSEvent) {
        let shouldRaise = pendingRaise && !hasDragged
        pendingRaise = false
        hasDragged = false
        guard let kind = activeInteraction else {
            if shouldRaise { interactionDelegate?.pipRequestFront() }
            return
        }
        activeInteraction = nil
        interactionDelegate?.pipInteractionEnded(kind)
        if shouldRaise {
            interactionDelegate?.pipRequestFront()
        }
        let point = convert(event.locationInWindow, from: nil)
        let resized: Bool = { if case .resize = kind { return true } else { return false } }()
        if !hoverRect.contains(point) || !isFrontCard {
            setControlsVisible(false)
            NSCursor.arrow.set()
        } else {
            updateCursor(for: event)
            // Bring the blur back once the snap animation has settled at the final size.
            if resized {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in self?.resumeHaze() }
            }
        }
    }

    /// Tactile raise transition: spring scale lift, shadow elevation bloom, and specular rim highlight.
    func animateRaise() {
        CATransaction.begin()
        // 1. Subtle physical lift scale (1.0 -> 1.035 -> 1.0)
        let lift = CAKeyframeAnimation(keyPath: "transform.scale")
        lift.values = [1.0, 1.035, 0.995, 1.0]
        lift.keyTimes = [0.0, 0.38, 0.72, 1.0]
        lift.duration = 0.28
        lift.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
        layer?.add(lift, forKey: "raiseLift")

        // 2. Shadow elevation pulse (lifts towards viewer, then settles)
        let shadowRad = CAKeyframeAnimation(keyPath: "shadowRadius")
        shadowRad.values = [10.0, 22.0, 10.0]
        shadowRad.keyTimes = [0.0, 0.42, 1.0]
        shadowRad.duration = 0.28
        shadowLayer.add(shadowRad, forKey: "raiseShadowRadius")

        let shadowOp = CAKeyframeAnimation(keyPath: "shadowOpacity")
        shadowOp.values = [0.35, 0.65, 0.35]
        shadowOp.keyTimes = [0.0, 0.42, 1.0]
        shadowOp.duration = 0.28
        shadowLayer.add(shadowOp, forKey: "raiseShadowOpacity")

        // 3. Specular rim highlight on window outline
        let rim = CABasicAnimation(keyPath: "borderColor")
        rim.fromValue = NSColor.white.withAlphaComponent(0.55).cgColor
        rim.toValue = NSColor.clear.cgColor
        rim.duration = 0.35
        previewLayer.borderWidth = 1.5
        previewLayer.borderColor = NSColor.clear.cgColor
        previewLayer.add(rim, forKey: "raiseBorderFlash")

        CATransaction.commit()
    }

    // MARK: - Live Edge Docking (Feature 3)

    private func layoutDockOverlay(for side: PiPDockSide) {
        let tabWidth: CGFloat = 36.0
        let pBounds = previewLayer.bounds
        let tabFrame: CGRect
        switch side {
        case .left:
            tabFrame = CGRect(x: max(0, pBounds.width - tabWidth), y: 0, width: tabWidth, height: pBounds.height)
        case .right:
            tabFrame = CGRect(x: 0, y: 0, width: tabWidth, height: pBounds.height)
        }
        dockOverlay.frame = tabFrame

        let grabH: CGFloat = 28.0
        let grabW: CGFloat = 3.0
        dockGrabLayer.frame = CGRect(x: (tabWidth - grabW) / 2.0, y: (pBounds.height - grabH) / 2.0 - 14.0, width: grabW, height: grabH)

        let iconSize: CGFloat = 16.0
        dockChevronLayer.frame = CGRect(x: (tabWidth - iconSize) / 2.0, y: (pBounds.height - grabH) / 2.0 + 18.0, width: iconSize, height: iconSize)

        let symName = (side == .left) ? "chevron.right" : "chevron.left"
        if let symImg = NSImage(systemSymbolName: symName, accessibilityDescription: "Undock PiP") {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            if let configured = symImg.withSymbolConfiguration(config),
               let cg = configured.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                dockChevronLayer.contents = cg
            }
        }
    }

    func setDocked(_ docked: Bool, side: PiPDockSide?) {
        dockSide = docked ? side : nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        if docked, let side = side {
            layoutDockOverlay(for: side)
            dockOverlay.opacity = 1.0
            stopButton.alphaValue = 0.0
            dismissButton.alphaValue = 0.0
            hazeLayer.opacity = 0.0
            mirrorCursorContainer.opacity = 0.0
        } else {
            dockOverlay.opacity = 0.0
        }
        CATransaction.commit()
    }

    // MARK: - Agent Action Mirroring (Feature 1)

    func mirrorCursorMoved(normalizedX: CGFloat, normalizedY: CGFloat, duration: Double) {
        guard dockSide == nil else { return }
        let pBounds = previewLayer.bounds
        guard pBounds.width > 0, pBounds.height > 0 else { return }
        let px = normalizedX * pBounds.width
        let py = (1.0 - normalizedY) * pBounds.height

        CATransaction.begin()
        CATransaction.setAnimationDuration(max(0.04, duration))
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        mirrorCursorContainer.position = CGPoint(x: px, y: py)
        mirrorCursorContainer.opacity = 1.0
        CATransaction.commit()
        isMirrorCursorVisible = true
    }

    func mirrorCursorClicked(normalizedX: CGFloat, normalizedY: CGFloat, button: String) {
        guard dockSide == nil else { return }
        let pBounds = previewLayer.bounds
        guard pBounds.width > 0, pBounds.height > 0 else { return }
        let px = normalizedX * pBounds.width
        let py = (1.0 - normalizedY) * pBounds.height

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mirrorCursorContainer.position = CGPoint(x: px, y: py)
        mirrorCursorContainer.opacity = 1.0
        CATransaction.commit()

        let press = CABasicAnimation(keyPath: "transform.scale")
        press.fromValue = 1.0
        press.toValue = 0.82
        press.duration = 0.08
        press.autoreverses = true
        press.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        mirrorCursorContainer.add(press, forKey: "mirrorPress")

        let ripple = CAShapeLayer()
        let rSize: CGFloat = 8.0
        ripple.path = CGPath(ellipseIn: CGRect(x: -rSize/2, y: -rSize/2, width: rSize, height: rSize), transform: nil)
        ripple.position = CGPoint(x: px, y: py)
        ripple.fillColor = nil
        ripple.strokeColor = (button == "right") ? NSColor.systemOrange.cgColor : NSColor.white.withAlphaComponent(0.92).cgColor
        ripple.lineWidth = 1.4
        mirrorRippleLayer.addSublayer(ripple)

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 0.4
        scaleAnim.toValue = 2.4
        scaleAnim.duration = 0.30
        scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = 1.0
        fadeAnim.toValue = 0.0
        fadeAnim.duration = 0.30
        fadeAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            ripple.removeFromSuperlayer()
        }
        ripple.add(scaleAnim, forKey: "scale")
        ripple.add(fadeAnim, forKey: "fade")
        CATransaction.commit()
    }

    func mirrorCursorExited() {
        guard isMirrorCursorVisible else { return }
        isMirrorCursorVisible = false
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.20)
        mirrorCursorContainer.opacity = 0.0
        CATransaction.commit()
    }

    /// While dragging, the blur (a pre-rendered full frame) would be stretched and lag behind; show the live preview.
    private func suspendHaze() {
        pendingHaze?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [hazeLayer, cornerSolidLayer, shadowCornerSolid] { layer.removeAnimation(forKey: "hoverOpacity") }
        hazeLayer.opacity = 0
        cornerSolidLayer.opacity = 1
        shadowCornerSolid.opacity = 1
        CATransaction.commit()
    }

    private func resumeHaze() {
        guard controlsVisible, activeInteraction == nil else { return }
        renderHaze()
        guard hazeLayer.contents != nil else { return }
        animateOpacity(hazeLayer, to: 1, duration: 0.18)
        animateOpacity(cornerSolidLayer, to: 0, duration: 0.08, delay: 0.1)
        animateOpacity(shadowCornerSolid, to: 0, duration: 0.18)
    }

    // MARK: Content

    func updatePreview(with image: CGImage?) {
        currentCapture = image.map { CIImage(cgImage: $0) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        captureLayer.contents = image
        CATransaction.commit()
        if controlsVisible && activeInteraction == nil { renderHaze() } else { hazeSize = .zero }
    }

    /// A live ScreenCaptureKit frame: shown straight from its IOSurface (no copy). The corner blur is
    /// re-rendered from it a few times a second while hovered, so it keeps up without burning the GPU.
    func updatePreview(with frame: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(frame)?.takeUnretainedValue() else { return }
        currentCapture = CIImage(cvPixelBuffer: frame)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        captureLayer.contents = surface
        CATransaction.commit()
        guard controlsVisible, activeInteraction == nil else { hazeSize = .zero; return }
        let now = CACurrentMediaTime()
        if now - lastHazeRender > 0.15 { renderHaze() }
    }

    private func scheduleHazeRefresh(after delay: TimeInterval) {
        pendingHaze?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.renderHaze() }
        pendingHaze = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Swaps in a fresh haze image; opacity is left alone so this never causes a flash.
    private func renderHaze() {
        pendingHaze?.cancel()
        hazeSize = bounds.size
        renderCornerCutout()
        lastHazeRender = CACurrentMediaTime()
        let haze = currentCapture.flatMap(makeCornerHaze)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hazeLayer.contents = haze
        CATransaction.commit()
    }

    /// Blurred, dimmed copy of the window's top-left corner. Fully opaque inside the window, so the
    /// corner never turns see-through, and continuing outward as smoke that fades into the desktop.
    private func makeCornerHaze(from source: CIImage) -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        let toPixels = CGAffineTransform(scaleX: scale, y: scale)
        let canvas = bounds.applying(toPixels).integral
        let preview = previewRect.applying(toPixels).integral
        guard !preview.isEmpty, !canvas.isEmpty else { return nil }

        // Aspect-fill the capture into the preview rect, same as the live layer.
        let fill = max(preview.width / source.extent.width, preview.height / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        let placed = scaled.transformed(by: CGAffineTransform(
            translationX: preview.midX - scaled.extent.midX,
            y: preview.midY - scaled.extent.midY
        )).cropped(to: preview)
        let backed = placed.composited(over: CIImage(color: .black).cropped(to: preview))

        // The window as it sits on screen (rounded, transparent outside), blurred as a whole: its edge
        // dissolves into the background exactly like a real gaussian blur over the window.
        let clear = CIImage(color: .clear).cropped(to: canvas)
        let sharp = backed.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: roundedRect(preview, radius: Self.cornerRadius * scale)
        ])
        // Blur the content with its edge pixels extended (clamped), so it is fully opaque everywhere inside
        // the window: nothing behind the PiP ever shows through. The smoke past the edge gets its own alpha,
        // starting at ~1 right on the edge and fading outward, so there is no step at the window outline.
        let sigma = 10 * scale
        let opaqueBlur = backed.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.35])
        let radius = Self.cornerRadius * scale
        let reach = 5 * scale
        let spill = roundedRect(preview.insetBy(dx: -reach, dy: -reach), radius: radius + reach)
            .applyingGaussianBlur(sigma: 6 * scale)
        let shape = roundedRect(preview, radius: radius)
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: spill])
        let blurred = opaqueBlur.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: shape
        ])

        // Soft-edged rectangle over the top-left corner, reaching past the edges to take the spill with it.
        let maskRect = CGRect(x: preview.minX - 40 * scale, y: preview.maxY - 52 * scale,
                              width: 126 * scale, height: 92 * scale)
        let mask = CIImage(color: .white).cropped(to: maskRect).applyingGaussianBlur(sigma: 8 * scale)

        // Full frame: blurred in the corner, sharp elsewhere, so this layer alone is opaque across the window.
        let composite = blurred.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: sharp, kCIInputMaskImageKey: mask
        ]).cropped(to: canvas)
        return Self.ciContext.createCGImage(composite, from: canvas)
    }

    /// Same soft rectangle, inverted, in preview coordinates: masks the sharp preview out where the blur takes over.
    private func renderCornerCutout() {
        let scale = window?.backingScaleFactor ?? 2
        let toPixels = CGAffineTransform(scaleX: scale, y: scale)
        let preview = previewRect.applying(toPixels).integral
        guard !preview.isEmpty else { return }
        let maskRect = CGRect(x: preview.minX - 40 * scale, y: preview.maxY - 52 * scale,
                              width: 126 * scale, height: 92 * scale)
        let mask = CIImage(color: .white).cropped(to: maskRect).applyingGaussianBlur(sigma: 8 * scale)
        let cutout = CIImage(color: .clear).cropped(to: preview).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .white).cropped(to: preview),
            kCIInputMaskImageKey: mask
        ]).cropped(to: preview)
        // Same cutout over the whole canvas, for the shadow (which lives outside the preview).
        let canvas = bounds.applying(toPixels).integral
        let shadowCut = CIImage(color: .clear).cropped(to: canvas).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .white).cropped(to: canvas),
            kCIInputMaskImageKey: mask
        ]).cropped(to: canvas)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cornerCutoutLayer.contents = Self.ciContext.createCGImage(cutout, from: preview)
        shadowCornerCutout.contents = Self.ciContext.createCGImage(shadowCut, from: canvas)
        CATransaction.commit()
    }

    private func roundedRect(_ rect: CGRect, radius: CGFloat) -> CIImage {
        CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            kCIInputExtentKey: CIVector(cgRect: rect),
            kCIInputRadiusKey: radius,
            kCIInputColorKey: CIColor.white
        ])?.outputImage ?? CIImage(color: .white).cropped(to: rect)
    }

    @objc private func stopControl() { onEmergencyClose?() }
    @objc private func dismissPreview() { onDismiss?() }
}

/// Floating live preview pinned to a corner of the app that invoked `mcu pip show`.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Borderless panel that handles its own mouse clicks. A plain NSPanel lets AppKit raise the clicked window
/// on mouse-down, so pressing on a card behind the front one would pop it on top instantly. Here the deck
/// order only changes when our own code says so.
final class PiPPanel: NSPanel {
    private weak var mouseTarget: NSView?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard let content = contentView,
                  let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil)
                                            ?? event.locationInWindow) else { return }
            mouseTarget = hit
            hit.mouseDown(with: event)
        case .leftMouseDragged:
            mouseTarget?.mouseDragged(with: event)
        case .leftMouseUp:
            mouseTarget?.mouseUp(with: event)
            mouseTarget = nil
        default:
            super.sendEvent(event)
        }
    }
}

/// ScreenCaptureKit stream of one window, delivering BGRA frames on the main queue.
final class PiPStream: NSObject, SCStreamOutput, SCStreamDelegate {
    private let windowID: CGWindowID
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "mcu.pip.stream", qos: .userInteractive)
    private var stopped = false
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onFailure: (() -> Void)?

    init(windowID: CGWindowID) { self.windowID = windowID }

    func start() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let window = content.windows.first(where: { $0.windowID == self.windowID }) else {
                    throw NSError(domain: "mcu.pip", code: 1)
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                // Plenty for a PiP; bounded so a huge window doesn't stream 5K frames.
                let fit = min(1, 1600 / max(window.frame.width * scale, 1))
                config.width = max(2, Int(window.frame.width * scale * fit))
                config.height = max(2, Int(window.frame.height * scale * fit))
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.queueDepth = 4
                config.showsCursor = false
                config.capturesAudio = false
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                if self.stopped { try? await stream.stopCapture(); return }
                self.stream = stream
            } catch {
                FileHandle.standardError.write("PiP stream for window \(self.windowID) failed: \(error)\n".data(using: .utf8)!)
                DispatchQueue.main.async { self.onFailure?() }
            }
        }
    }

    func stop() {
        stopped = true
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        DispatchQueue.main.async { [weak self] in self?.onFrame?(frame) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("PiP stream for window \(windowID) stopped: \(error)\n".data(using: .utf8)!)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.onFailure?()
        }
    }
}

/// Owns every open PiP. PiPs pinned to the same corner of the same caller window form a deck: the newest
/// is the front card in the corner, older ones sit behind it, slightly narrower, peeking out past its free
/// edge. The front card is topmost in z-order, so each card's shadow falls onto the card behind it.
final class PiPManager {
    /// Each card behind the front one shifts this far into the caller window (sideways and down/up),
    /// so it shows an L-shaped strip that is easy to see and click.
    /// Collapsed deck: each card behind is this much smaller and shows this much edge past the one in front.
    static let collapsedScaleStep: CGFloat = 0.06
    static let collapsedPeek: CGFloat = 6
    /// Expanded (hovered) deck: cards listed one after another along the edge with this gap.
    static let expandedGap: CGFloat = 10
    static let dimPerLevel: Float = 0.08
    private var expanded: Set<String> = []
    private var collapseWork: [String: DispatchWorkItem] = [:]

    private func deckKey(_ pip: PiPWindowController) -> String { "\(pip.anchorPID ?? -1)-\(pip.corner)" }

    func isExpanded(_ pip: PiPWindowController) -> Bool { expanded.contains(deckKey(pip)) }

    static let cascadeStep = CGVector(dx: 22, dy: 30)
    /// Window-like z-order, back first. Independent of position: raising a PiP never moves it.
    private var zOrder: [ObjectIdentifier] = []

    /// Position in its corner's cascade (0 = oldest, in the corner itself).
    func cascadeIndex(for pip: PiPWindowController) -> Int {
        group(of: pip).firstIndex { $0 === pip } ?? 0
    }

    private func zIndex(_ pip: PiPWindowController) -> Int {
        zOrder.firstIndex(of: ObjectIdentifier(pip)) ?? Int.max
    }

    func isTop(_ pip: PiPWindowController) -> Bool {
        zOrder.last == ObjectIdentifier(pip)
    }

    /// Bring a PiP to the top of its cascade with a tactile spring elevation lift transition.
    func raise(_ pip: PiPWindowController) {
        let isAlreadyTop = zOrder.last == ObjectIdentifier(pip)
        zOrder.removeAll { $0 == ObjectIdentifier(pip) }
        zOrder.append(ObjectIdentifier(pip))
        restackAll()
        if !isAlreadyTop {
            pip.animateRaise()
        }
        relayout(animated: true)
    }

    /// Hovering a deck (any of its cards, plus a little slack so the gaps don't count as leaving) fans it out;
    /// leaving it collapses it again after a short grace period.
    func updateDeckHover(at point: NSPoint) {
        let decks = Dictionary(grouping: pips.filter { $0.isShowing }) { deckKey($0) }
        for (key, deck) in decks {
            if deck.contains(where: { $0.interacting }) { continue }
            let inside = deck.count > 1 && deck.contains { $0.hoverFrame().insetBy(dx: -8, dy: -(Self.expandedGap + 4)).contains(point) }
            if inside {
                collapseWork[key]?.cancel()
                collapseWork[key] = nil
                if !expanded.contains(key) {
                    expanded.insert(key)
                    relayout(animated: true)
                }
            } else if expanded.contains(key), collapseWork[key] == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.collapseWork[key] = nil
                    self.expanded.remove(key)
                    self.relayout(animated: true)
                }
                collapseWork[key] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
        }
    }
    static let visibleDepth = 3
    private(set) var pips: [PiPWindowController] = []
    private var followTimer: Timer?
    private var mouseMonitors: [Any] = []

    func show(appName: String?, windowID: CGWindowID?, anchorPID: pid_t?) {
        let target = windowID ?? appName.flatMap(PiPWindowController.firstWindowID(matchingApp:))
        if let target, pips.contains(where: { $0.targetWindowID == target }) {
            restackAll()
            return
        }
        let pip = PiPWindowController(manager: self)
        pips.append(pip)
        zOrder.append(ObjectIdentifier(pip))
        pip.show(targetWindowID: target, anchorPID: anchorPID)
        relayout(animated: true, except: pip)
        restackAll()
        startFollowing()
    }

    func hideAll() {
        for pip in pips { pip.hide() }
        pips.removeAll()
        stopFollowing()
    }

    func hide(windowID: CGWindowID) {
        for pip in pips where pip.targetWindowID == windowID { pip.hide() }
    }

    func didHide(_ pip: PiPWindowController) {
        let wasFront = depth(for: pip) == 0
        pips.removeAll { $0 === pip }
        zOrder.removeAll { $0 == ObjectIdentifier(pip) }
        _ = wasFront
        relayout(animated: true)
        restackAll()
        if pips.isEmpty { stopFollowing() }
    }

    /// Cards in the same deck (same caller, same corner), back to front.
    private func group(of pip: PiPWindowController) -> [PiPWindowController] {
        pips.filter { $0.corner == pip.corner && $0.anchorPID == pip.anchorPID }
    }

    /// 0 for the front card, 1 for the one right behind it, and so on.
    func depth(for pip: PiPWindowController) -> Int {
        let deck = group(of: pip)
        guard let index = deck.firstIndex(where: { $0 === pip }) else { return 0 }
        return deck.count - 1 - index
    }

    /// The front card's size; back cards are laid out relative to it.
    func frontSize(for pip: PiPWindowController) -> CGSize? {
        group(of: pip).last?.previewSize
    }

    func bringToFront(_ pip: PiPWindowController) {
        guard depth(for: pip) > 0 else { restackAll(); return }
        pips.removeAll { $0 === pip }
        pips.append(pip)
        // No pop: the clicked card turns invisible, moves to the front slot unseen, goes on top and fades
        // in there, while the old front card slides back into the deck underneath it.
        pip.beginFadeSwap()
        restackAll()
        relayout(animated: true, except: pip)
        pip.endFadeSwap()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pips.forEach { $0.verifyHover() }
        }
    }

    /// A card dropped on another corner becomes the front of that corner's deck.
    func moveToFront(_ pip: PiPWindowController, leaving previousCorner: PiPCorner) {
        pips.removeAll { $0 === pip }
        pips.append(pip)
        zOrder.removeAll { $0 == ObjectIdentifier(pip) }
        zOrder.append(ObjectIdentifier(pip))
    }

    func relayout(animated: Bool, except skipped: PiPWindowController? = nil) {
        for pip in pips {
            if !isTop(pip) {
                pip.setControlsVisible(false)
            }
            let level = min(depth(for: pip), Self.visibleDepth)
            pip.setBackDim(Float(level) * Self.dimPerLevel, animated: animated)
            if pip !== skipped && !pip.isDocked { pip.moveToSlot(animated: animated) }
        }
    }

    func notifyCursorMoved(to screenPoint: CGPoint, duration: Double) {
        for pip in pips where pip.isShowing {
            pip.notifyCursorMoved(to: screenPoint, duration: duration)
        }
    }

    func notifyCursorClicked(at screenPoint: CGPoint, button: String) {
        for pip in pips where pip.isShowing {
            pip.notifyCursorClicked(at: screenPoint, button: button)
        }
    }

    func notifyCursorHidden() {
        for pip in pips where pip.isShowing {
            pip.notifyCursorHidden()
        }
    }

    func dockFront(side: PiPDockSide) {
        if let top = pips.last(where: { $0.isShowing && !$0.isDocked }) {
            top.dock(to: side)
        }
    }

    func undockAll() {
        for pip in pips where pip.isShowing && pip.isDocked {
            pip.undock()
        }
    }

    /// For each caller: its PiPs right above the caller window, back cards first, front cards on top.
    func restackAll() {
        let groups = Dictionary(grouping: pips.filter { $0.isShowing }) { $0.anchorPID ?? -1 }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for (pid, group) in groups {
            let ordered = group.sorted { zIndex($0) < zIndex($1) }   // back ... front

            // Caller app in use: float above everything it has, so clicking/navigating inside it can never
            // cover the PiPs (the cause of the flicker). Otherwise sit in the normal stack right above the
            // caller window, so other apps cover the PiPs together with it.
            let callerActive = pid == -1 || pid == frontmostPID
            if callerActive {
                for pip in ordered {
                    pip.setLevel(.floating)
                    pip.orderFront()
                }
                continue
            }

            guard let anchor = PiPWindowController.frontWindow(of: pid) else { continue }
            _ = anchor
            for pip in ordered {
                pip.setLevel(.floating)
                pip.orderFront()
            }
        }
    }

    private func startFollowing() {
        guard followTimer == nil else { return }
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            var moved = false
            for pip in self.pips {
                moved = pip.anchorMoved() || moved
                pip.verifyHover()
            }
            if moved { self.relayout(animated: false) }
            self.restackAll()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown]
        let update: (NSEvent) -> Void = { [weak self] event in
            // Where this event happened, in screen coordinates.
            let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
            self?.pips.forEach { $0.updateMousePassThrough(at: point) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: update) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { update($0); return $0 }) { mouseMonitors.append(local) }
    }

    private func stopFollowing() {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
        followTimer?.invalidate()
        followTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func appActivated(_ note: Notification) {
        // React right away when focus changes instead of waiting for the next follow tick.
        restackAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.restackAll() }
    }
}

/// One floating live preview, pinned to a corner of the app that invoked `mcu pip show`.
final class PiPWindowController: PiPInteractionDelegate {
    private static let inset: CGFloat = 14
    private static let minWidth: CGFloat = 200

    private weak var manager: PiPManager?
    private var panel: NSPanel?
    private var pipView: HoverPiPView?
    private var captureTimer: Timer?
    private var liveStream: PiPStream?
    private var captureInFlight = false
    private(set) var targetWindowID: CGWindowID?
    private(set) var anchorPID: pid_t?
    private(set) var corner: PiPCorner = .topRight
    private(set) var previewSize = CGSize(width: 280, height: 175)
    private var aspect: CGFloat = 0.625
    private var lastAnchor: CGRect = .zero
    private var interactionStartFrame: CGRect = .zero
    private(set) var interacting = false
    private var snapTimer: Timer?
    private(set) var isShowing = false
    private(set) var dockSide: PiPDockSide? = nil
    var isDocked: Bool { dockSide != nil }
    private var preDockFrame: CGRect?

    init(manager: PiPManager) { self.manager = manager }

    var pinnedCorner: PiPCorner { corner }
    var isFrontmost: Bool { manager?.isTop(self) ?? true }
    var windowNumber: Int { panel?.windowNumber ?? 0 }

    func animateRaise() {
        pipView?.animateRaise()
    }

    func setControlsVisible(_ visible: Bool) {
        pipView?.setControlsVisible(visible)
    }

    func show(targetWindowID: CGWindowID?, anchorPID: pid_t?) {
        self.targetWindowID = targetWindowID
        self.anchorPID = anchorPID

        let initial = targetWindowID.flatMap(Self.capture(windowID:))
        var targetWidth: CGFloat = 1100
        var targetHeight: CGFloat = 700
        if let wid = targetWindowID,
           let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
           let info = list.first,
           let dict = info[kCGWindowBounds as String] as? NSDictionary,
           let bounds = CGRect(dictionaryRepresentation: dict),
           bounds.width > 50, bounds.height > 50 {
            targetWidth = bounds.width
            targetHeight = bounds.height
        } else if let initial {
            targetWidth = CGFloat(initial.width) / 2.0
            targetHeight = CGFloat(initial.height) / 2.0
        }
        aspect = targetHeight / max(targetWidth, 1)

        // Every PiP is sized proportionally to its own target window (never forced to equal dimensions),
        // pinned to the caller's top-right corner with cascading offsets.
        let anchor = anchorRect()
        lastAnchor = anchor
        corner = .topRight
        var width = targetWidth * 0.27
        let maxWidth = min(anchor.width * 0.45, 500)
        let minWidth = max(anchor.width * 0.16, 220)
        width = min(max(width, minWidth), maxWidth)
        var height = width * aspect
        let maxHeight = anchor.height * 0.52
        if height > maxHeight {
            height = maxHeight
            width = height / max(aspect, 0.2)
        }
        previewSize = CGSize(width: round(width), height: round(height))

        let panel = makePanel()
        self.panel = panel
        let frame = slotFrame()
        let view = HoverPiPView(frame: NSRect(origin: .zero, size: frame.size), image: initial)
        view.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
        view.interactionDelegate = self
        view.onEmergencyClose = { [weak self] in self?.hide() }
        view.onDismiss = { [weak self] in
            guard let self = self else { return }
            self.dock(to: self.corner.isLeft ? .left : .right)
        }
        view.onUndock = { [weak self] in self?.undock() }
        view.onActivateTarget = { [weak self] in self?.activateTarget() }
        pipView = view
        panel.contentView = view
        panel.setFrame(frame, display: true)

        isShowing = true
        panel.alphaValue = 0
        if anchorPID != nil { panel.orderBack(nil) } else { panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 1
        }

        startCapture()
    }

    /// Live capture through ScreenCaptureKit: real-time frames, and macOS marks the captured window/app with
    /// its screen-recording indicator, the same way Codex's computer use does. Falls back to periodic
    /// `screencapture` stills if the stream can't start.
    private func startCapture() {
        guard let wid = targetWindowID else { return }
        let stream = PiPStream(windowID: wid)
        stream.onFrame = { [weak self] frame in
            guard let self, self.isShowing else { return }
            self.pipView?.updatePreview(with: frame)
        }
        stream.onFailure = { [weak self] in
            guard let self, self.isShowing, self.captureTimer == nil else { return }
            self.liveStream = nil
            self.captureTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                self?.updateCapture()
            }
        }
        liveStream = stream
        stream.start()
    }

    func hide() {
        guard isShowing, let panel else { return }
        isShowing = false
        captureTimer?.invalidate()
        captureTimer = nil
        liveStream?.stop()
        liveStream = nil
        snapTimer?.invalidate()
        manager?.didHide(self)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    func orderFront() { panel?.orderFrontRegardless() }
    func verifyHover() { pipView?.verifyHover() }
    /// The card as it is on screen right now (mid-animation included).
    func hoverFrame() -> CGRect { currentPreviewFrame() }
    func order(above windowNumber: Int) { panel?.order(.above, relativeTo: windowNumber) }
    func setBackDim(_ value: Float, animated: Bool) { pipView?.setBackDim(value, animated: animated) }
    var level: NSWindow.Level { panel?.level ?? .normal }
    func setLevel(_ level: NSWindow.Level) {
        guard let panel, panel.level != level else { return }
        panel.level = level
    }

    private func makePanel() -> NSPanel {
        let panel = PiPPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Normal level: PiPs live in the regular window stack, right above their caller (see restackAll()).
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    /// Double-click: bring the previewed window (and its app) to the front.
    private func activateTarget() {
        guard let wid = targetWindowID,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
              let pid = list.first?[kCGWindowOwnerPID as String] as? pid_t else { return }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            for window in windows {
                var id: CGWindowID = 0
                if _AXUIElementGetWindow(window, &id) == .success, id == wid {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    break
                }
            }
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    // MARK: Geometry

    /// Where this PiP's preview belongs. PiPs on the same corner cascade like windows: the oldest sits in the
    /// caller's corner, each newer one shifted into the caller window by one step, so the PiPs behind show
    /// their top and side edges. Clicking one only raises it; nothing moves.
    private func previewFrame(in anchor: CGRect) -> CGRect {
        let inset = Self.inset
        let size = previewSize
        let step = CGFloat(manager?.cascadeIndex(for: self) ?? 0)
        let dx = PiPManager.cascadeStep.dx * step
        let dy = PiPManager.cascadeStep.dy * step
        let x = corner.isLeft ? anchor.minX + inset + dx : anchor.maxX - inset - size.width - dx
        let y = corner.isTop ? anchor.maxY - inset - size.height - dy : anchor.minY + inset + dy
        return CGRect(origin: CGPoint(x: x, y: y), size: size).integral
    }

    func slotFrame() -> CGRect { panelFrame(for: previewFrame(in: lastAnchor)) }

    private func panelFrame(for preview: CGRect) -> CGRect {
        let m = HoverPiPView.margin
        return CGRect(x: preview.minX - m.left, y: preview.minY - m.bottom,
                      width: preview.width + m.left + m.right, height: preview.height + m.top + m.bottom)
    }

    private func currentPreviewFrame() -> CGRect {
        guard let panel else { return .zero }
        let m = HoverPiPView.margin
        let f = panel.frame
        return CGRect(x: f.minX + m.left, y: f.minY + m.bottom,
                      width: f.width - m.left - m.right, height: f.height - m.top - m.bottom)
    }

    /// Frontmost on-screen window of the calling app, in Cocoa screen coordinates.
    private func anchorRect() -> CGRect {
        if let pid = anchorPID, let window = Self.frontWindow(of: pid) { return window.rect }
        return (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Re-reads the caller window's frame; true if it moved or resized.
    func anchorMoved() -> Bool {
        guard isShowing else { return false }
        let anchor = anchorRect()
        guard anchor != lastAnchor else { return false }
        lastAnchor = anchor
        return true
    }

    /// Glides (or jumps) to this PiP's slot. Skipped while the user is dragging it or docked.
    func moveToSlot(animated: Bool) {
        guard isShowing, !interacting, !isDocked, let panel else { return }
        let target = slotFrame()
        guard target != panel.frame else { return }
        guard animated else { snapTimer?.invalidate(); setPanelFrame(target); return }
        animate(to: target, completion: nil)
    }

    private func animate(to target: CGRect, completion: (() -> Void)?) {
        guard let panel else { return }
        // Frame-by-frame through setPanelFrame, so the content stays locked to the window the whole way.
        let start = panel.frame
        let begin = CACurrentMediaTime()
        let duration = 0.22
        snapTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, (CACurrentMediaTime() - begin) / duration)
            let e = CGFloat(1 - pow(1 - t, 3))
            func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * e }
            self.setPanelFrame(CGRect(x: lerp(start.minX, target.minX), y: lerp(start.minY, target.minY),
                                      width: lerp(start.width, target.width), height: lerp(start.height, target.height)).integral)
            if t >= 1 {
                timer.invalidate()
                self.setPanelFrame(target)
                completion?()
            }
        }
        snapTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: PiPInteractionDelegate

    func pipInteractionBegan(_ kind: PiPInteraction) {
        snapTimer?.invalidate()
        interacting = true
        interactionStartFrame = currentPreviewFrame()
    }

    func pipInteractionChanged(_ kind: PiPInteraction, delta: CGVector) {
        let start = interactionStartFrame
        switch kind {
        case .move:
            setPanelFrame(panelFrame(for: start.offsetBy(dx: delta.dx, dy: delta.dy)))
        case .resize(let dragged):
            // The pinned corner stays put; the size follows the pointer along the axes the dragged corner can move.
            let pinned = corner
            let outX = dragged.isLeft ? -delta.dx : delta.dx
            let outY = (dragged.isTop ? delta.dy : -delta.dy) / max(aspect, 0.2)
            var candidates: [CGFloat] = []
            if dragged.isLeft != pinned.isLeft { candidates.append(start.width + outX) }
            if dragged.isTop != pinned.isTop { candidates.append(start.width + outY) }
            let maxWidth = max(Self.minWidth, min(lastAnchor.width - 2 * Self.inset, 1100))
            let width = round(min(max(candidates.max() ?? start.width, Self.minWidth), maxWidth))
            let size = CGSize(width: width, height: round(width * aspect))
            let x = pinned.isLeft ? start.minX : start.maxX - size.width
            let y = pinned.isTop ? start.maxY - size.height : start.minY
            previewSize = size
            setPanelFrame(panelFrame(for: CGRect(origin: CGPoint(x: x, y: y), size: size)))
            // PiPs stacked after this one follow the new height live.
            manager?.relayout(animated: false, except: self)
        }
    }

    func beginFadeSwap() {
        guard let panel else { return }
        snapTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = 0
        }
        panel.alphaValue = 0
        setPanelFrame(slotFrame())
    }

    func endFadeSwap() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func pipRequestFront() {
        manager?.raise(self)
    }

    /// Lets clicks through everywhere except over the preview itself (the shadow/blur margin would otherwise
    /// swallow clicks meant for the card peeking out underneath).
    func updateMousePassThrough(at point: NSPoint) {
        guard let panel, isShowing else { return }
        if interacting { panel.ignoresMouseEvents = false; return }
        let hit = currentPreviewFrame().insetBy(dx: -6, dy: -6).contains(point)
        if panel.ignoresMouseEvents == hit { panel.ignoresMouseEvents = !hit }
    }

    func pipInteractionEnded(_ kind: PiPInteraction) {
        let anchor = anchorRect()
        lastAnchor = anchor
        if case .move = kind {
            let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let frame = currentPreviewFrame()

            // Live Edge Docking (Feature 3): if released near or beyond left/right display edge
            if frame.midX < screen.minX + 80 || frame.minX < screen.minX - 20 {
                dock(to: .left)
                return
            } else if frame.midX > screen.maxX - 80 || frame.maxX > screen.maxX + 20 {
                dock(to: .right)
                return
            }

            // Snap to whichever corner of the caller window is closest; join the end of that corner's stack.
            let newCorner: PiPCorner
            switch (frame.midX < anchor.midX, frame.midY > anchor.midY) {
            case (true, true): newCorner = .topLeft
            case (false, true): newCorner = .topRight
            case (true, false): newCorner = .bottomLeft
            case (false, false): newCorner = .bottomRight
            }
            if newCorner != corner {
                let previousCorner = corner
                corner = newCorner
                manager?.moveToFront(self, leaving: previousCorner)
            }
        }
        manager?.relayout(animated: true, except: self)
        guard let panel, slotFrame() != panel.frame else {
            interacting = false
            manager?.restackAll()
            return
        }
        animate(to: slotFrame()) { [weak self] in
            self?.interacting = false
            self?.manager?.restackAll()
        }
    }

    /// Resizes the window and lays out its layers in the same Core Animation commit. Without this the window
    /// server shows the new window size a frame before the layers catch up, and the preview slides/lags.
    private func setPanelFrame(_ frame: CGRect) {
        guard let panel else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: false)
        if let view = pipView {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
        panel.displayIfNeeded()
        CATransaction.commit()
        CATransaction.flush()
    }

    // MARK: - Live Edge Docking (Feature 3)

    func dock(to side: PiPDockSide) {
        guard let panel, isShowing else { return }
        dockSide = side
        preDockFrame = panel.frame
        pipView?.setDocked(true, side: side)

        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let curPreview = currentPreviewFrame()
        let tabVisibleWidth: CGFloat = 36.0

        let dockedY = min(max(curPreview.minY, screen.minY + 20), screen.maxY - curPreview.height - 20)
        let targetPreviewX: CGFloat
        switch side {
        case .left:
            targetPreviewX = screen.minX + tabVisibleWidth - curPreview.width
        case .right:
            targetPreviewX = screen.maxX - tabVisibleWidth
        }

        let targetPreview = CGRect(x: targetPreviewX, y: dockedY, width: curPreview.width, height: curPreview.height)
        let targetPanelFrame = panelFrame(for: targetPreview)

        animate(to: targetPanelFrame) { [weak self] in
            self?.interacting = false
        }
    }

    func undock() {
        guard panel != nil, isShowing, isDocked else { return }
        dockSide = nil
        pipView?.setDocked(false, side: nil)

        let targetFrame = preDockFrame ?? slotFrame()
        preDockFrame = nil
        animate(to: targetFrame) { [weak self] in
            guard let self = self else { return }
            self.interacting = false
            self.manager?.relayout(animated: true)
            self.manager?.restackAll()
        }
    }

    // MARK: - Agent Action Mirroring (Feature 1)

    func targetWindowBounds() -> CGRect? {
        guard let wid = targetWindowID,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
              let info = list.first,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict),
              bounds.width > 20, bounds.height > 20 else { return nil }
        return bounds
    }

    func notifyCursorMoved(to screenPoint: CGPoint, duration: Double) {
        guard isShowing, !isDocked, let bounds = targetWindowBounds() else {
            pipView?.mirrorCursorExited()
            return
        }
        let extended = bounds.insetBy(dx: -40, dy: -40)
        if extended.contains(screenPoint) {
            let clampedX = min(max(screenPoint.x, bounds.minX), bounds.maxX)
            let clampedY = min(max(screenPoint.y, bounds.minY), bounds.maxY)
            let nx = (clampedX - bounds.minX) / max(1.0, bounds.width)
            let ny = (clampedY - bounds.minY) / max(1.0, bounds.height)
            pipView?.mirrorCursorMoved(normalizedX: nx, normalizedY: ny, duration: duration)
        } else {
            pipView?.mirrorCursorExited()
        }
    }

    func notifyCursorClicked(at screenPoint: CGPoint, button: String) {
        guard isShowing, !isDocked, let bounds = targetWindowBounds() else { return }
        let extended = bounds.insetBy(dx: -40, dy: -40)
        if extended.contains(screenPoint) {
            let clampedX = min(max(screenPoint.x, bounds.minX), bounds.maxX)
            let clampedY = min(max(screenPoint.y, bounds.minY), bounds.maxY)
            let nx = (clampedX - bounds.minX) / max(1.0, bounds.width)
            let ny = (clampedY - bounds.minY) / max(1.0, bounds.height)
            pipView?.mirrorCursorClicked(normalizedX: nx, normalizedY: ny, button: button)
        }
    }

    func notifyCursorHidden() {
        pipView?.mirrorCursorExited()
    }

    // MARK: Capture

    private func updateCapture() {
        guard isShowing, !captureInFlight, let wid = targetWindowID else { return }
        captureInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = Self.capture(windowID: wid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.captureInFlight = false
                if let image, self.isShowing { self.pipView?.updatePreview(with: image) }
            }
        }
    }

    private static func capture(windowID: CGWindowID) -> CGImage? {
        let path = NSTemporaryDirectory() + "mcu_pip_capture_\(windowID).png"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l\(windowID)", path]
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func firstWindowID(matchingApp name: String) -> CGWindowID? {
        for window in getWindowsList(allLayers: false) {
            let owner = window["app"] as? String ?? ""
            if owner.localizedCaseInsensitiveContains(name), let id = window["id"] as? Int {
                return CGWindowID(id)
            }
        }
        return nil
    }

    /// Frontmost sizeable window of `pid`: its id and frame in Cocoa screen coordinates.
    static func frontWindow(of pid: pid_t) -> (id: CGWindowID, rect: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 240, bounds.height >= 180 else { continue }
            return (id, CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height))
        }
        return nil
    }

    /// Window ids of normal-layer on-screen windows, front to back.
    static func windowStack(allLayers: Bool = false) -> [CGWindowID] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            allLayers || (info[kCGWindowLayer as String] as? Int) == 0 ? info[kCGWindowNumber as String] as? CGWindowID : nil
        }
    }
}

// MARK: - Actual macOS Virtual Cursor Daemon (Floating Click-Through Arrow)

class FlippedView: NSView {
    override var isFlipped: Bool { return true }
}

class FancyCursorDaemon {
    var panel: NSPanel!
    var rootLayer: CALayer!
    var cursorContainerLayer: CALayer!
    var cursorImageLayer: CALayer!
    var idleTimer: Timer?
    var screenHeight: CGFloat = 1329.0
    var pipManager: PiPManager?
    
    // Smooth 60fps movement animation properties
    var animTimer: Timer?
    var animStartTime: Date?
    var animStartPoint: NSPoint = .zero
    var animTargetPoint: NSPoint = .zero
    var animDuration: Double = 0.50
    
    // Natural compact cursor dimensions (scaled from user's untouched 1024x1001 image)
    let panelSize: CGFloat = 48.0
    let cursorAssetWidth: CGFloat = 19.0
    var cursorAssetHeight: CGFloat { cursorAssetWidth * (1001.0 / 1024.0) } // ~18.57 pt
    
    // Generous transparent margin so cursor is centered and NEVER clipped by panel borders
    let assetMargin: CGFloat = 14.0
    
    // Exact tip coordinate in untouched 1024x1001 image: (208, 194)
    var tipInAssetX: CGFloat { 208.0 * (cursorAssetWidth / 1024.0) } // ~3.86 pt
    var tipInAssetY: CGFloat { 194.0 * (cursorAssetHeight / 1001.0) } // ~3.60 pt
    
    var tipOffsetX: CGFloat { assetMargin + tipInAssetX } // ~17.86 pt
    var tipOffsetY: CGFloat { assetMargin + tipInAssetY } // ~17.60 pt
    
    func start() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        
        if let mainScreen = NSScreen.main {
            screenHeight = mainScreen.frame.height
        }
        
        let initialX: CGFloat = 600.0
        let initialY: CGFloat = 400.0
        let panelOriginX = initialX - tipOffsetX
        let panelOriginY = screenHeight - initialY - panelSize + tipOffsetY
        
        panel = PiPPanel(
            contentRect: NSRect(x: panelOriginX, y: panelOriginY, width: panelSize, height: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        let customView = FlippedView(frame: NSRect(x: 0, y: 0, width: panelSize, height: panelSize))
        customView.wantsLayer = true
        panel.contentView = customView
        rootLayer = customView.layer!
        
        pipManager = PiPManager()
        
        setupActualCursorVisuals()
        registerNotifications()
        resetIdleTimer()
        
        panel.orderFrontRegardless()
        print("Compact Delta Cursor Daemon active (Untouched 19pt asset, Smooth 60fps glide, zero clipping, PiP oversight enabled).")
        app.run()
    }
    
    func setupActualCursorVisuals() {
        cursorContainerLayer = CALayer()
        cursorContainerLayer.bounds = CGRect(x: 0, y: 0, width: cursorAssetWidth, height: cursorAssetHeight)
        cursorContainerLayer.anchorPoint = CGPoint(x: tipInAssetX / cursorAssetWidth, y: tipInAssetY / cursorAssetHeight)
        cursorContainerLayer.position = CGPoint(x: tipOffsetX, y: tipOffsetY)
        
        cursorImageLayer = CALayer()
        cursorImageLayer.frame = CGRect(x: 0, y: 0, width: cursorAssetWidth, height: cursorAssetHeight)
        
        let assetPaths = [
            kMCURootDirectory + "/resources/cursor.png",
            NSHomeDirectory() + "/.config/macos-computer-use/resources/cursor.png",
            NSHomeDirectory() + "/.gemini/config/skills/macos-computer-use/resources/cursor.png"
        ]
        
        var loaded = false
        for p in assetPaths {
            if let img = NSImage(contentsOfFile: p),
               let cgImg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                cursorImageLayer.contents = cgImg
                cursorImageLayer.contentsGravity = .resizeAspect
                loaded = true
                break
            }
        }
        
        if !loaded {
            let shape = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 4, y: 3))
            path.addLine(to: CGPoint(x: 16, y: 8))
            path.addLine(to: CGPoint(x: 11, y: 11))
            path.addLine(to: CGPoint(x: 8, y: 16))
            path.closeSubpath()
            shape.path = path
            shape.fillColor = NSColor.black.cgColor
            shape.strokeColor = NSColor.white.cgColor
            shape.lineWidth = 1.5
            shape.lineJoin = .round
            cursorImageLayer.addSublayer(shape)
        }
        
        cursorContainerLayer.addSublayer(cursorImageLayer)
        rootLayer.addSublayer(cursorContainerLayer)
    }
    
    func registerNotifications() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kCursorNotificationName),
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self = self,
                  let info = notif.userInfo as? [String: Any],
                  let action = info["action"] as? String else { return }
            
            if action != "done" {
                self.resetIdleTimer()
            }
            
            // Bring cursor to front if moving or clicking
            if (action == "move" || action == "click" || action == "show") && self.panel.alphaValue < 1.0 {
                self.panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    self.panel.animator().alphaValue = 1.0
                }
            }
            
            switch action {
            case "move":
                if let x = info["x"] as? Double, let y = info["y"] as? Double {
                    let speed = info["speed"] as? String
                    let dur = info["duration"] as? Double
                    self.moveTo(x: CGFloat(x), y: CGFloat(y), smooth: true, speed: speed, duration: dur)
                }
            case "click":
                if let x = info["x"] as? Double, let y = info["y"] as? Double {
                    let btn = info["button"] as? String ?? "left"
                    self.triggerClickAction(x: CGFloat(x), y: CGFloat(y), button: btn)
                }
            case "pip_show":
                let app = info["app"] as? String
                let wid = (info["windowID"] as? Int).map { CGWindowID($0) }
                let anchor = (info["anchorPID"] as? Int).map { pid_t($0) }
                self.pipManager?.show(appName: app, windowID: wid, anchorPID: anchor)
            case "pip_dock":
                let sideStr = info["side"] as? String ?? "right"
                let side: PiPDockSide = (sideStr == "left") ? .left : .right
                self.pipManager?.dockFront(side: side)
            case "pip_undock":
                self.pipManager?.undockAll()
            case "pip_hide":
                if let wid = info["windowID"] as? Int {
                    self.pipManager?.hide(windowID: CGWindowID(wid))
                } else {
                    self.pipManager?.hideAll()
                }
            case "done":
                self.idleTimer?.invalidate()
                self.idleTimer = nil
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    self.panel.animator().alphaValue = 0.0
                }, completionHandler: {
                    self.panel.orderOut(nil)
                })
                self.pipManager?.notifyCursorHidden()
                self.pipManager?.hideAll()
            case "hide":
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.20
                    self.panel.animator().alphaValue = 0.0
                }
                self.pipManager?.notifyCursorHidden()
            case "show":
                self.panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.20
                    self.panel.animator().alphaValue = 1.0
                }
            case "stop":
                self.pipManager?.hideAll()
                exit(0)
            default:
                break
            }
        }
    }
    
    func moveTo(x: CGFloat, y: CGFloat, smooth: Bool = true, speed: String? = nil, duration: Double? = nil) {
        if let mainScreen = NSScreen.main {
            screenHeight = mainScreen.frame.height
        }
        let panelOriginX = x - tipOffsetX
        let panelOriginY = screenHeight - y - panelSize + tipOffsetY
        let target = NSPoint(x: panelOriginX, y: panelOriginY)
        
        animTimer?.invalidate()
        animTimer = nil
        
        if !smooth {
            panel.setFrameOrigin(target)
            pipManager?.notifyCursorMoved(to: CGPoint(x: x, y: y), duration: 0.05)
            return
        }
        
        let start = panel.frame.origin
        let dist = hypot(target.x - start.x, target.y - start.y)
        if dist < 2.0 {
            panel.setFrameOrigin(target)
            pipManager?.notifyCursorMoved(to: CGPoint(x: x, y: y), duration: 0.03)
            return
        }
        
        animStartTime = Date()
        animStartPoint = start
        animTargetPoint = target
        
        // Slower, graceful, clearly visible 60fps glide
        if let d = duration, d > 0 {
            animDuration = d
        } else if let s = speed {
            switch s.lowercased() {
            case "slow":
                animDuration = min(1.8, max(0.80, Double(dist) / 350.0))
            case "fast":
                animDuration = min(0.5, max(0.20, Double(dist) / 1200.0))
            case "instant":
                panel.setFrameOrigin(target)
                pipManager?.notifyCursorMoved(to: CGPoint(x: x, y: y), duration: 0.03)
                return
            default: // "normal"
                animDuration = min(1.2, max(0.45, Double(dist) / 600.0))
            }
        } else {
            animDuration = min(1.2, max(0.45, Double(dist) / 600.0))
        }
        
        // Forward virtual cursor projection to PiP previews
        pipManager?.notifyCursorMoved(to: CGPoint(x: x, y: y), duration: animDuration)
        
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] timer in
            guard let self = self, let sTime = self.animStartTime else {
                timer.invalidate()
                return
            }
            let elapsed = Date().timeIntervalSince(sTime)
            let progress = min(1.0, elapsed / self.animDuration)
            let ease = (1.0 - cos(progress * .pi)) / 2.0
            
            let cx = self.animStartPoint.x + (self.animTargetPoint.x - self.animStartPoint.x) * ease
            let cy = self.animStartPoint.y + (self.animTargetPoint.y - self.animStartPoint.y) * ease
            self.panel.setFrameOrigin(NSPoint(x: cx, y: cy))
            self.panel.displayIfNeeded()
            
            if progress >= 1.0 {
                self.panel.setFrameOrigin(self.animTargetPoint)
                timer.invalidate()
                self.animTimer = nil
            }
        }
        if let timer = animTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    func triggerClickAction(x: CGFloat, y: CGFloat, button: String) {
        moveTo(x: x, y: y, smooth: false)
        
        // Forward virtual click ripple to PiP previews
        pipManager?.notifyCursorClicked(at: CGPoint(x: x, y: y), button: button)
        
        // Tactile cursor press animation (compresses towards tip)
        let press = CABasicAnimation(keyPath: "transform.scale")
        press.fromValue = 1.0
        press.toValue = 0.88
        press.duration = 0.07
        press.autoreverses = true
        press.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cursorContainerLayer.add(press, forKey: "clickPress")
        
        // Subtle compact ripple at exact tip
        let ripple = CALayer()
        let rSize: CGFloat = 10.0
        ripple.frame = CGRect(x: tipOffsetX - rSize / 2.0, y: tipOffsetY - rSize / 2.0, width: rSize, height: rSize)
        ripple.cornerRadius = rSize / 2.0
        
        let ringColor = (button == "right") ?
            NSColor.systemOrange.cgColor :
            NSColor.white.withAlphaComponent(0.85).cgColor
        
        ripple.borderColor = ringColor
        ripple.borderWidth = 1.5
        rootLayer.addSublayer(ripple)
        
        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 0.4
        scaleAnim.toValue = 2.2
        
        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = 0.9
        fadeAnim.toValue = 0.0
        
        let group = CAAnimationGroup()
        group.animations = [scaleAnim, fadeAnim]
        group.duration = 0.22
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        
        ripple.add(group, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            ripple.removeFromSuperlayer()
        }
    }
    
    func resetIdleTimer() {
        idleTimer?.invalidate()
        // Virtual Cursor Idle Fade: If no cursor movement arrives within 5.0 seconds,
        // fade out the cursor overlay so it doesn't obstruct the user.
        // NOTE: PiP live preview windows remain pinned and active for persistent oversight
        // until explicitly closed with 'mcu pip hide' or 'mcu done'.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.panel.animator().alphaValue = 0.0
            }, completionHandler: {
                self.panel.orderOut(nil)
            })
            self.pipManager?.notifyCursorHidden()
        }
        
        if panel.alphaValue < 1.0 {
            panel.orderFrontRegardless()
            panel.alphaValue = 1.0
        }
    }
}

// MARK: - Screen Capture & Processing

func getScreenInfoJSON() -> String {
    var displaysList: [[String: Any]] = []
    var displayCount: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &displayCount)
    var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)
    
    let mainDisplay = CGMainDisplayID()
    let mousePos = CGEvent(source: nil)?.location ?? .zero
    
    for id in displayIDs {
        let bounds = CGDisplayBounds(id)
        let pixelsW = CGDisplayPixelsWide(id)
        let pixelsH = CGDisplayPixelsHigh(id)
        let scale = (bounds.width > 0) ? Double(pixelsW) / Double(bounds.width) : 1.0
        
        displaysList.append([
            "id": id,
            "isMain": id == mainDisplay,
            "bounds": [
                "x": bounds.origin.x, "y": bounds.origin.y,
                "width": bounds.size.width, "height": bounds.size.height
            ],
            "pixelDimensions": ["width": pixelsW, "height": pixelsH],
            "scaleFactor": scale
        ])
    }
    
    let result: [String: Any] = [
        "displays": displaysList,
        "mousePosition": ["x": mousePos.x, "y": mousePos.y]
    ]
    
    if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
       let str = String(data: data, encoding: .utf8) {
        return str
    }
    return "{}"
}

func captureScreen(output: String, scale1x: Bool, withGrid: Bool, windowID: CGWindowID?, rect: CGRect?, includeCursor: Bool) {
    let tmpFile = "/tmp/mcu_raw_capture_\(ProcessInfo.processInfo.processIdentifier).png"
    var args = ["-x"]
    if includeCursor { args.append("-C") }
    if let wid = windowID {
        args.append(contentsOf: ["-o", "-l\(wid)"])
    } else if let r = rect {
        args.append("-R\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.size.width)),\(Int(r.size.height))")
    } else {
        args.append("-m")
    }
    args.append(tmpFile)
    
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = args
    try? task.run()
    task.waitUntilExit()
    
    defer { try? FileManager.default.removeItem(atPath: tmpFile) }
    
    guard FileManager.default.fileExists(atPath: tmpFile),
          let imgSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: tmpFile) as CFURL, nil),
          let rawImg = CGImageSourceCreateImageAtIndex(imgSource, 0, nil) else {
        fputs("Error: screencapture failed to generate image\n", stderr)
        exit(1)
    }
    
    let scale = NSScreen.main?.backingScaleFactor ?? 2.0
    let targetWidth = scale1x ? Int(Double(rawImg.width) / scale) : rawImg.width
    let targetHeight = scale1x ? Int(Double(rawImg.height) / scale) : rawImg.height
    
    if !scale1x && !withGrid {
        try? FileManager.default.removeItem(atPath: output)
        try? FileManager.default.copyItem(atPath: tmpFile, toPath: output)
        print("Captured screenshot directly: \(output) (\(rawImg.width)x\(rawImg.height)px)")
        return
    }
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: targetWidth,
        height: targetHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("Error: Failed to create CoreGraphics context\n", stderr)
        exit(1)
    }
    
    context.interpolationQuality = .high
    context.draw(rawImg, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    
    if withGrid {
        let minorStep: CGFloat = scale1x ? 50.0 : 50.0 * scale
        let majorStep: CGFloat = scale1x ? 100.0 : 100.0 * scale
        let superStep: CGFloat = scale1x ? 500.0 : 500.0 * scale
        
        context.setStrokeColor(CGColor(red: 0.0, green: 0.8, blue: 1.0, alpha: 0.2))
        context.setLineWidth(1.0)
        for x in stride(from: minorStep, to: CGFloat(targetWidth), by: minorStep) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: CGFloat(targetHeight)))
        }
        for y in stride(from: minorStep, to: CGFloat(targetHeight), by: minorStep) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: CGFloat(targetWidth), y: y))
        }
        context.strokePath()
        
        context.setStrokeColor(CGColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 0.45))
        context.setLineWidth(1.5)
        for x in stride(from: majorStep, to: CGFloat(targetWidth), by: majorStep) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: CGFloat(targetHeight)))
        }
        for y in stride(from: majorStep, to: CGFloat(targetHeight), by: majorStep) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: CGFloat(targetWidth), y: y))
        }
        context.strokePath()
        
        context.setStrokeColor(CGColor(red: 1.0, green: 0.3, blue: 0.1, alpha: 0.75))
        context.setLineWidth(2.0)
        for x in stride(from: superStep, to: CGFloat(targetWidth), by: superStep) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: CGFloat(targetHeight)))
        }
        for y in stride(from: superStep, to: CGFloat(targetHeight), by: superStep) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: CGFloat(targetWidth), y: y))
        }
        context.strokePath()
        
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, scale1x ? 11 : 18, nil)
        let labelAttr: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 0, alpha: 1)
        ]
        
        for x in stride(from: majorStep, to: CGFloat(targetWidth) - 40, by: majorStep) {
            let labelText = "\(Int(scale1x ? x : x / scale))"
            let attrStr = CFAttributedStringCreate(nil, labelText as CFString, labelAttr as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attrStr)
            
            context.saveGState()
            context.translateBy(x: x + 4, y: scale1x ? 18 : 30)
            context.scaleBy(x: 1.0, y: -1.0)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        
        for y in stride(from: majorStep, to: CGFloat(targetHeight) - 20, by: majorStep) {
            let labelText = "\(Int(scale1x ? y : y / scale))"
            let attrStr = CFAttributedStringCreate(nil, labelText as CFString, labelAttr as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attrStr)
            
            context.saveGState()
            context.translateBy(x: 4, y: y + (scale1x ? 14 : 22))
            context.scaleBy(x: 1.0, y: -1.0)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
    
    guard let outputImg = context.makeImage() else {
        fputs("Error: Failed to finalize CoreGraphics image\n", stderr)
        exit(1)
    }
    
    let destURL = URL(fileURLWithPath: output) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(destURL, "public.png" as CFString, 1, nil) else {
        fputs("Error: Failed to create image destination for \(output)\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(dest, outputImg, nil)
    CGImageDestinationFinalize(dest)
    print("Screenshot saved to \(output) (\(targetWidth)x\(targetHeight) \(scale1x ? "points 1:1" : "pixels"))")
}

// MARK: - Window Inspection & Management

func getWindowsList(allLayers: Bool) -> [[String: Any]] {
    let options: CGWindowListOption = allLayers ? [.excludeDesktopElements] : [.excludeDesktopElements, .optionOnScreenOnly]
    guard let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    
    var windows: [[String: Any]] = []
    for info in windowListInfo {
        let layer = info[kCGWindowLayer as String] as? Int ?? -1
        if !allLayers && layer != 0 { continue }
        
        let wid = info[kCGWindowNumber as String] as? Int ?? 0
        let pid = info[kCGWindowOwnerPID as String] as? Int ?? 0
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        let name = info[kCGWindowName as String] as? String ?? ""
        let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let isMinimized = info[kCGWindowIsOnscreen as String] as? Bool == false
        
        let w = boundsDict["Width"] ?? 0
        let h = boundsDict["Height"] ?? 0
        if w < 20 || h < 20 { continue }
        
        windows.append([
            "id": wid,
            "pid": pid,
            "app": owner,
            "title": name,
            "layer": layer,
            "bounds": [
                "x": boundsDict["X"] ?? 0,
                "y": boundsDict["Y"] ?? 0,
                "width": w,
                "height": h
            ],
            "minimized": isMinimized
        ])
    }
    return windows
}

func focusTarget(_ query: String) -> Bool {
    let validation = AccessControlEngine.validate(action: "window_focus", targetApp: query)
    if !validation.allowed {
        fputs("\(validation.reason)\n", stderr)
        AccessControlEngine.logAudit(action: "window_focus", targetApp: query, decision: "BLOCKED", reason: validation.reason)
        return false
    }
    
    // 1. Try PID
    if let pid = Int32(query), let app = NSRunningApplication(processIdentifier: pid) {
        app.activate()
        AccessControlEngine.logAudit(action: "window_focus", targetApp: app.localizedName, details: "PID \(pid)")
        print("Focused app PID \(pid) (\(app.localizedName ?? ""))")
        return true
    }
    // 2. Try App Name
    let runningApps = NSWorkspace.shared.runningApplications
    for app in runningApps {
        if let name = app.localizedName, name.localizedCaseInsensitiveContains(query) {
            app.activate()
            AccessControlEngine.logAudit(action: "window_focus", targetApp: name, details: "PID \(app.processIdentifier)")
            print("Focused app '\(name)' (PID: \(app.processIdentifier))")
            return true
        }
    }
    // 3. Try Window ID
    if let wid = Int(query) {
        let windows = getWindowsList(allLayers: true)
        if let win = windows.first(where: { ($0["id"] as? Int) == wid }),
           let pid = win["pid"] as? Int32,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
            AccessControlEngine.logAudit(action: "window_focus", targetApp: win["app"] as? String, details: "Window ID \(wid)")
            print("Focused window [\(wid)] owned by \(win["app"] ?? "")")
            return true
        }
    }
    fputs("Error: Could not find target '\(query)'\n", stderr)
    return false
}

// MARK: - Accessibility (AXUIElement)

func getAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return err == .success ? value : nil
}

func getElementFrame(_ element: AXUIElement) -> CGRect? {
    var posVal: CFTypeRef?
    var sizeVal: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posVal)
    AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeVal)
    
    var pos = CGPoint.zero
    var size = CGSize.zero
    if let p = posVal, CFGetTypeID(p) == AXValueGetTypeID() {
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
    }
    if let s = sizeVal, CFGetTypeID(s) == AXValueGetTypeID() {
        AXValueGetValue(s as! AXValue, .cgSize, &size)
    }
    return CGRect(origin: pos, size: size)
}

func axElementToDict(_ el: AXUIElement, depth: Int, maxDepth: Int) -> [String: Any]? {
    let role = getAttribute(el, kAXRoleAttribute) as? String ?? ""
    let title = getAttribute(el, kAXTitleAttribute) as? String ?? ""
    let desc = getAttribute(el, kAXDescriptionAttribute) as? String ?? ""
    let val = getAttribute(el, kAXValueAttribute)
    let frame = getElementFrame(el) ?? .zero
    
    var dict: [String: Any] = [
        "role": role,
        "frame": [
            "x": frame.origin.x, "y": frame.origin.y,
            "width": frame.size.width, "height": frame.size.height
        ]
    ]
    if !title.isEmpty { dict["title"] = title }
    if !desc.isEmpty { dict["description"] = desc }
    if let v = val as? String, !v.isEmpty { dict["value"] = v }
    
    if depth < maxDepth {
        if let children = getAttribute(el, kAXChildrenAttribute) as? [AXUIElement], !children.isEmpty {
            var childDicts: [[String: Any]] = []
            for child in children {
                if let cd = axElementToDict(child, depth: depth + 1, maxDepth: maxDepth) {
                    childDicts.append(cd)
                }
            }
            if !childDicts.isEmpty { dict["children"] = childDicts }
        }
    }
    return dict
}

func findAXElementsRecursively(_ el: AXUIElement, roleFilter: String?, titleFilter: String?, containsText: String?, results: inout [[String: Any]], maxResults: Int = 20) {
    if results.count >= maxResults { return }
    let role = getAttribute(el, kAXRoleAttribute) as? String ?? ""
    let title = getAttribute(el, kAXTitleAttribute) as? String ?? ""
    let desc = getAttribute(el, kAXDescriptionAttribute) as? String ?? ""
    let val = getAttribute(el, kAXValueAttribute) as? String ?? ""
    let frame = getElementFrame(el) ?? .zero
    
    var matches = true
    if let rf = roleFilter, !rf.isEmpty {
        if !role.localizedCaseInsensitiveContains(rf) { matches = false }
    }
    if let tf = titleFilter, !tf.isEmpty {
        if !title.localizedCaseInsensitiveContains(tf) { matches = false }
    }
    if let cf = containsText, !cf.isEmpty {
        let combined = "\(title) \(desc) \(val)"
        if !combined.localizedCaseInsensitiveContains(cf) { matches = false }
    }
    
    if matches && (!role.isEmpty || !title.isEmpty) {
        var item: [String: Any] = [
            "role": role,
            "title": title,
            "frame": [
                "x": frame.origin.x, "y": frame.origin.y,
                "width": frame.size.width, "height": frame.size.height
            ],
            "center": [
                "x": frame.origin.x + frame.size.width / 2.0,
                "y": frame.origin.y + frame.size.height / 2.0
            ]
        ]
        if !desc.isEmpty { item["description"] = desc }
        if !val.isEmpty { item["value"] = val }
        results.append(item)
    }
    
    if let children = getAttribute(el, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children {
            findAXElementsRecursively(child, roleFilter: roleFilter, titleFilter: titleFilter, containsText: containsText, results: &results, maxResults: maxResults)
            if results.count >= maxResults { break }
        }
    }
}

func getAppElement(appName: String?, pid: Int32?) -> AXUIElement? {
    if let p = pid {
        return AXUIElementCreateApplication(p)
    }
    if let name = appName {
        let apps = NSWorkspace.shared.runningApplications
        if let target = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(name) == true }) {
            return AXUIElementCreateApplication(target.processIdentifier)
        }
    }
    if let front = NSWorkspace.shared.frontmostApplication {
        return AXUIElementCreateApplication(front.processIdentifier)
    }
    return nil
}

// MARK: - Non-Disruptive Input Simulation (Mouse & Keyboard)

func getMousePosition() -> CGPoint {
    return CGEvent(source: nil)?.location ?? .zero
}

func selectWordInBackground(pid: pid_t, at pt: CGPoint) {
    let appEl = AXUIElementCreateApplication(pid)
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(appEl, Float(pt.x), Float(pt.y), &el) == .success,
          let targetEl = el else { return }
    
    var point = pt
    guard let ptVal = AXValueCreate(.cgPoint, &point) else { return }
    var rangeVal: AnyObject?
    guard AXUIElementCopyParameterizedAttributeValue(targetEl, "AXRangeForPosition" as CFString, ptVal, &rangeVal) == .success,
          let rv = rangeVal else { return }
    
    var charRange = CFRange()
    guard AXValueGetValue(rv as! AXValue, .cfRange, &charRange) else { return }
    
    var fullTextVal: AnyObject?
    guard AXUIElementCopyAttributeValue(targetEl, kAXValueAttribute as CFString, &fullTextVal) == .success,
          let text = fullTextVal as? String else { return }
    
    let ns = text as NSString
    guard charRange.location >= 0, charRange.location < ns.length else { return }
    
    var start = charRange.location
    while start > 0 {
        let c = ns.character(at: start - 1)
        if CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains(UnicodeScalar(c)!) {
            start -= 1
        } else {
            break
        }
    }
    var end = charRange.location
    while end < ns.length {
        let c = ns.character(at: end)
        if CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains(UnicodeScalar(c)!) {
            end += 1
        } else {
            break
        }
    }
    var wordRange = CFRange(location: start, length: max(1, end - start))
    if let selVal = AXValueCreate(.cfRange, &wordRange) {
        AXUIElementSetAttributeValue(targetEl, kAXSelectedTextRangeAttribute as CFString, selVal)
    }
}

func selectRangeInBackground(pid: pid_t, from: CGPoint, to: CGPoint) -> Bool {
    let appEl = AXUIElementCreateApplication(pid)
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(appEl, Float(from.x), Float(from.y), &el) == .success,
          let targetEl = el else { return false }
    
    var ptFrom = from
    var ptTo = to
    guard let valFrom = AXValueCreate(.cgPoint, &ptFrom),
          let valTo = AXValueCreate(.cgPoint, &ptTo) else { return false }
    
    var rVal1: AnyObject?
    var rVal2: AnyObject?
    var range1 = CFRange()
    var range2 = CFRange()
    
    if AXUIElementCopyParameterizedAttributeValue(targetEl, "AXRangeForPosition" as CFString, valFrom, &rVal1) == .success,
       let rv1 = rVal1, AXValueGetValue(rv1 as! AXValue, .cfRange, &range1),
       AXUIElementCopyParameterizedAttributeValue(targetEl, "AXRangeForPosition" as CFString, valTo, &rVal2) == .success,
       let rv2 = rVal2, AXValueGetValue(rv2 as! AXValue, .cfRange, &range2) {
        
        let loc = min(range1.location, range2.location)
        let endLoc = max(range1.location + range1.length, range2.location + range2.length)
        var combinedRange = CFRange(location: loc, length: max(1, endLoc - loc))
        if let selVal = AXValueCreate(.cfRange, &combinedRange) {
            AXUIElementSetAttributeValue(targetEl, kAXSelectedTextRangeAttribute as CFString, selVal)
            return true
        }
    }
    return false
}

func selectRangeAction(from: CGPoint, to: CGPoint, targetPID: pid_t? = nil, appName: String? = nil, autoClean: Bool = false) {
    var pid = targetPID
    if pid == nil, let app = appName {
        let apps = NSWorkspace.shared.runningApplications
        if let match = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(app) == true }) {
            pid = match.processIdentifier
        }
    }
    
    if let app = appName {
        VirtualCursorClient.pipShow(appName: app, windowID: nil)
    }
    
    // 1. Smooth glide to start point
    VirtualCursorClient.move(to: from, speed: "normal")
    usleep(250000)
    VirtualCursorClient.click(at: from)
    
    // 2. Drag to end point
    VirtualCursorClient.move(to: to, speed: "normal")
    usleep(250000)
    VirtualCursorClient.click(at: to)
    
    // 3. Post non-disruptive events to background app or AX range
    if let p = pid {
        let axSuccess = selectRangeInBackground(pid: p, from: from, to: to)
        if !axSuccess {
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)
            down?.postToPid(p)
            usleep(20000)
            let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: to, mouseButton: .left)
            drag?.postToPid(p)
            usleep(20000)
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)
            up?.postToPid(p)
        }
    } else {
        dragMouse(from: from, to: to, duration: 0.4, restoreCursor: true)
    }
    
    if autoClean {
        usleep(300000)
        VirtualCursorClient.done()
    }
    print("Selected range from (\(Int(from.x)), \(Int(from.y))) to (\(Int(to.x)), \(Int(to.y))) \(pid != nil ? "[Target PID: \(pid!)]" : "")")
}

func resolveTargetPID(at pt: CGPoint, explicitPID: pid_t?) -> pid_t? {
    if let pid = explicitPID { return pid }
    let myPID = ProcessInfo.processInfo.processIdentifier
    let wins = getWindowsList(allLayers: false)
    // Prefer an active PiP target or last targeted background window containing pt
    for path in ["/tmp/mcu_active_pip_pid.txt", "/tmp/mcu_last_target_pid.txt"] {
        if let savedPIDStr = try? String(contentsOfFile: path, encoding: .utf8),
           let savedPID = Int32(savedPIDStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            for win in wins {
                guard let wPid = (win["pid"] as? Int).map(pid_t.init) ?? (win["pid"] as? pid_t),
                      wPid == savedPID,
                      let b = win["bounds"] as? [String: CGFloat] else { continue }
                let rect = CGRect(x: b["x"] ?? 0, y: b["y"] ?? 0, width: b["width"] ?? 0, height: b["height"] ?? 0)
                if rect.contains(pt) { return savedPID }
            }
        }
    }
    for win in wins {
        guard let wPid = (win["pid"] as? Int).map(pid_t.init) ?? (win["pid"] as? pid_t),
              wPid != myPID,
              let b = win["bounds"] as? [String: CGFloat] else { continue }
        let rect = CGRect(x: b["x"] ?? 0, y: b["y"] ?? 0, width: b["width"] ?? 0, height: b["height"] ?? 0)
        if rect.contains(pt) { return wPid }
    }
    return nil
}

func clickMouseNonDisruptive(at targetPoint: CGPoint?, button: CGMouseButton = .left, clickCount: Int = 1, restoreCursor: Bool = true, targetPID: pid_t? = nil) {
    let pt = targetPoint ?? getMousePosition()
    let resolvedPID = resolveTargetPID(at: pt, explicitPID: targetPID)
    
    // Access Control check
    let validation = AccessControlEngine.validate(action: "mouse_click", point: pt)
    if !validation.allowed {
        VirtualCursorClient.glow(color: "red")
        fputs("\(validation.reason)\n", stderr)
        AccessControlEngine.logAudit(action: "mouse_click", details: "Point (\(Int(pt.x)), \(Int(pt.y)))", decision: "BLOCKED", reason: validation.reason)
        return
    }
    
    // Glide our virtual cursor smoothly to the target point so movement is clearly visible!
    if let target = targetPoint {
        VirtualCursorClient.move(to: target, speed: "normal")
        usleep(400000)
    }
    
    let downType: CGEventType
    let upType: CGEventType
    switch button {
    case .right:
        downType = .rightMouseDown
        upType = .rightMouseUp
    case .center:
        downType = .otherMouseDown
        upType = .otherMouseUp
    default:
        downType = .leftMouseDown
        upType = .leftMouseUp
    }
    
    let focusableRoles: Set<String> = ["AXTextField", "AXComboBox", "AXTextArea", "AXSearchField"]
    let pressableRoles: Set<String> = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXPopUpButton", "AXTextField", "AXComboBox", "AXTextArea", "AXSearchField", "AXTabButton"]
    let containerStopRoles: Set<String> = ["AXWindow", "AXApplication", "AXWebArea", "AXScrollArea", "AXSplitGroup", "AXToolbar", "AXSheet"]
    
    var handledViaAX = false
    if let pid = resolvedPID, button == .left {
        try? "\(pt.x),\(pt.y)".write(toFile: "/tmp/mcu_last_click_\(pid).txt", atomically: true, encoding: .utf8)
        try? "\(pid)".write(toFile: "/tmp/mcu_last_target_pid.txt", atomically: true, encoding: .utf8)
        let appEl = AXUIElementCreateApplication(pid)
        var hitEl: AXUIElement?
        if AXUIElementCopyElementAtPosition(appEl, Float(pt.x), Float(pt.y), &hitEl) == .success, let leaf = hitEl {
            // Walk up at most 4 levels to find an explicit interactive control; NEVER fall back to AXWindow or AXWebArea!
            var matchedControl: AXUIElement? = nil
            var matchedRole: String = ""
            var curr: AXUIElement = leaf
            for _ in 0..<5 {
                let r = getAttribute(curr, kAXRoleAttribute) as? String ?? ""
                if containerStopRoles.contains(r) {
                    break
                }
                if pressableRoles.contains(r) || focusableRoles.contains(r) {
                    matchedControl = curr
                    matchedRole = r
                    break
                }
                if let parent = getAttribute(curr, kAXParentAttribute) {
                    curr = parent as! AXUIElement
                } else {
                    break
                }
            }
            
            VirtualCursorClient.click(at: pt, button: "left")
            if let ctrl = matchedControl {
                // NEVER set kAXFocusedAttribute = true on WebKit/AppKit background elements as WebKit calls makeKeyAndOrderFront!
                // Instead, perform kAXPressAction and track the clicked input coordinate for subsequent keyboard typing.
                AXUIElementPerformAction(ctrl, kAXPressAction as CFString)
                handledViaAX = true
            } else {
                let leafRole = getAttribute(leaf, kAXRoleAttribute) as? String ?? ""
                if !containerStopRoles.contains(leafRole) {
                    AXUIElementPerformAction(leaf, kAXPressAction as CFString)
                    handledViaAX = true
                }
            }
        }
    }
    
    // Only post raw CGEvent to PID if AX did not handle it (or for right/middle clicks)
    if !handledViaAX {
        for i in 1...clickCount {
            VirtualCursorClient.click(at: pt, button: (button == .right ? "right" : "left"))
            
            let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: pt, mouseButton: button)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            if let pid = resolvedPID {
                down?.postToPid(pid)
            }
            
            usleep(15000)
            
            let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: pt, mouseButton: button)
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            if let pid = resolvedPID {
                up?.postToPid(pid)
            }
            
            if i < clickCount { usleep(120000) }
        }
    }
    
    // For background overshadowed apps: perform native AX word selection if double-clicking text
    if let pid = resolvedPID, clickCount >= 2 {
        selectWordInBackground(pid: pid, at: pt)
    }
    
    AccessControlEngine.logAudit(action: "mouse_click", details: "Point (\(Int(pt.x)), \(Int(pt.y))), button=\(button == .left ? "left" : "right"), count=\(clickCount), targetPID=\(String(describing: resolvedPID))")
    print("Clicked at (\(Int(pt.x)), \(Int(pt.y))) button=\(button == .left ? "left" : (button == .right ? "right" : "middle")) \(resolvedPID != nil ? "[Target PID: \(resolvedPID!)] (Zero-focus background delivery)" : "")")
}

func moveMouseVirtual(to target: CGPoint, speed: String? = nil, duration: Double? = nil) {
    let validation = AccessControlEngine.validate(action: "cursor_move", point: target)
    if !validation.allowed {
        VirtualCursorClient.glow(color: "red")
        fputs("\(validation.reason)\n", stderr)
        return
    }
    // Only moves the fancy overlay cursor - NEVER displaces the user's actual mouse!
    VirtualCursorClient.move(to: target, speed: speed, duration: duration)
    AccessControlEngine.logAudit(action: "cursor_move", details: "Point (\(Int(target.x)), \(Int(target.y)))")
    print("Fancy agent cursor moved to (\(Int(target.x)), \(Int(target.y))) [Zero user disruption]")
}

func dragMouse(from start: CGPoint, to end: CGPoint, duration: Double = 0.4, restoreCursor: Bool = true) {
    let validationStart = AccessControlEngine.validate(action: "mouse_drag", point: start)
    let validationEnd = AccessControlEngine.validate(action: "mouse_drag", point: end)
    if !validationStart.allowed || !validationEnd.allowed {
        let reason = !validationStart.allowed ? validationStart.reason : validationEnd.reason
        fputs("\(reason)\n", stderr)
        AccessControlEngine.logAudit(action: "mouse_drag", details: "From (\(Int(start.x)), \(Int(start.y))) to (\(Int(end.x)), \(Int(end.y)))", decision: "BLOCKED", reason: reason)
        return
    }
    
    let originalUserPos = getMousePosition()
    
    VirtualCursorClient.move(to: start)
    usleep(150000)
    
    let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left)
    moveEvent?.post(tap: .cghidEventTap)
    usleep(25000)
    
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)
    down?.post(tap: .cghidEventTap)
    usleep(20000)
    
    let steps = max(10, Int(duration * 40))
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let ease = (1.0 - cos(t * .pi)) / 2.0
        let currentX = start.x + (end.x - start.x) * ease
        let currentY = start.y + (end.y - start.y) * ease
        let pt = CGPoint(x: currentX, y: currentY)
        
        VirtualCursorClient.move(to: pt, speed: "instant")
        let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: pt, mouseButton: .left)
        drag?.post(tap: .cghidEventTap)
        usleep(useconds_t(duration / Double(steps) * 1_000_000))
    }
    
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)
    up?.post(tap: .cghidEventTap)
    
    if restoreCursor {
        usleep(10000)
        CGWarpMouseCursorPosition(originalUserPos)
        let restoreEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: originalUserPos, mouseButton: .left)
        restoreEvent?.post(tap: .cghidEventTap)
    }
    
    AccessControlEngine.logAudit(action: "mouse_drag", details: "From (\(Int(start.x)), \(Int(start.y))) to (\(Int(end.x)), \(Int(end.y))) (User cursor preserved: \(restoreCursor))")
    print("Dragged from (\(Int(start.x)), \(Int(start.y))) to (\(Int(end.x)), \(Int(end.y))) [User cursor preserved]")
}

func findScrollArea(pid: pid_t, at pt: CGPoint?) -> AXUIElement? {
    let appEl = AXUIElementCreateApplication(pid)
    var probePoint = pt
    if probePoint == nil {
        let wins = getWindowsList(allLayers: false)
        var targetWin: [String: Any]? = nil
        if let widStr = try? String(contentsOfFile: "/tmp/mcu_active_pip_wid.txt", encoding: .utf8),
           let wid = Int(widStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            targetWin = wins.first(where: { ($0["id"] as? Int) == wid && (($0["pid"] as? Int).map(pid_t.init) ?? ($0["pid"] as? pid_t)) == pid })
        }
        if targetWin == nil {
            targetWin = wins.first(where: { win in
                let wPid = (win["pid"] as? Int).map(pid_t.init) ?? (win["pid"] as? pid_t)
                let b = win["bounds"] as? [String: CGFloat]
                return wPid == pid && (b?["width"] ?? 0) >= 200 && (b?["height"] ?? 0) >= 200
            })
        }
        if let win = targetWin, let b = win["bounds"] as? [String: CGFloat] {
            let x = (b["x"] ?? 0) + (b["width"] ?? 0) * 0.5
            let y = (b["y"] ?? 0) + (b["height"] ?? 0) * 0.5
            probePoint = CGPoint(x: x, y: y)
        }
    }
    if let p = probePoint {
        var hitEl: AXUIElement?
        if AXUIElementCopyElementAtPosition(appEl, Float(p.x), Float(p.y), &hitEl) == .success, var curr = hitEl {
            for _ in 0..<12 {
                let r = getAttribute(curr, kAXRoleAttribute) as? String ?? ""
                if r == "AXScrollArea" {
                    return curr
                }
                if let parent = getAttribute(curr, kAXParentAttribute) {
                    curr = parent as! AXUIElement
                } else {
                    break
                }
            }
        }
    }
    // Fallback: recursive breadth-first search inside the app's main window for an AXScrollArea
    var results: [AXUIElement] = []
    func search(_ el: AXUIElement, depth: Int) {
        if depth > 6 || !results.isEmpty { return }
        let r = getAttribute(el, kAXRoleAttribute) as? String ?? ""
        if r == "AXScrollArea" {
            if getAttribute(el, kAXVerticalScrollBarAttribute) != nil {
                results.append(el)
                return
            }
        }
        if let children = getAttribute(el, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                search(child, depth: depth + 1)
                if !results.isEmpty { return }
            }
        }
    }
    search(appEl, depth: 0)
    return results.first
}

func scrollWheel(dx: Int32, dy: Int32, at: CGPoint? = nil, targetPID: pid_t? = nil) {
    let validation = AccessControlEngine.validate(action: "mouse_scroll")
    if !validation.allowed {
        fputs("\(validation.reason)\n", stderr)
        return
    }
    let resolvedPID: pid_t?
    if let loc = at {
        VirtualCursorClient.move(to: loc, speed: "fast")
        usleep(40000)
        resolvedPID = resolveTargetPID(at: loc, explicitPID: targetPID)
    } else {
        resolvedPID = resolveLastTargetPID(explicitPID: targetPID)
    }

    var vBar: AXUIElement? = nil
    var hBar: AXUIElement? = nil
    var beforeV: Double? = nil
    var beforeH: Double? = nil
    if let pid = resolvedPID, let scrollArea = findScrollArea(pid: pid, at: at) {
        if let vb = getAttribute(scrollArea, kAXVerticalScrollBarAttribute) {
            let el = vb as! AXUIElement
            vBar = el
            beforeV = (getAttribute(el, kAXValueAttribute) as? NSNumber)?.doubleValue
        }
        if let hb = getAttribute(scrollArea, kAXHorizontalScrollBarAttribute) {
            let el = hb as! AXUIElement
            hBar = el
            beforeH = (getAttribute(el, kAXValueAttribute) as? NSNumber)?.doubleValue
        }
    }

    let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
    if let loc = at {
        event?.location = loc
    }
    if let pid = resolvedPID {
        event?.postToPid(pid)
    } else {
        event?.post(tap: .cghidEventTap)
    }

    // If background window (e.g. Safari/WebKit) ignores CGEvent.postToPid scroll events, apply smoothly via AXScrollBar
    if let pid = resolvedPID {
        usleep(20000)
        if dy != 0, let vb = vBar, let initialV = beforeV {
            let afterV = (getAttribute(vb, kAXValueAttribute) as? NSNumber)?.doubleValue ?? initialV
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(vb, kAXValueAttribute as CFString, &settable)
            if settable.boolValue && abs(afterV - initialV) < 0.0001 {
                let delta = -Double(dy) * 0.012
                let targetV = min(1.0, max(0.0, initialV + delta))
                let steps = 5
                for s in 1...steps {
                    let frac = Double(s) / Double(steps)
                    let stepVal = initialV + (targetV - initialV) * frac
                    AXUIElementSetAttributeValue(vb, kAXValueAttribute as CFString, NSNumber(value: stepVal))
                    usleep(12000)
                }
            }
        }
        if dx != 0, let hb = hBar, let initialH = beforeH {
            let afterH = (getAttribute(hb, kAXValueAttribute) as? NSNumber)?.doubleValue ?? initialH
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(hb, kAXValueAttribute as CFString, &settable)
            if settable.boolValue && abs(afterH - initialH) < 0.0001 {
                let delta = -Double(dx) * 0.012
                let targetH = min(1.0, max(0.0, initialH + delta))
                let steps = 5
                for s in 1...steps {
                    let frac = Double(s) / Double(steps)
                    let stepVal = initialH + (targetH - initialH) * frac
                    AXUIElementSetAttributeValue(hb, kAXValueAttribute as CFString, NSNumber(value: stepVal))
                    usleep(12000)
                }
            }
        }
        try? "\(pid)".write(toFile: "/tmp/mcu_last_target_pid.txt", atomically: true, encoding: .utf8)
    }

    AccessControlEngine.logAudit(action: "mouse_scroll", details: "dx=\(dx), dy=\(dy), pid=\(resolvedPID?.description ?? "none")")
    print("Scrolled deltaX=\(dx), deltaY=\(dy) \(resolvedPID != nil ? "[Target PID: \(resolvedPID!)] (Zero-focus background delivery)" : "")")
}

func resolveLastTargetPID(explicitPID: pid_t?) -> pid_t? {
    if let p = explicitPID { return p }
    if let str = try? String(contentsOfFile: "/tmp/mcu_last_target_pid.txt", encoding: .utf8),
       let p = Int32(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return p
    }
    return nil
}

func resolveFocusedAXElement(for pid: pid_t) -> AXUIElement? {
    let inputRoles: Set<String> = ["AXTextField", "AXComboBox", "AXTextArea", "AXSearchField"]
    let appEl = AXUIElementCreateApplication(pid)
    if let coords = try? String(contentsOfFile: "/tmp/mcu_last_click_\(pid).txt", encoding: .utf8) {
        let parts = coords.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if parts.count == 2 {
            var hitEl: AXUIElement?
            if AXUIElementCopyElementAtPosition(appEl, parts[0], parts[1], &hitEl) == .success, let leaf = hitEl {
                var curr = leaf
                for _ in 0..<5 {
                    let role = getAttribute(curr, kAXRoleAttribute) as? String ?? ""
                    if ["AXWindow", "AXApplication", "AXWebArea", "AXScrollArea"].contains(role) {
                        break
                    }
                    if inputRoles.contains(role) {
                        return curr
                    }
                    if let parent = getAttribute(curr, kAXParentAttribute) {
                        curr = parent as! AXUIElement
                    } else {
                        break
                    }
                }
            }
        }
    }
    var focusedRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
       let f = focusedRef {
        let el = f as! AXUIElement
        let r = getAttribute(el, kAXRoleAttribute) as? String ?? ""
        if inputRoles.contains(r) {
            return el
        }
    }
    return nil
}

func typeString(_ text: String, targetPID: pid_t? = nil) {
    let validation = AccessControlEngine.validate(action: "keyboard_type")
    if !validation.allowed {
        fputs("\(validation.reason)\n", stderr)
        AccessControlEngine.logAudit(action: "keyboard_type", details: "Length \(text.count)", decision: "BLOCKED", reason: validation.reason)
        return
    }
    
    let resolvedPID = resolveLastTargetPID(explicitPID: targetPID)
    
    var focusedEl: AXUIElement? = nil
    var beforeVal: String = ""
    if let pid = resolvedPID, let el = resolveFocusedAXElement(for: pid) {
        focusedEl = el
        beforeVal = getAttribute(el, kAXValueAttribute) as? String ?? ""
    }
    
    let source = CGEventSource(stateID: .hidSystemState)
    for char in text {
        let utf16 = Array(String(char).utf16)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        if let pid = resolvedPID {
            down?.postToPid(pid)
        }
        
        usleep(2000)
        
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        if let pid = resolvedPID {
            up?.postToPid(pid)
        }
        
        usleep(4000)
    }
    
    // If background inactive window ignored raw CGEvent keystrokes on a focused AX text input, apply via native AXValue
    if let el = focusedEl {
        usleep(15000)
        let afterVal = getAttribute(el, kAXValueAttribute) as? String ?? ""
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
        if settable.boolValue && afterVal == beforeVal {
            let updated = beforeVal + text
            AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, updated as CFTypeRef)
        }
    }
    
    AccessControlEngine.logAudit(action: "keyboard_type", details: "Typed \(text.count) characters \(resolvedPID != nil ? "to PID \(resolvedPID!)" : "")")
    print("Typed: \"\(text)\" \(resolvedPID != nil ? "[Target PID: \(resolvedPID!)] (Zero-focus background delivery)" : "")")
}

func pressKey(keyCode: CGKeyCode, flags: CGEventFlags = [], targetPID: pid_t? = nil) {
    let resolvedPID = resolveLastTargetPID(explicitPID: targetPID)
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    down?.flags = flags
    if let pid = resolvedPID {
        down?.postToPid(pid)
    }
    
    usleep(15000)
    
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    up?.flags = flags
    if let pid = resolvedPID {
        up?.postToPid(pid)
    }
    
    if let pid = resolvedPID, (keyCode == 0x24 || keyCode == 0x4C), let el = resolveFocusedAXElement(for: pid) {
        AXUIElementPerformAction(el, kAXConfirmAction as CFString)
    }
}

func triggerHotkeyCombo(_ combo: String, targetPID: pid_t? = nil) {
    let validation = AccessControlEngine.validate(action: "keyboard_hotkey", hotkey: combo)
    if !validation.allowed {
        fputs("\(validation.reason)\n", stderr)
        AccessControlEngine.logAudit(action: "keyboard_hotkey", details: combo, decision: "BLOCKED", reason: validation.reason)
        return
    }
    
    guard let parsed = parseHotkey(combo) else {
        fputs("Error: Failed to parse hotkey combo '\(combo)'\n", stderr)
        return
    }
    pressKey(keyCode: parsed.keyCode, flags: parsed.flags, targetPID: targetPID)
    AccessControlEngine.logAudit(action: "keyboard_hotkey", details: "\(combo) \(targetPID != nil ? "[PID: \(targetPID!)]" : "")")
    print("Triggered hotkey combo '\(combo)' \(targetPID != nil ? "[Target PID: \(targetPID!)] (Overshadowed background delivery)" : "")")
}

// MARK: - Clipboard Management

func getClipboardString() -> String {
    return NSPasteboard.general.string(forType: .string) ?? ""
}

func setClipboardString(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Main CLI Router

func printUsage() {
    let usage = """
    macOS Computer Use CLI (mcu)
    High-performance native macOS desktop automation, non-disruptive virtual cursor & access controls

    USAGE:
      mcu cursor start                         Launch fancy agent cursor overlay (click-through, non-disruptive)
      mcu cursor stop                          Terminate fancy agent cursor overlay
      mcu cursor move <x> <y>                  Move fancy virtual cursor [Leaves user hardware mouse untouched]
      mcu cursor ripple <x> <y>                Trigger visual pulse/ripple animation at target
      mcu cursor glow <color>                  Change cursor theme (cyan, emerald, violet, amber, crimson)
      mcu cursor-daemon                        Internal daemon entrypoint

      mcu emergency stop                       Activate immediate deadman kill switch (halts all agent actions)
      mcu emergency resume                     Clear emergency halt lock and resume operation
      mcu emergency status                     Check kill switch status

      mcu access policy                        Inspect active access control rules & boundaries
      mcu audit tail [--n <count>]             Inspect recent entries in the immutable security audit log

      mcu screen info                          Print display geometries and cursor position (JSON)
      mcu screen capture [options]             Capture screenshot (optional 1x points scaling & coordinate grid)
          --output <path>                      Target image path (default: /tmp/mcu_screen.png)
          --scale-1x                           Downscale Retina to logical point resolution (1px = 1pt)
          --grid                               Draw coordinate grid overlay (major/minor lines + numbers)
          --cursor                             Include mouse cursor in capture
          --window <wid>                       Capture specific window ID
          --app <name>                         Capture window of specific application
          --rect <x,y,w,h>                     Capture specific rectangle in display points

      mcu window list [--all]                  List on-screen windows with IDs, titles, owners, bounds (JSON)
      mcu window capture <app|wid> [options]   Capture background window even if overshadowed by other apps
      mcu window focus <app|pid|wid>           Bring window or application to front
      mcu window move <wid> <x> <y> <w> <h>    Move/resize window to target coordinates
      mcu window resize <wid> <w> <h>          Resize window with visual cursor and ripple

      mcu ax dump [options]                    Dump accessibility hierarchy of app or front window
          --app <name> / --pid <pid>           Target application
          --depth <n>                          Recursion depth (default: 4)
      mcu ax find [options]                    Search for accessibility elements by title, role, or text
      mcu ax click [options]                   Perform AXPress action directly [Hardware mouse is never moved!]
      mcu ax inspect <x> <y>                   Inspect accessibility element directly under screen coordinates

      mcu mouse pos                            Print current mouse position (x, y)
      mcu mouse click <x> <y> [options]        Click at coordinates with automatic user cursor restoration
          --button left|right|middle           Mouse button (default: left)
          --count 1|2|3                        Click count (default: 1)
          --no-restore                         Do not restore user's cursor position after click
      mcu mouse drag <x1> <y1> <x2> <y2>       Drag mouse from (x1, y1) to (x2, y2)
      mcu mouse scroll <dx> <dy>               Scroll wheel (dy > 0 is up, dy < 0 is down)

      mcu keyboard type <text>                 Type text string using native unicode injection
      mcu keyboard key <name>                  Press a single key (e.g., return, tab, esc, space, down)
      mcu keyboard hotkey <combo>              Press hotkey combination (e.g., cmd+space, cmd+c, opt+f)

      mcu clipboard get                        Print system clipboard text
      mcu clipboard set <text>                 Write text to system clipboard

      mcu screenshare status                   Check status of macOS Screen Sharing services
      mcu screenshare open [host]              Launch Screen Sharing.app or connect to VNC target
      mcu record start <output.mp4>            Start screen recording in background
      mcu record stop                          Stop active screen recording

      mcu ocr [--app <name>] [--window <wid>]  High-speed Apple Vision OCR on window or full screen
      mcu click text <query> [options]         Semantically find & click text with virtual cursor
      mcu select range <x1> <y1> <x2> <y2>     Select range of text in background without focus
      mcu done                                 Clean up and dismiss all PiP previews and virtual cursor
      mcu mcp                                  Run native MCP Server over stdio JSON-RPC 2.0
    """
    print(usage)
}

func resizeWindowWithVirtualCursor(windowID wid: Int, targetWidth: Double, targetHeight: Double, duration: Double = 0.6) {
    let windows = getWindowsList(allLayers: true)
    guard let targetWin = windows.first(where: { ($0["id"] as? Int) == wid }),
          let pidInt = (targetWin["pid"] as? Int) ?? (targetWin["pid"] as? Int32).map(Int.init),
          let b = targetWin["bounds"] as? [String: Any] else {
        fputs("Error: Could not locate window \(wid)\n", stderr)
        exit(1)
    }
    
    func parseCoord(_ val: Any?) -> Double {
        if let d = val as? Double { return d }
        if let f = val as? CGFloat { return Double(f) }
        if let i = val as? Int { return Double(i) }
        return 0.0
    }
    
    let curX = parseCoord(b["x"])
    let curY = parseCoord(b["y"])
    let curW = parseCoord(b["width"])
    let curH = parseCoord(b["height"])
    
    let pid = pid_t(pidInt)
    let appEl = AXUIElementCreateApplication(pid)
    guard let winElements = getAttribute(appEl, kAXWindowsAttribute) as? [AXUIElement],
          let winEl = winElements.first(where: { el in
              var id: CGWindowID = 0
              return _AXUIElementGetWindow(el, &id) == .success && Int(id) == wid
          }) ?? winElements.first else {
        fputs("Error: Could not obtain AXUIElement for window \(wid)\n", stderr)
        exit(1)
    }
    
    let startCorner = CGPoint(x: curX + curW, y: curY + curH)
    let endCorner = CGPoint(x: curX + targetWidth, y: curY + targetHeight)
    
    // 1. Smoothly glide virtual cursor to bottom-right corner of target window
    VirtualCursorClient.move(to: startCorner, speed: "normal")
    usleep(450000)
    
    // 2. Visual grab/press ripple at the resize corner
    VirtualCursorClient.click(at: startCorner)
    usleep(80000)
    
    // 3. Smooth animated resizing along sinusoidal ease curve in 25-35 steps
    let steps = max(15, Int(duration * 40))
    for step in 1...steps {
        let t = Double(step) / Double(steps)
        let ease = (1.0 - cos(t * .pi)) / 2.0
        let w = curW + (targetWidth - curW) * ease
        let h = curH + (targetHeight - curH) * ease
        let corner = CGPoint(x: curX + w, y: curY + h)
        
        var size = CGSize(width: w, height: h)
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(winEl, kAXSizeAttribute as CFString, sizeVal)
        }
        VirtualCursorClient.move(to: corner, speed: "instant")
        usleep(useconds_t(duration / Double(steps) * 1_000_000))
    }
    
    // Final exact size
    var finalSize = CGSize(width: targetWidth, height: targetHeight)
    if let finalVal = AXValueCreate(.cgSize, &finalSize) {
        AXUIElementSetAttributeValue(winEl, kAXSizeAttribute as CFString, finalVal)
    }
    VirtualCursorClient.move(to: endCorner, speed: "instant")
    usleep(40000)
    
    // 4. Release ripple at final position
    VirtualCursorClient.click(at: endCorner)
    
    print("Window \(wid) resized with virtual cursor from (\(Int(curW)), \(Int(curH))) to (\(Int(targetWidth)), \(Int(targetHeight))) [Zero user disruption]")
}

// MARK: - Apple Vision OCR & Semantic Interaction

struct VisionOCRItem: Codable {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let centerX: Double
    let centerY: Double
}

class VisionOCREngine {
    static func captureWindowImage(windowID: CGWindowID) -> (image: CGImage, bounds: CGRect)? {
        let wins = getWindowsList(allLayers: true)
        guard let win = wins.first(where: { ($0["id"] as? Int) == Int(windowID) }),
              let b = win["bounds"] as? [String: Any],
              let bx = (b["x"] as? NSNumber)?.doubleValue,
              let by = (b["y"] as? NSNumber)?.doubleValue,
              let bw = (b["width"] as? NSNumber)?.doubleValue,
              let bh = (b["height"] as? NSNumber)?.doubleValue else {
            return nil
        }
        let bounds = CGRect(x: bx, y: by, width: bw, height: bh)
        
        let tmpFile = "/tmp/mcu_ocr_debug_last.png"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l\(windowID)", tmpFile]
        try? task.run()
        task.waitUntilExit()
        
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: tmpFile) as CFURL, nil),
              let cgImg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fputs("Error: Could not load captured window image from \(tmpFile)\n", stderr)
            return nil
        }
        return (cgImg, bounds)
    }
    
    static func captureScreenImage() -> (image: CGImage, bounds: CGRect)? {
        let screenRect = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let tmpFile = "/tmp/mcu_ocr_screen_\(ProcessInfo.processInfo.processIdentifier).png"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-m", tmpFile]
        try? task.run()
        task.waitUntilExit()
        
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: tmpFile) as CFURL, nil),
              let cgImg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fputs("Error: Could not load captured window image from \(tmpFile)\n", stderr)
            return nil
        }
        return (cgImg, screenRect)
    }
    
    static func recognize(cgImage: CGImage, bounds: CGRect, fast: Bool = true) -> (items: [VisionOCRItem], rawObservations: [VNRecognizedTextObservation]) {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = fast ? .fast : .accurate
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([req])
        } catch {
            fputs("Vision OCR Error: \(error)\n", stderr)
        }
        
        guard let observations = req.results else {
            fputs("Vision OCR: req.results is nil\n", stderr)
            return ([], [])
        }
        fputs("Vision OCR: cgImage \(cgImage.width)x\(cgImage.height), observations count = \(observations.count)\n", stderr)
        
        var items: [VisionOCRItem] = []
        for obs in observations {
            guard let top = obs.topCandidates(1).first else { continue }
            let b = obs.boundingBox
            let winX = bounds.origin.x + b.origin.x * bounds.width
            let winY = bounds.origin.y + (1.0 - b.origin.y - b.height) * bounds.height
            let winW = b.width * bounds.width
            let winH = b.height * bounds.height
            
            let item = VisionOCRItem(
                text: top.string,
                confidence: top.confidence,
                x: winX,
                y: winY,
                width: winW,
                height: winH,
                centerX: winX + winW / 2.0,
                centerY: winY + winH / 2.0
            )
            items.append(item)
        }
        return (items, observations)
    }
    
    static func findText(query: String, in items: [VisionOCRItem], observations: [VNRecognizedTextObservation], bounds: CGRect) -> (targetPoint: CGPoint, matchedText: String, item: VisionOCRItem)? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        
        for (idx, item) in items.enumerated() {
            if let rangeInItem = item.text.localizedStandardRange(of: q) {
                if idx < observations.count {
                    let obs = observations[idx]
                    if let top = obs.topCandidates(1).first,
                       let strRange = top.string.range(of: String(item.text[rangeInItem]), options: .caseInsensitive),
                       let subBoxObs = try? top.boundingBox(for: strRange) {
                        let b = subBoxObs.boundingBox
                        let winX = bounds.origin.x + b.origin.x * bounds.width
                        let winY = bounds.origin.y + (1.0 - b.origin.y - b.height) * bounds.height
                        let winW = b.width * bounds.width
                        let winH = b.height * bounds.height
                        let center = CGPoint(x: winX + winW / 2.0, y: winY + winH / 2.0)
                        return (center, String(item.text[rangeInItem]), item)
                    }
                }
                return (CGPoint(x: item.centerX, y: item.centerY), item.text, item)
            }
        }
        return nil
    }
}

func clickText(
    query: String,
    appName: String? = nil,
    windowID: CGWindowID? = nil,
    button: CGMouseButton = .left,
    clickCount: Int = 1,
    autoClean: Bool = false
) -> (success: Bool, message: String) {
    var targetWID = windowID
    if targetWID == nil, let app = appName {
        targetWID = PiPWindowController.firstWindowID(matchingApp: app)
    }
    
    var targetPID: pid_t? = nil
    if let app = appName {
        let apps = NSWorkspace.shared.runningApplications
        if let match = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(app) == true }) {
            targetPID = match.processIdentifier
        }
    } else if let wid = targetWID {
        let wins = getWindowsList(allLayers: true)
        if let win = wins.first(where: { ($0["id"] as? Int) == Int(wid) }),
           let p = (win["pid"] as? Int) ?? (win["pid"] as? Int32).map(Int.init) {
            targetPID = pid_t(p)
        }
    }
    
    // 1. Activate PiP preview if window/app specified
    if targetWID != nil || appName != nil {
        VirtualCursorClient.pipShow(appName: appName, windowID: targetWID.map(Int.init))
    }
    
    // 2. Capture target
    guard let capture = (targetWID != nil ? VisionOCREngine.captureWindowImage(windowID: targetWID!) : VisionOCREngine.captureScreenImage()) else {
        return (false, "Error: Failed to capture target image for OCR")
    }
    
    // 3. Run OCR
    let (items, rawObs) = VisionOCREngine.recognize(cgImage: capture.image, bounds: capture.bounds, fast: true)
    guard let match = VisionOCREngine.findText(query: query, in: items, observations: rawObs, bounds: capture.bounds) else {
        return (false, "Error: Text '\(query)' not found in target")
    }
    
    let clickPoint = match.targetPoint
    
    // 4. Glide virtual cursor smoothly to point
    VirtualCursorClient.move(to: clickPoint, speed: "normal")
    usleep(250000)
    
    // 5. Tactile press & ripple animation
    VirtualCursorClient.click(at: clickPoint)
    
    // 6. Non-disruptive background delivery to target PID
    clickMouseNonDisruptive(at: clickPoint, button: button, clickCount: clickCount, restoreCursor: true, targetPID: targetPID)
    
    // 7. Auto clean if requested
    if autoClean {
        usleep(300000)
        VirtualCursorClient.done()
    }
    
    return (true, "Clicked text '\(match.matchedText)' at (\(Int(clickPoint.x)), \(Int(clickPoint.y))) \(targetPID != nil ? "[Target PID: \(targetPID!)] (Overshadowed background delivery)" : "")")
}

// MARK: - Native MCP Server (stdio JSON-RPC 2.0)

func sendMCPResponse(_ dict: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: dict),
       let str = String(data: data, encoding: .utf8) {
        FileHandle.standardOutput.write((str + "\n").data(using: .utf8)!)
    }
}

func handleMCPToolCall(name: String, args: [String: Any]) -> String {
    switch name {
    case "click", "mouse_click":
        guard let x = (args["x"] as? NSNumber)?.doubleValue,
              let y = (args["y"] as? NSNumber)?.doubleValue else {
            return "Error: missing required x, y coordinates"
        }
        let btnStr = (args["button"] as? String)?.lowercased() ?? "left"
        let btn: CGMouseButton = (btnStr == "right") ? .right : ((btnStr == "middle" || btnStr == "center") ? .center : .left)
        let count = (args["count"] as? NSNumber)?.intValue ?? 1
        var targetPID: pid_t? = nil
        if let app = args["app"] as? String {
            let apps = NSWorkspace.shared.runningApplications
            if let match = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(app) == true }) {
                targetPID = match.processIdentifier
            }
        }
        clickMouseNonDisruptive(at: CGPoint(x: x, y: y), button: btn, clickCount: count, restoreCursor: true, targetPID: targetPID)
        if let autoClean = args["done"] as? Bool, autoClean {
            usleep(300000)
            VirtualCursorClient.done()
        }
        return "Clicked at (\(Int(x)), \(Int(y))) count=\(count) button=\(btnStr)"

    case "move", "mouse_move":
        guard let x = (args["x"] as? NSNumber)?.doubleValue,
              let y = (args["y"] as? NSNumber)?.doubleValue else {
            return "Error: missing x, y coordinates"
        }
        moveMouseVirtual(to: CGPoint(x: x, y: y), speed: "normal")
        return "Moved virtual cursor to (\(Int(x)), \(Int(y)))"

    case "type", "keyboard_type":
        guard let text = args["text"] as? String else { return "Error: missing text" }
        var targetPID: pid_t? = nil
        if let app = args["app"] as? String {
            let apps = NSWorkspace.shared.runningApplications
            if let match = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(app) == true }) {
                targetPID = match.processIdentifier
            }
        }
        typeString(text, targetPID: targetPID)
        return "Typed: \"\(text)\""

    case "key", "keyboard_key":
        guard let keyName = (args["name"] as? String ?? args["key"] as? String)?.lowercased() else {
            return "Error: missing key name"
        }
        guard let code = keyNameToKeyCode[keyName] else {
            return "Error: unknown key '\(keyName)'"
        }
        var targetPID: pid_t? = nil
        if let app = args["app"] as? String {
            let apps = NSWorkspace.shared.runningApplications
            if let match = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(app) == true }) {
                targetPID = match.processIdentifier
            }
        }
        pressKey(keyCode: code, targetPID: targetPID)
        return "Pressed key '\(keyName)'"

    case "hotkey", "keyboard_hotkey":
        guard let combo = args["combo"] as? String else {
            return "Error: missing 'combo' argument (e.g. 'cmd+shift+n')"
        }
        var targetPID: pid_t? = nil
        if let app = args["app"] as? String {
            let apps = NSWorkspace.shared.runningApplications
            if let match = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(app) == true }) {
                targetPID = match.processIdentifier
            }
        } else if let wid = (args["window"] as? NSNumber)?.intValue {
            let wins = getWindowsList(allLayers: true)
            if let win = wins.first(where: { ($0["id"] as? Int) == wid }),
               let p = (win["pid"] as? Int) ?? (win["pid"] as? Int32).map(Int.init) {
                targetPID = pid_t(p)
            }
        }
        triggerHotkeyCombo(combo, targetPID: targetPID)
        return "Triggered hotkey combo '\(combo)' \(targetPID != nil ? "[Target PID: \(targetPID!)]" : "")"

    case "browser_open":
        guard let url = args["url"] as? String else { return "Error: missing 'url'" }
        let appName = args["app"] as? String ?? "Safari"
        let isPrivate = (args["private"] as? Bool) ?? (args["incognito"] as? Bool) ?? false
        
        let apps = NSWorkspace.shared.runningApplications
        let isRunning = apps.contains(where: { $0.localizedName?.localizedCaseInsensitiveContains(appName) == true })
        if !isRunning {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            if let bundleID = appName.localizedCaseInsensitiveContains("Safari") ? "com.apple.Safari" : nil,
               let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
                sleep(2)
            }
        }
        
        if isPrivate, let match = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(appName) == true }) {
            triggerHotkeyCombo("cmd+shift+n", targetPID: match.processIdentifier)
            usleep(600000)
        }
        
        if appName.localizedCaseInsensitiveContains("Safari") {
            let script = "tell application \"Safari\" to set URL of current tab of front window to \"\(url)\""
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
            }
        }
        VirtualCursorClient.pipShow(appName: appName, windowID: nil)
        return "Opened \(url) in \(appName) \(isPrivate ? "(Private Browsing) " : "")[Zero focus stolen, PiP oversight active]"

    case "screen_capture":
        let output = args["output"] as? String ?? "/tmp/mcu_screen.png"
        let wid = (args["window"] as? NSNumber).map { CGWindowID($0.intValue) }
        var rect: CGRect? = nil
        if let rectStr = args["rect"] as? String {
            let parts = rectStr.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 4 {
                rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            }
        }
        captureScreen(output: output, scale1x: true, withGrid: false, windowID: wid, rect: rect, includeCursor: false)
        return "Screen captured to \(output)"

    case "window_capture":
        var targetWID: CGWindowID? = nil
        if let wid = (args["window"] as? NSNumber)?.intValue ?? (args["wid"] as? NSNumber)?.intValue {
            targetWID = CGWindowID(wid)
        } else if let app = args["app"] as? String {
            targetWID = PiPWindowController.firstWindowID(matchingApp: app)
        }
        guard let wid = targetWID else {
            return "Error: Window not found. Please provide a valid 'app' name or 'window' ID."
        }
        let output = args["output"] as? String ?? "/tmp/mcu_window_\(wid).png"
        let scale1x = (args["scale_1x"] as? Bool) ?? true
        captureScreen(output: output, scale1x: scale1x, withGrid: false, windowID: wid, rect: nil, includeCursor: false)
        return "Background window \(wid) captured to \(output) [Overshadowed background isolated]"

    case "pip_show":
        let app = args["app"] as? String
        let wid = (args["window"] as? NSNumber)?.intValue
        VirtualCursorClient.pipShow(appName: app, windowID: wid)
        return "PiP live preview activated for '\(app ?? (wid != nil ? "Window \(wid!)" : "Active Window"))'"

    case "pip_hide":
        VirtualCursorClient.pipHide()
        return "All PiP live previews closed"

    case "window_list":
        let windows = getWindowsList(allLayers: false)
        if let data = try? JSONSerialization.data(withJSONObject: windows, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "[]"

    case "done", "cleanup":
        VirtualCursorClient.done()
        return "All PiP previews and virtual cursor dismissed"

    case "ocr":
        var targetWID: CGWindowID? = nil
        if let wid = (args["window"] as? NSNumber)?.intValue ?? (args["wid"] as? NSNumber)?.intValue {
            targetWID = CGWindowID(wid)
        } else if let app = args["app"] as? String {
            targetWID = PiPWindowController.firstWindowID(matchingApp: app)
        }
        let fast = (args["fast"] as? Bool) ?? true
        
        guard let capture = (targetWID != nil ? VisionOCREngine.captureWindowImage(windowID: targetWID!) : VisionOCREngine.captureScreenImage()) else {
            return "Error: Failed to capture target image for OCR"
        }
        let (items, _) = VisionOCREngine.recognize(cgImage: capture.image, bounds: capture.bounds, fast: fast)
        if let data = try? JSONSerialization.data(withJSONObject: items.map { [
            "text": $0.text,
            "confidence": $0.confidence,
            "x": $0.x,
            "y": $0.y,
            "width": $0.width,
            "height": $0.height,
            "center_x": $0.centerX,
            "center_y": $0.centerY
        ] }, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "[]"

    case "click_text":
        guard let query = args["query"] as? String else {
            return "Error: missing required 'query' parameter"
        }
        let app = args["app"] as? String
        let wid = (args["window"] as? NSNumber).map { CGWindowID($0.intValue) }
        let btnStr = (args["button"] as? String)?.lowercased() ?? "left"
        let btn: CGMouseButton = (btnStr == "right") ? .right : ((btnStr == "middle" || btnStr == "center") ? .center : .left)
        let count = (args["count"] as? NSNumber)?.intValue ?? 1
        let done = (args["done"] as? Bool) ?? false
        
        let result = clickText(query: query, appName: app, windowID: wid, button: btn, clickCount: count, autoClean: done)
        return result.message

    case "scroll", "mouse_scroll":
        guard let dy = (args["dy"] as? NSNumber)?.int32Value else {
            return "Error: missing required 'dy' parameter"
        }
        let dx = (args["dx"] as? NSNumber)?.int32Value ?? 0
        var pt: CGPoint? = nil
        if let x = (args["x"] as? NSNumber)?.doubleValue,
           let y = (args["y"] as? NSNumber)?.doubleValue {
            pt = CGPoint(x: x, y: y)
        }
        var targetPID: pid_t? = nil
        if let app = args["app"] as? String {
            let apps = NSWorkspace.shared.runningApplications
            if let match = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(app) == true }) {
                targetPID = match.processIdentifier
            }
        } else if let wid = (args["window"] as? NSNumber)?.intValue {
            let wins = getWindowsList(allLayers: true)
            if let win = wins.first(where: { ($0["id"] as? Int) == wid }),
               let p = (win["pid"] as? Int) ?? (win["pid"] as? Int32).map(Int.init) {
                targetPID = pid_t(p)
            }
        }
        scrollWheel(dx: dx, dy: dy, at: pt, targetPID: targetPID)
        if (args["done"] as? Bool) == true {
            usleep(200000)
            VirtualCursorClient.done()
        }
        return "Scrolled deltaX=\(dx), deltaY=\(dy) \(targetPID != nil ? "[Target PID: \(targetPID!)]" : "")"

    case "select_range":
        guard let x1 = (args["from_x"] as? NSNumber)?.doubleValue,
              let y1 = (args["from_y"] as? NSNumber)?.doubleValue,
              let x2 = (args["to_x"] as? NSNumber)?.doubleValue,
              let y2 = (args["to_y"] as? NSNumber)?.doubleValue else {
            return "Error: missing from_x, from_y, to_x, to_y"
        }
        let from = CGPoint(x: x1, y: y1)
        let to = CGPoint(x: x2, y: y2)
        var targetPID: pid_t? = nil
        let app = args["app"] as? String
        if let app = app {
            let apps = NSWorkspace.shared.runningApplications
            if let match = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(app) == true }) {
                targetPID = match.processIdentifier
            }
        } else if let wid = (args["window"] as? NSNumber)?.intValue {
            let wins = getWindowsList(allLayers: true)
            if let win = wins.first(where: { ($0["id"] as? Int) == wid }),
               let p = (win["pid"] as? Int) ?? (win["pid"] as? Int32).map(Int.init) {
                targetPID = pid_t(p)
            }
        }
        let done = (args["done"] as? Bool) ?? false
        selectRangeAction(from: from, to: to, targetPID: targetPID, appName: app, autoClean: done)
        return "Selected range from (\(Int(x1)), \(Int(y1))) to (\(Int(x2)), \(Int(y2)))"

    default:
        return "Unknown tool: \(name)"
    }
}

func runMCPServer() {
    FileHandle.standardError.write("Starting native mcu MCP server (stdio JSON-RPC 2.0)...\n".data(using: .utf8)!)
    while let line = readLine() {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else { continue }
        
        let id = json["id"]
        
        switch method {
        case "initialize":
            let resp: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id ?? 1,
                "result": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": [
                        "tools": [:]
                    ],
                    "serverInfo": [
                        "name": "macos-computer-use",
                        "version": "1.0.0"
                    ]
                ]
            ]
            sendMCPResponse(resp)
            
        case "notifications/initialized":
            break
            
        case "ping":
            let resp: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id ?? 1,
                "result": [:]
            ]
            sendMCPResponse(resp)
            
        case "tools/list":
            let tools: [[String: Any]] = [
                [
                    "name": "click",
                    "description": "Click or double-click at coordinates using virtual cursor with zero hardware mouse disruption and zero focus stealing.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "x": ["type": "number", "description": "X coordinate in screen points"],
                            "y": ["type": "number", "description": "Y coordinate in screen points"],
                            "button": ["type": "string", "enum": ["left", "right", "middle"], "default": "left"],
                            "count": ["type": "integer", "default": 1],
                            "app": ["type": "string", "description": "Target application name if background"],
                            "done": ["type": "boolean", "description": "Automatically clean up after click", "default": false]
                        ],
                        "required": ["x", "y"]
                    ]
                ],
                [
                    "name": "move",
                    "description": "Smoothly glide the virtual cursor to target coordinates.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "x": ["type": "number"],
                            "y": ["type": "number"]
                        ],
                        "required": ["x", "y"]
                    ]
                ],
                [
                    "name": "type",
                    "description": "Type text into target application without stealing focus.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "app": ["type": "string"]
                        ],
                        "required": ["text"]
                    ]
                ],
                [
                    "name": "key",
                    "description": "Press a key by name (return, tab, space, escape, etc.)",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "app": ["type": "string"]
                        ],
                        "required": ["name"]
                    ]
                ],
                [
                    "name": "screen_capture",
                    "description": "Capture screenshot with coordinates.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "output": ["type": "string", "default": "/tmp/mcu_screen.png"],
                            "window": ["type": "integer"],
                            "rect": ["type": "string"]
                        ]
                    ]
                ],
                [
                    "name": "window_capture",
                    "description": "Capture an isolated, full-content screenshot of a specific window even when it is in the background or completely overshadowed/occluded by foreground applications. Supports targeting by app name or window ID.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "app": ["type": "string", "description": "Target application name (e.g. 'iTerm2', 'Terminal', 'OpenChamber', 'Safari')"],
                            "window": ["type": "integer", "description": "Target window ID"],
                            "output": ["type": "string", "description": "Output image file path (default: /tmp/mcu_window_<wid>.png)"],
                            "scale_1x": ["type": "boolean", "description": "Scale Retina to logical points resolution (default: true)", "default": true]
                        ]
                    ]
                ],
                [
                    "name": "ocr",
                    "description": "Perform high-speed Apple Vision OCR on a background window or full screen to recognize all visible text with exact bounding boxes and center coordinates.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "app": ["type": "string", "description": "Target application name"],
                            "window": ["type": "integer", "description": "Target window ID"],
                            "fast": ["type": "boolean", "description": "Use fast OCR mode (default true)", "default": true]
                        ]
                    ]
                ],
                [
                    "name": "click_text",
                    "description": "Semantically find and click text inside a background window or on screen using Apple Vision OCR with virtual cursor animation and zero user disruption.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "query": ["type": "string", "description": "Text substring or phrase to find and click"],
                            "app": ["type": "string", "description": "Target application name"],
                            "window": ["type": "integer", "description": "Target window ID"],
                            "button": ["type": "string", "enum": ["left", "right", "middle"], "default": "left"],
                            "count": ["type": "integer", "default": 1],
                            "done": ["type": "boolean", "description": "Automatically clean up after click", "default": false]
                        ],
                        "required": ["query"]
                    ]
                ],
                [
                    "name": "scroll",
                    "description": "Scroll wheel delta in a background window or at specific coordinates without stealing focus.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "dy": ["type": "integer", "description": "Vertical scroll delta (positive = up, negative = down)"],
                            "dx": ["type": "integer", "description": "Horizontal scroll delta", "default": 0],
                            "x": ["type": "number", "description": "X coordinate in screen points"],
                            "y": ["type": "number", "description": "Y coordinate in screen points"],
                            "app": ["type": "string", "description": "Target application name"],
                            "window": ["type": "integer", "description": "Target window ID"],
                            "done": ["type": "boolean", "default": false]
                        ],
                        "required": ["dy"]
                    ]
                ],
                [
                    "name": "select_range",
                    "description": "Select a range of text or perform a drag selection in a background window without stealing focus.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "from_x": ["type": "number"],
                            "from_y": ["type": "number"],
                            "to_x": ["type": "number"],
                            "to_y": ["type": "number"],
                            "app": ["type": "string"],
                            "window": ["type": "integer"],
                            "done": ["type": "boolean", "default": false]
                        ],
                        "required": ["from_x", "from_y", "to_x", "to_y"]
                    ]
                ],
                [
                    "name": "pip_show",
                    "description": "Show live PiP preview stream of a target window.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "app": ["type": "string"],
                            "window": ["type": "integer"]
                        ]
                    ]
                ],
                [
                    "name": "pip_hide",
                    "description": "Close all active PiP live previews.",
                    "inputSchema": ["type": "object", "properties": [:]]
                ],
                [
                    "name": "window_list",
                    "description": "List all on-screen windows with IDs, titles, bounds, and apps.",
                    "inputSchema": ["type": "object", "properties": [:]]
                ],
                [
                    "name": "done",
                    "description": "Complete computer use session and clean up PiP and virtual cursor.",
                    "inputSchema": ["type": "object", "properties": [:]]
                ],
                [
                    "name": "hotkey",
                    "description": "Trigger a shortcut combo like 'cmd+shift+n' directly in target application without stealing focus.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "combo": ["type": "string", "description": "Shortcut combo (e.g. 'cmd+shift+n', 'cmd+t', 'cmd+c')"],
                            "app": ["type": "string", "description": "Target application name"],
                            "window": ["type": "integer", "description": "Target window ID"]
                        ],
                        "required": ["combo"]
                    ]
                ],
                [
                    "name": "browser_open",
                    "description": "Open a URL in a browser (Safari/Chrome) completely in the background without stealing focus, with optional private/incognito mode and live PiP oversight.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "url": ["type": "string", "description": "URL to open"],
                            "app": ["type": "string", "description": "Browser name (default 'Safari')", "default": "Safari"],
                            "private": ["type": "boolean", "description": "Open in Private/Incognito mode (default false)", "default": false]
                        ],
                        "required": ["url"]
                    ]
                ]
            ]
            let resp: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id ?? 1,
                "result": [
                    "tools": tools
                ]
            ]
            sendMCPResponse(resp)
            
        case "tools/call":
            let params = json["params"] as? [String: Any] ?? [:]
            let toolName = params["name"] as? String ?? ""
            let toolArgs = params["arguments"] as? [String: Any] ?? [:]
            let resultText = handleMCPToolCall(name: toolName, args: toolArgs)
            let resp: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id ?? 1,
                "result": [
                    "content": [
                        [
                            "type": "text",
                            "text": resultText
                        ]
                    ]
                ]
            ]
            sendMCPResponse(resp)
            
        default:
            let resp: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id ?? 1,
                "error": [
                    "code": -32601,
                    "message": "Method not found: \(method)"
                ]
            ]
            sendMCPResponse(resp)
        }
    }
}

let args = CommandLine.arguments

guard args.count >= 2 else {
    printUsage()
    exit(0)
}

let command = args[1]
let subCommand = args.count >= 3 ? args[2] : ""

switch command {
case "mcp":
    runMCPServer()

case "done", "cleanup":
    VirtualCursorClient.done()
    print("Agent operation completed. All PiP previews and virtual cursor dismissed natively.")

case "ocr":
    var targetWID: CGWindowID? = nil
    var targetApp: String? = nil
    var fast = true
    var asJSON = false
    var i = 2
    while i < args.count {
        if (args[i] == "--window" || args[i] == "--wid" || args[i] == "-w"), i + 1 < args.count {
            if let w = Int(args[i + 1]) { targetWID = CGWindowID(w) }
            i += 1
        } else if (args[i] == "--app" || args[i] == "-a"), i + 1 < args.count {
            targetApp = args[i + 1]
            i += 1
        } else if args[i] == "--accurate" {
            fast = false
        } else if args[i] == "--fast" {
            fast = true
        } else if args[i] == "--json" {
            asJSON = true
        }
        i += 1
    }
    if targetWID == nil, let app = targetApp {
        targetWID = PiPWindowController.firstWindowID(matchingApp: app)
    }
    guard let capture = (targetWID != nil ? VisionOCREngine.captureWindowImage(windowID: targetWID!) : VisionOCREngine.captureScreenImage()) else {
        fputs("Error: Failed to capture target image for OCR\n", stderr)
        exit(1)
    }
    let (items, _) = VisionOCREngine.recognize(cgImage: capture.image, bounds: capture.bounds, fast: fast)
    if asJSON {
        if let data = try? JSONSerialization.data(withJSONObject: items.map { [
            "text": $0.text, "confidence": $0.confidence, "x": $0.x, "y": $0.y, "width": $0.width, "height": $0.height, "center_x": $0.centerX, "center_y": $0.centerY
        ] }, options: .prettyPrinted), let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } else {
        print("Recognized \(items.count) text elements:")
        for (idx, item) in items.enumerated() {
            print("[\(idx)] \"\(item.text)\" at (\(Int(item.centerX)), \(Int(item.centerY))) [conf: \(String(format: "%.2f", item.confidence))]")
        }
    }

case "click":
    if subCommand == "text" {
        guard args.count >= 4 else {
            fputs("Usage: mcu click text <query> [--app <name>] [--window <wid>] [--button <left|right|middle>] [--count <n>] [--done]\n", stderr)
            exit(1)
        }
        let query = args[3]
        var targetApp: String? = nil
        var targetWID: CGWindowID? = nil
        var btn: CGMouseButton = .left
        var count = 1
        var autoClean = false
        var i = 4
        while i < args.count {
            if args[i] == "--app", i + 1 < args.count { targetApp = args[i + 1]; i += 1 }
            else if (args[i] == "--window" || args[i] == "--wid"), i + 1 < args.count {
                if let w = Int(args[i + 1]) { targetWID = CGWindowID(w) }
                i += 1
            } else if args[i] == "--button", i + 1 < args.count {
                switch args[i + 1].lowercased() {
                case "right": btn = .right
                case "middle", "center": btn = .center
                default: btn = .left
                }
                i += 1
            } else if args[i] == "--count", i + 1 < args.count {
                count = Int(args[i + 1]) ?? 1
                i += 1
            } else if args[i] == "--done" || args[i] == "--clean" {
                autoClean = true
            }
            i += 1
        }
        let res = clickText(query: query, appName: targetApp, windowID: targetWID, button: btn, clickCount: count, autoClean: autoClean)
        print(res.message)
    } else {
        print("Use: mcu click text <query> or mcu mouse click <x> <y>")
    }

case "select":
    if subCommand == "range" {
        guard args.count >= 7,
              let x1 = Double(args[3]),
              let y1 = Double(args[4]),
              let x2 = Double(args[5]),
              let y2 = Double(args[6]) else {
            fputs("Usage: mcu select range <x1> <y1> <x2> <y2> [--app <name>] [--window <wid>] [--pid <pid>] [--done]\n", stderr)
            exit(1)
        }
        var targetApp: String? = nil
        var targetPID: pid_t? = nil
        var autoClean = false
        var i = 7
        while i < args.count {
            if args[i] == "--app", i + 1 < args.count { targetApp = args[i + 1]; i += 1 }
            else if args[i] == "--pid", i + 1 < args.count { if let p = Int32(args[i + 1]) { targetPID = p }; i += 1 }
            else if (args[i] == "--window" || args[i] == "--wid"), i + 1 < args.count {
                if let wid = Int(args[i + 1]) {
                    let wins = getWindowsList(allLayers: true)
                    if let win = wins.first(where: { ($0["id"] as? Int) == wid }),
                       let p = (win["pid"] as? Int) ?? (win["pid"] as? Int32).map(Int.init) {
                        targetPID = pid_t(p)
                    }
                }
                i += 1
            } else if args[i] == "--done" || args[i] == "--clean" {
                autoClean = true
            }
            i += 1
        }
        selectRangeAction(from: CGPoint(x: x1, y: y1), to: CGPoint(x: x2, y: y2), targetPID: targetPID, appName: targetApp, autoClean: autoClean)
    } else {
        print("Usage: mcu select range <x1> <y1> <x2> <y2>")
    }

// MARK: Cursor Daemon Subcommand (Internal)
case "cursor-daemon":
    let daemon = FancyCursorDaemon()
    daemon.start()

// MARK: Cursor Commands
case "cursor":
    switch subCommand {
    case "start":
        VirtualCursorClient.ensureDaemonRunning()
        print("Fancy virtual cursor overlay initiated.")
    case "stop":
        VirtualCursorClient.stop()
        print("Fancy virtual cursor overlay terminated.")
    case "move":
        guard args.count >= 5, let x = Double(args[3]), let y = Double(args[4]) else {
            fputs("Usage: mcu cursor move <x> <y> [--speed slow|normal|fast] [--duration <sec>]\n", stderr)
            exit(1)
        }
        var speed: String? = nil
        var dur: Double? = nil
        var i = 5
        while i < args.count {
            if args[i] == "--speed", i + 1 < args.count { speed = args[i + 1]; i += 1 }
            else if args[i] == "--duration", i + 1 < args.count { dur = Double(args[i + 1]); i += 1 }
            i += 1
        }
        moveMouseVirtual(to: CGPoint(x: x, y: y), speed: speed, duration: dur)
    case "done":
        VirtualCursorClient.done()
        print("Agent control completed. Virtual cursor and PiP window dismissed.")
    case "ripple":
        guard args.count >= 5, let x = Double(args[3]), let y = Double(args[4]) else {
            fputs("Usage: mcu cursor ripple <x> <y>\n", stderr)
            exit(1)
        }
        VirtualCursorClient.click(at: CGPoint(x: x, y: y))
        print("Visual click ripple emitted at (\(Int(x)), \(Int(y)))")
    case "glow":
        guard args.count >= 4 else {
            fputs("Usage: mcu cursor glow <cyan|emerald|violet|amber|crimson>\n", stderr)
            exit(1)
        }
        VirtualCursorClient.glow(color: args[3])
        print("Cursor glow theme changed to '\(args[3])'")
    case "hide":
        VirtualCursorClient.hide()
        print("Virtual cursor hidden.")
    case "show":
        VirtualCursorClient.show()
        print("Virtual cursor displayed.")
    default:
        printUsage()
    }

// MARK: Picture-in-Picture (PiP) Commands
case "pip":
    switch subCommand {
    case "show", "start", "open":
        var app: String? = nil
        var wid: Int? = nil
        var anchorPID: pid_t? = nil
        var i = 3
        while i < args.count {
            if args[i] == "--app", i + 1 < args.count { app = args[i + 1]; i += 1 }
            else if (args[i] == "--window" || args[i] == "--window-id"), i + 1 < args.count { wid = Int(args[i + 1]); i += 1 }
            else if args[i] == "--anchor-pid", i + 1 < args.count { anchorPID = pid_t(args[i + 1]); i += 1 }
            i += 1
        }
        VirtualCursorClient.pipShow(appName: app, windowID: wid, anchorPID: anchorPID)
        print("PiP live preview activated for '\(app ?? (wid != nil ? "Window \(wid!)" : "Active Window"))'")
    case "hide", "stop", "close":
        var wid: Int? = nil
        if let i = args.firstIndex(where: { $0 == "--window" || $0 == "--window-id" }), i + 1 < args.count { wid = Int(args[i + 1]) }
        VirtualCursorClient.pipHide(windowID: wid)
        print(wid.map { "PiP for window \($0) closed." } ?? "All PiP live previews closed.")
    case "dock":
        let side = (args.contains("--left") || args.contains("left")) ? "left" : "right"
        VirtualCursorClient.pipDock(side: side)
        print("PiP live preview docked to \(side) edge.")
    case "undock":
        VirtualCursorClient.pipUndock()
        print("PiP live preview undocked to resting slot.")
    case "status":
        print("PiP live preview is managed by cursor-daemon.")
    default:
        printUsage()
    }

// MARK: Emergency Controls
case "emergency":
    switch subCommand {
    case "stop":
        try? "EMERGENCY_HALT".write(toFile: kDefaultKillSwitchPath, atomically: true, encoding: .utf8)
        VirtualCursorClient.glow(color: "crimson")
        AccessControlEngine.logAudit(action: "emergency_stop", decision: "KILL_SWITCH_ENGAGED", reason: "User triggered emergency stop")
        print("EMERGENCY KILL SWITCH ENGAGED! All agent actions are now frozen.")
    case "resume":
        try? FileManager.default.removeItem(atPath: kDefaultKillSwitchPath)
        VirtualCursorClient.glow(color: "cyan")
        AccessControlEngine.logAudit(action: "emergency_resume", decision: "KILL_SWITCH_CLEARED")
        print("Emergency kill switch cleared. Normal operation resumed.")
    case "status":
        let active = AccessControlEngine.isKillSwitchActive()
        print("Emergency kill switch status: \(active ? "ACTIVE (BLOCKED)" : "CLEAR (OPERATIONAL)")")
    default:
        printUsage()
    }

// MARK: Access Policy & Audit
case "access":
    switch subCommand {
    case "policy":
        if let data = try? JSONSerialization.data(withJSONObject: AccessControlEngine.config, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    default:
        printUsage()
    }

case "audit":
    switch subCommand {
    case "tail":
        let count = (args.count >= 4 && args[3] == "--n" && args.count >= 5) ? (Int(args[4]) ?? 10) : 10
        let logPath = ((AccessControlEngine.config["audit_logging"] as? [String: Any])?["log_path"] as? String ?? kDefaultAuditLogPath)
        let resolved = (logPath as NSString).expandingTildeInPath
        if let content = try? String(contentsOfFile: resolved, encoding: .utf8) {
            let lines = content.split(separator: "\n").suffix(count)
            for line in lines { print(line) }
        } else {
            print("No audit log found at \(resolved)")
        }
    default:
        printUsage()
    }

// MARK: Screen Commands
case "screen":
    switch subCommand {
    case "info":
        print(getScreenInfoJSON())
    case "capture":
        var output = "/tmp/mcu_screen.png"
        var scale1x = false
        var withGrid = false
        var withCursor = false
        var windowID: CGWindowID? = nil
        var rect: CGRect? = nil
        
        var i = 3
        while i < args.count {
            switch args[i] {
            case "--output":
                if i + 1 < args.count { output = args[i + 1]; i += 1 }
            case "--scale-1x":
                scale1x = true
            case "--grid":
                withGrid = true
            case "--cursor":
                withCursor = true
            case "--window":
                if i + 1 < args.count, let wid = UInt32(args[i + 1]) { windowID = wid; i += 1 }
            case "--app":
                if i + 1 < args.count {
                    let appName = args[i + 1]
                    windowID = PiPWindowController.firstWindowID(matchingApp: appName)
                    i += 1
                }
            case "--rect":
                if i + 1 < args.count {
                    let parts = args[i + 1].split(separator: ",").compactMap { Double($0) }
                    if parts.count == 4 {
                        rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                    }
                    i += 1
                }
            default:
                break
            }
            i += 1
        }
        captureScreen(output: output, scale1x: scale1x, withGrid: withGrid, windowID: windowID, rect: rect, includeCursor: withCursor)
    default:
        printUsage()
    }

// MARK: Window Commands
case "window":
    switch subCommand {
    case "list":
        let all = args.contains("--all")
        let windows = getWindowsList(allLayers: all)
        if let data = try? JSONSerialization.data(withJSONObject: windows, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    case "capture":
        var targetWID: CGWindowID? = nil
        var targetApp: String? = nil
        var output = "/tmp/mcu_window_capture.png"
        var scale1x = true
        var i = 3
        if i < args.count && !args[i].hasPrefix("-") {
            if let w = Int(args[i]) {
                targetWID = CGWindowID(w)
            } else {
                targetApp = args[i]
            }
            i += 1
        }
        while i < args.count {
            if (args[i] == "--window" || args[i] == "--wid" || args[i] == "-w"), i + 1 < args.count {
                if let w = Int(args[i + 1]) { targetWID = CGWindowID(w) }
                i += 1
            } else if (args[i] == "--app" || args[i] == "-a"), i + 1 < args.count {
                targetApp = args[i + 1]
                i += 1
            } else if (args[i] == "--output" || args[i] == "-o"), i + 1 < args.count {
                output = args[i + 1]
                i += 1
            } else if args[i] == "--no-scale" || args[i] == "--scale-2x" {
                scale1x = false
            }
            i += 1
        }
        if targetWID == nil, let app = targetApp {
            targetWID = PiPWindowController.firstWindowID(matchingApp: app)
        }
        guard let wid = targetWID else {
            fputs("Error: Must specify a target window ID or application name (e.g. mcu window capture --app <name> or mcu window capture <wid>)\n", stderr)
            exit(1)
        }
        captureScreen(output: output, scale1x: scale1x, withGrid: false, windowID: wid, rect: nil, includeCursor: false)
        print("Captured background window \(wid) to \(output) [Overshadowed background isolated]")
    case "focus":
        guard args.count >= 4 else {
            fputs("Usage: mcu window focus <app|pid|wid>\n", stderr)
            exit(1)
        }
        _ = focusTarget(args[3])
    case "move":
        guard args.count >= 8,
              let wid = Int(args[3]),
              let x = Double(args[4]),
              let y = Double(args[5]),
              let w = Double(args[6]),
              let h = Double(args[7]) else {
            fputs("Usage: mcu window move <wid> <x> <y> <w> <h>\n", stderr)
            exit(1)
        }
        let windows = getWindowsList(allLayers: true)
        if let targetWin = windows.first(where: { ($0["id"] as? Int) == wid }),
           let pidInt = (targetWin["pid"] as? Int) ?? (targetWin["pid"] as? Int32).map(Int.init) {
            let pid = pid_t(pidInt)
            let appEl = AXUIElementCreateApplication(pid)
            if let winElements = getAttribute(appEl, kAXWindowsAttribute) as? [AXUIElement] {
                let targetEl: AXUIElement? = winElements.first(where: { el in
                    var id: CGWindowID = 0
                    return _AXUIElementGetWindow(el, &id) == .success && Int(id) == wid
                }) ?? winElements.first
                if let winEl = targetEl {
                    var pos = CGPoint(x: x, y: y)
                    var size = CGSize(width: w, height: h)
                    if let posVal = AXValueCreate(.cgPoint, &pos) {
                        AXUIElementSetAttributeValue(winEl, kAXPositionAttribute as CFString, posVal)
                    }
                    if let sizeVal = AXValueCreate(.cgSize, &size) {
                        AXUIElementSetAttributeValue(winEl, kAXSizeAttribute as CFString, sizeVal)
                    }
                    print("Window \(wid) resized and moved to (\(Int(x)), \(Int(y)), \(Int(w)), \(Int(h)))")
                }
            }
        }
    case "resize":
        guard args.count >= 6,
              let wid = Int(args[3]),
              let targetW = Double(args[4]),
              let targetH = Double(args[5]) else {
            fputs("Usage: mcu window resize <wid> <w> <h> [--duration <sec>]\n", stderr)
            exit(1)
        }
        var dur = 0.6
        var i = 6
        while i < args.count {
            if args[i] == "--duration", i + 1 < args.count {
                dur = Double(args[i + 1]) ?? 0.6
                i += 1
            }
            i += 1
        }
        resizeWindowWithVirtualCursor(windowID: wid, targetWidth: targetW, targetHeight: targetH, duration: dur)
    default:
        printUsage()
    }

// MARK: Accessibility Commands
case "ax":
    switch subCommand {
    case "dump":
        var appName: String? = nil
        var pid: Int32? = nil
        var maxDepth = 4
        var i = 3
        while i < args.count {
            if args[i] == "--app", i + 1 < args.count { appName = args[i + 1]; i += 1 }
            else if args[i] == "--pid", i + 1 < args.count { pid = Int32(args[i + 1]); i += 1 }
            else if args[i] == "--depth", i + 1 < args.count { maxDepth = Int(args[i + 1]) ?? 4; i += 1 }
            i += 1
        }
        guard let appEl = getAppElement(appName: appName, pid: pid) else {
            fputs("Error: Could not locate target application\n", stderr)
            exit(1)
        }
        if let dict = axElementToDict(appEl, depth: 0, maxDepth: maxDepth),
           let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
        
    case "find":
        var appName: String? = nil
        var pid: Int32? = nil
        var role: String? = nil
        var title: String? = nil
        var contains: String? = nil
        var i = 3
        while i < args.count {
            if args[i] == "--app", i + 1 < args.count { appName = args[i + 1]; i += 1 }
            else if args[i] == "--pid", i + 1 < args.count { pid = Int32(args[i + 1]); i += 1 }
            else if args[i] == "--role", i + 1 < args.count { role = args[i + 1]; i += 1 }
            else if args[i] == "--title", i + 1 < args.count { title = args[i + 1]; i += 1 }
            else if args[i] == "--contains", i + 1 < args.count { contains = args[i + 1]; i += 1 }
            i += 1
        }
        guard let appEl = getAppElement(appName: appName, pid: pid) else {
            fputs("Error: Could not locate target application\n", stderr)
            exit(1)
        }
        var results: [[String: Any]] = []
        findAXElementsRecursively(appEl, roleFilter: role, titleFilter: title, containsText: contains, results: &results)
        if let data = try? JSONSerialization.data(withJSONObject: results, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
        
    case "click":
        var appName: String? = nil
        var pid: Int32? = nil
        var role: String? = nil
        var title: String? = nil
        var i = 3
        while i < args.count {
            if args[i] == "--app", i + 1 < args.count { appName = args[i + 1]; i += 1 }
            else if args[i] == "--pid", i + 1 < args.count { pid = Int32(args[i + 1]); i += 1 }
            else if args[i] == "--role", i + 1 < args.count { role = args[i + 1]; i += 1 }
            else if args[i] == "--title", i + 1 < args.count { title = args[i + 1]; i += 1 }
            i += 1
        }
        
        // Access Control check
        let validation = AccessControlEngine.validate(action: "ax_click", targetApp: appName)
        if !validation.allowed {
            VirtualCursorClient.glow(color: "crimson")
            fputs("\(validation.reason)\n", stderr)
            AccessControlEngine.logAudit(action: "ax_click", targetApp: appName, decision: "BLOCKED", reason: validation.reason)
            exit(1)
        }
        
        guard let appEl = getAppElement(appName: appName, pid: pid) else {
            fputs("Error: Target application not found\n", stderr)
            exit(1)
        }
        
        func findAndPress(_ el: AXUIElement) -> Bool {
            let elRole = getAttribute(el, kAXRoleAttribute) as? String ?? ""
            let elTitle = getAttribute(el, kAXTitleAttribute) as? String ?? ""
            var match = true
            if let r = role, !r.isEmpty, !elRole.localizedCaseInsensitiveContains(r) { match = false }
            if let t = title, !t.isEmpty, !elTitle.localizedCaseInsensitiveContains(t) { match = false }
            
            if match && (role != nil || title != nil) {
                // If element has a frame, show our fancy cursor gliding over!
                if let frame = getElementFrame(el) {
                    let center = CGPoint(x: frame.origin.x + frame.size.width / 2.0, y: frame.origin.y + frame.size.height / 2.0)
                    VirtualCursorClient.click(at: center, button: "left")
                }
                
                let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
                if err == .success {
                    AccessControlEngine.logAudit(action: "ax_click", targetApp: appName, details: "Role='\(elRole)', Title='\(elTitle)'")
                    print("Pressed element via AXPress: Role='\(elRole)', Title='\(elTitle)' [Hardware mouse never moved!]")
                    return true
                }
            }
            if let children = getAttribute(el, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children {
                    if findAndPress(child) { return true }
                }
            }
            return false
        }
        
        if !findAndPress(appEl) {
            fputs("Error: Matching AX element not found or press action failed\n", stderr)
            exit(1)
        }
        
    case "inspect":
        guard args.count >= 5,
              let x = Float(args[3]),
              let y = Float(args[4]) else {
            fputs("Usage: mcu ax inspect <x> <y>\n", stderr)
            exit(1)
        }
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, x, y, &element)
        if err == .success, let el = element {
            let role = getAttribute(el, kAXRoleAttribute) as? String ?? ""
            let title = getAttribute(el, kAXTitleAttribute) as? String ?? ""
            let desc = getAttribute(el, kAXDescriptionAttribute) as? String ?? ""
            let val = getAttribute(el, kAXValueAttribute) as? String ?? ""
            let frame = getElementFrame(el) ?? .zero
            
            let res: [String: Any] = [
                "role": role,
                "title": title,
                "description": desc,
                "value": val,
                "frame": [
                    "x": frame.origin.x, "y": frame.origin.y,
                    "width": frame.size.width, "height": frame.size.height
                ]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: res, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            print("{\"error\": \"No element found at (\(x), \(y))\"}")
        }
    default:
        printUsage()
    }

// MARK: Mouse Commands (Non-Disruptive)
case "mouse":
    switch subCommand {
    case "pos":
        let pt = getMousePosition()
        print("\(Int(pt.x)),\(Int(pt.y))")
    case "move":
        guard args.count >= 5,
              let x = Double(args[3]),
              let y = Double(args[4]) else {
            fputs("Usage: mcu mouse move <x> <y> [--speed slow|normal|fast] [--duration <sec>]\n", stderr)
            exit(1)
        }
        var speed: String? = nil
        var dur: Double? = nil
        var i = 5
        while i < args.count {
            if args[i] == "--speed", i + 1 < args.count { speed = args[i + 1]; i += 1 }
            else if args[i] == "--duration", i + 1 < args.count { dur = Double(args[i + 1]); i += 1 }
            i += 1
        }
        // Move the fancy virtual cursor!
        moveMouseVirtual(to: CGPoint(x: x, y: y), speed: speed, duration: dur)
        
    case "click":
        var x: Double? = nil
        var y: Double? = nil
        var btn: CGMouseButton = .left
        var count = 1
        var restoreCursor = true
        var targetPID: pid_t? = nil
        var autoClean = false
        
        var i = 3
        if i < args.count, let px = Double(args[i]) { x = px; i += 1 }
        if i < args.count, let py = Double(args[i]) { y = py; i += 1 }
        
        while i < args.count {
            if args[i] == "--button", i + 1 < args.count {
                switch args[i + 1].lowercased() {
                case "right": btn = .right
                case "middle", "center": btn = .center
                default: btn = .left
                }
                i += 1
            } else if args[i] == "--count", i + 1 < args.count {
                count = Int(args[i + 1]) ?? 1
                i += 1
            } else if args[i] == "--no-restore" {
                restoreCursor = false
            } else if args[i] == "--done" || args[i] == "--clean" {
                autoClean = true
            } else if args[i] == "--pid", i + 1 < args.count {
                if let p = Int32(args[i + 1]) { targetPID = p }
                i += 1
            } else if args[i] == "--window", i + 1 < args.count {
                if let wid = Int(args[i + 1]) {
                    let wins = getWindowsList(allLayers: true)
                    if let win = wins.first(where: { ($0["id"] as? Int) == wid }),
                       let p = (win["pid"] as? Int) ?? (win["pid"] as? Int32).map(Int.init) {
                        targetPID = pid_t(p)
                    }
                }
                i += 1
            } else if args[i] == "--app", i + 1 < args.count {
                let appName = args[i + 1]
                let apps = NSWorkspace.shared.runningApplications
                if let match = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(appName) == true }) {
                    targetPID = match.processIdentifier
                }
                i += 1
            }
            i += 1
        }
        let pt = (x != nil && y != nil) ? CGPoint(x: x!, y: y!) : nil
        clickMouseNonDisruptive(at: pt, button: btn, clickCount: count, restoreCursor: restoreCursor, targetPID: targetPID)
        if autoClean {
            usleep(300000)
            VirtualCursorClient.done()
        }
        
    case "drag":
        guard args.count >= 7,
              let x1 = Double(args[3]),
              let y1 = Double(args[4]),
              let x2 = Double(args[5]),
              let y2 = Double(args[6]) else {
            fputs("Usage: mcu mouse drag <x1> <y1> <x2> <y2> [--duration <sec>] [--no-restore]\n", stderr)
            exit(1)
        }
        var dur = 0.4
        var restore = true
        var i = 7
        while i < args.count {
            if args[i] == "--duration", i + 1 < args.count { dur = Double(args[i + 1]) ?? 0.4; i += 1 }
            else if args[i] == "--no-restore" { restore = false }
            i += 1
        }
        dragMouse(from: CGPoint(x: x1, y: y1), to: CGPoint(x: x2, y: y2), duration: dur, restoreCursor: restore)
        
    case "scroll":
        var dy: Int32 = 0
        var dx: Int32 = 0
        var x: Double? = nil
        var y: Double? = nil
        var targetPID: pid_t? = nil
        var autoClean = false
        var i = 3
        if i < args.count, let v = Int32(args[i]) {
            dy = v
            i += 1
            if i < args.count, let v2 = Int32(args[i]) {
                dx = dy
                dy = v2
                i += 1
            }
        }
        while i < args.count {
            if args[i] == "--dy", i + 1 < args.count { dy = Int32(args[i + 1]) ?? 0; i += 1 }
            else if args[i] == "--dx", i + 1 < args.count { dx = Int32(args[i + 1]) ?? 0; i += 1 }
            else if args[i] == "--x", i + 1 < args.count { x = Double(args[i + 1]); i += 1 }
            else if args[i] == "--y", i + 1 < args.count { y = Double(args[i + 1]); i += 1 }
            else if args[i] == "--pid", i + 1 < args.count { if let p = Int32(args[i + 1]) { targetPID = p }; i += 1 }
            else if args[i] == "--window", i + 1 < args.count {
                if let wid = Int(args[i + 1]) {
                    let wins = getWindowsList(allLayers: true)
                    if let win = wins.first(where: { ($0["id"] as? Int) == wid }),
                       let p = (win["pid"] as? Int) ?? (win["pid"] as? Int32).map(Int.init) {
                        targetPID = pid_t(p)
                    }
                }
                i += 1
            } else if args[i] == "--app", i + 1 < args.count {
                let appName = args[i + 1]
                let apps = NSWorkspace.shared.runningApplications
                if let match = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(appName) == true }) {
                    targetPID = match.processIdentifier
                }
                i += 1
            } else if args[i] == "--done" || args[i] == "--clean" {
                autoClean = true
            }
            i += 1
        }
        let pt = (x != nil && y != nil) ? CGPoint(x: x!, y: y!) : nil
        scrollWheel(dx: dx, dy: dy, at: pt, targetPID: targetPID)
        if autoClean {
            usleep(250000)
            VirtualCursorClient.done()
        }
    default:
        printUsage()
    }

// MARK: Keyboard Commands
case "keyboard":
    switch subCommand {
    case "type":
        guard args.count >= 4 else {
            fputs("Usage: mcu keyboard type <text> [--app <name>] [--window <wid>] [--pid <pid>]\n", stderr)
            exit(1)
        }
        var targetPID: pid_t? = nil
        var textTokens: [String] = []
        var i = 3
        while i < args.count {
            if args[i] == "--pid", i + 1 < args.count {
                if let p = Int32(args[i + 1]) { targetPID = p }
                i += 1
            } else if args[i] == "--window", i + 1 < args.count {
                if let wid = Int(args[i + 1]) {
                    let wins = getWindowsList(allLayers: true)
                    if let win = wins.first(where: { ($0["id"] as? Int) == wid }),
                       let p = (win["pid"] as? Int) ?? (win["pid"] as? Int32).map(Int.init) {
                        targetPID = pid_t(p)
                    }
                }
                i += 1
            } else if args[i] == "--app", i + 1 < args.count {
                let appName = args[i + 1]
                let apps = NSWorkspace.shared.runningApplications
                if let match = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(appName) == true }) {
                    targetPID = match.processIdentifier
                }
                i += 1
            } else {
                textTokens.append(args[i])
            }
            i += 1
        }
        let text = textTokens.joined(separator: " ")
        typeString(text, targetPID: targetPID)
    case "key":
        guard args.count >= 4 else {
            fputs("Usage: mcu keyboard key <name> [--app <name>] [--window <wid>] [--pid <pid>]\n", stderr)
            exit(1)
        }
        let keyName = args[3].lowercased()
        guard let code = keyNameToKeyCode[keyName] else {
            fputs("Error: Unknown key name '\(keyName)'\n", stderr)
            exit(1)
        }
        var targetPID: pid_t? = nil
        var i = 4
        while i < args.count {
            if args[i] == "--pid", i + 1 < args.count {
                if let p = Int32(args[i + 1]) { targetPID = p }
                i += 1
            } else if args[i] == "--window", i + 1 < args.count {
                if let wid = Int(args[i + 1]) {
                    let wins = getWindowsList(allLayers: true)
                    if let win = wins.first(where: { ($0["id"] as? Int) == wid }),
                       let p = (win["pid"] as? Int) ?? (win["pid"] as? Int32).map(Int.init) {
                        targetPID = pid_t(p)
                    }
                }
                i += 1
            } else if args[i] == "--app", i + 1 < args.count {
                let appName = args[i + 1]
                let apps = NSWorkspace.shared.runningApplications
                if let match = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(appName) == true }) {
                    targetPID = match.processIdentifier
                }
                i += 1
            }
            i += 1
        }
        pressKey(keyCode: code, targetPID: targetPID)
        AccessControlEngine.logAudit(action: "keyboard_key", details: keyName)
        print("Pressed key '\(keyName)' \(targetPID != nil ? "[Target PID: \(targetPID!)] (Overshadowed background delivery)" : "")")
    case "hotkey":
        guard args.count >= 4 else {
            fputs("Usage: mcu keyboard hotkey <combo> [--app <name>] [--window <wid>] [--pid <pid>]\n", stderr)
            exit(1)
        }
        let combo = args[3]
        var targetPID: pid_t? = nil
        var i = 4
        while i < args.count {
            if args[i] == "--pid", i + 1 < args.count {
                if let p = Int32(args[i + 1]) { targetPID = p }
                i += 1
            } else if args[i] == "--window", i + 1 < args.count {
                if let wid = Int(args[i + 1]) {
                    let wins = getWindowsList(allLayers: true)
                    if let win = wins.first(where: { ($0["id"] as? Int) == wid }),
                       let p = (win["pid"] as? Int) ?? (win["pid"] as? Int32).map(Int.init) {
                        targetPID = pid_t(p)
                    }
                }
                i += 1
            } else if args[i] == "--app", i + 1 < args.count {
                let appName = args[i + 1]
                let apps = NSWorkspace.shared.runningApplications
                if let match = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(appName) == true }) {
                    targetPID = match.processIdentifier
                }
                i += 1
            }
            i += 1
        }
        triggerHotkeyCombo(combo, targetPID: targetPID)
    default:
        printUsage()
    }

// MARK: Clipboard Commands
case "clipboard":
    switch subCommand {
    case "get":
        print(getClipboardString())
    case "set":
        guard args.count >= 4 else {
            fputs("Usage: mcu clipboard set <text>\n", stderr)
            exit(1)
        }
        let text = args[3...].joined(separator: " ")
        setClipboardString(text)
        AccessControlEngine.logAudit(action: "clipboard_set", details: "\(text.count) chars")
        print("Clipboard updated")
    default:
        printUsage()
    }

// MARK: Browser Commands (Zero-Focus Background Automation)
case "browser":
    switch subCommand {
    case "open":
        guard args.count >= 4 else {
            fputs("Usage: mcu browser open <url> [--app <Safari|Chrome>] [--private|--incognito]\n", stderr)
            exit(1)
        }
        let url = args[3]
        var appName = "Safari"
        var isPrivate = false
        var i = 4
        while i < args.count {
            if args[i] == "--app", i + 1 < args.count { appName = args[i + 1]; i += 1 }
            else if args[i] == "--private" || args[i] == "--incognito" { isPrivate = true }
            i += 1
        }
        
        let apps = NSWorkspace.shared.runningApplications
        let isRunning = apps.contains(where: { $0.localizedName?.localizedCaseInsensitiveContains(appName) == true })
        if !isRunning {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            if let bundleID = appName.localizedCaseInsensitiveContains("Safari") ? "com.apple.Safari" : nil,
               let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
                sleep(2)
            }
        }
        
        if isPrivate, let match = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(appName) == true }) {
            triggerHotkeyCombo("cmd+shift+n", targetPID: match.processIdentifier)
            usleep(600000)
        }
        
        if appName.localizedCaseInsensitiveContains("Safari") {
            let script = "tell application \"Safari\" to set URL of current tab of front window to \"\(url)\""
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
            }
        }
        VirtualCursorClient.pipShow(appName: appName, windowID: nil)
        print("Opened \(url) in \(appName) \(isPrivate ? "(Private Browsing) " : "")[Zero focus stolen, PiP oversight active]")
    default:
        printUsage()
    }

// MARK: Screenshare & Recording
case "screenshare":
    switch subCommand {
    case "status":
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let str = String(data: data, encoding: .utf8) ?? ""
        let isRunning = str.contains("com.apple.screensharing")
        print("Screen Sharing agent status: \(isRunning ? "Active" : "Inactive")")
    case "open":
        let host = args.count >= 4 ? args[3] : "localhost"
        let url = URL(string: "vnc://\(host)")!
        NSWorkspace.shared.open(url)
        print("Opened Screen Sharing connection to \(host)")
    default:
        printUsage()
    }

case "record":
    switch subCommand {
    case "start":
        let output = args.count >= 4 ? args[3] : "/tmp/mcu_recording.mp4"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-v", output]
        try? task.run()
        let pid = task.processIdentifier
        try? "\(pid)".write(toFile: "/tmp/mcu_record.pid", atomically: true, encoding: .utf8)
        print("Screen recording started in background (PID: \(pid)) -> \(output)")
    case "stop":
        if let pidStr = try? String(contentsOfFile: "/tmp/mcu_record.pid", encoding: .utf8),
           let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGINT)
            try? FileManager.default.removeItem(atPath: "/tmp/mcu_record.pid")
            print("Stopped screen recording (PID: \(pid)). Video saved.")
        } else {
            print("No active screen recording found.")
        }
    default:
        printUsage()
    }

default:
    printUsage()
}
