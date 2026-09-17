// ccmon's desktop widget on macOS - the counterpart of CcmonWidget.cs, which is
// the same panel and the same menu on Windows. Built on the fly by lib/macos.sh
// with the swiftc that ships in the Command Line Tools, for the same reason the
// Windows one is built with csc: nothing to install, and the source is what is
// distributed rather than a binary.
//
// It reads usage-snapshot.json and nothing else. No network, no credentials:
// the poller owns both, and the widget is only ever a view onto its output.
//
// Do not rename this file to main.swift - it is compiled with -parse-as-library
// and an explicit @main, which is what keeps the entry point unambiguous.

import AppKit

// ----------------------------------------------------------------- geometry --

let W: CGFloat = 268, H: CGFloat = 190
let PAD: CGFloat = 16, RADIUS: CGFloat = 16, MARGIN: CGFloat = 24
let WINDOW_5H: TimeInterval = 5 * 3600
let WINDOW_7D: TimeInterval = 7 * 86400

// sRGB explicitly, never calibrated: these hex values are shared with the
// wallboard's CSS, and the calibrated colour space shifts the green and the
// yellow enough to see.
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
let cSurface = rgb(26, 26, 25)
let cText    = rgb(245, 245, 243)
let cMuted   = rgb(143, 142, 134)
let cTrack   = rgb(56, 56, 52)
let cGood    = rgb(25, 158, 112)
let cWarn    = rgb(234, 179, 8)
let cCrit    = rgb(230, 103, 103)
let cBorder  = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 70.0 / 255.0)

// WinForms point sizes render at 96 DPI, where a point is 4/3 of a pixel; on
// macOS a point is the drawing unit itself. The geometry above transfers 1:1,
// so the fonts have to be scaled by that 4/3 to keep the same proportion of
// text to panel: 8.5 -> 11, 21 -> 28, 7.5 -> 10.
let fLabel = NSFont.systemFont(ofSize: 11)
// Monospaced digits for this one only: it is redrawn every refresh, and SF's
// proportional figures make a right-aligned number's left edge twitch.
let fBig   = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
let fSmall = NSFont.systemFont(ofSize: 10)

func toneColor(_ tone: String) -> NSColor {
    switch tone {
    case "good": return cGood
    case "warn": return cWarn
    case "crit": return cCrit
    default:     return cMuted
    }
}

// Ranked so the menu bar, which has one dot for two windows, can show the worse.
func toneRank(_ tone: String) -> Int {
    switch tone {
    case "crit": return 3
    case "warn": return 2
    case "good": return 1
    default:     return 0    // muted: no reading, or a window too young to judge
    }
}

// ----------------------------------------------------------------- snapshot --

struct Snapshot {
    var fiveHour: Double?
    var sevenDay: Double?
    var stale = true
    var reason = ""
    var fetchedAtMs: Double = 0
    var fiveHourResets: TimeInterval = 0      // epoch seconds, 0 when absent
    var sevenDayResets: TimeInterval = 0

    static func read(_ path: String) -> Snapshot? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let d = obj as? [String: Any] else { return nil }
        var s = Snapshot()
        s.fiveHour = num(d["five_hour"])
        s.sevenDay = num(d["seven_day"])
        s.stale = (d["stale"] as? Bool) ?? false
        s.reason = (d["reason"] as? String) ?? ""
        s.fetchedAtMs = num(d["fetchedAtMs"]) ?? num(d["checkedAtMs"]) ?? 0
        s.fiveHourResets = epoch(d["five_hour_resets_at"] as? String)
        s.sevenDayResets = epoch(d["seven_day_resets_at"] as? String)
        return s
    }

    private static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    // DateTimeOffset.Parse was forgiving for free; ISO8601DateFormatter is not.
    // The API emits six fractional digits, which .withFractionalSeconds will not
    // take, and spells UTC as +00:00 - so normalise both away first, exactly as
    // the jq in usage-poll.sh already does for the history rows.
    private static func epoch(_ raw: String?) -> TimeInterval {
        guard var t = raw, !t.isEmpty else { return 0 }
        if let dot = t.firstIndex(of: ".") {
            var i = t.index(after: dot)
            while i < t.endIndex, t[i].isNumber { i = t.index(after: i) }
            t.removeSubrange(dot..<i)
        }
        if t.hasSuffix("+00:00") { t = String(t.dropLast(6)) + "Z" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: t)?.timeIntervalSince1970 ?? 0
    }
}

// --------------------------------------------------------------------- pace --

// The point of the project: not "how much have I used" but "speed up or slow
// down to finish this window at TARGET". Mirrors pace() in chart-lib.js and
// class Pace in CcmonWidget.cs - keep all three in step.
struct Pace {
    static let TARGET: Double = 95
    var paceNow: Double = 0        // where usage would be if spent evenly
    var verdict = "no data"
    var tone = "muted"

    static func of(_ util: Double?, _ resetsAt: TimeInterval, _ windowSec: TimeInterval) -> Pace {
        var p = Pace()
        guard resetsAt > 0 else { return p }
        let now = Date().timeIntervalSince1970
        let remaining = max(0, resetsAt - now)
        let elapsed = min(1, max(0, (windowSec - remaining) / windowSec))
        p.paceNow = TARGET * elapsed
        guard let u = util else { return p }

        let headroom = TARGET - u
        if u >= TARGET    { p.verdict = "over budget";   p.tone = "crit"; return p }
        if remaining <= 0 { p.verdict = "window closed";                 return p }
        if elapsed < 0.05 { p.verdict = "just reset";                    return p }

        let rateNow = u / elapsed
        let rateNeeded = headroom / max(1e-6, 1 - elapsed)
        let f = rateNow > 0 ? rateNeeded / rateNow : Double.infinity

        // The factor explodes at both ends of a window, so cap what is shown.
        if f.isInfinite || f >= 3 { p.verdict = "burn freely"; p.tone = "good" }
        else if f > 1.15  { p.verdict = String(format: "faster %.1fx", f);    p.tone = "good" }
        else if f >= 0.85 { p.verdict = "on pace";                            p.tone = "good" }
        else if f >= 0.5  { p.verdict = String(format: "ease off %.1fx", f);  p.tone = "warn" }
        else              { p.verdict = String(format: "slow down %.1fx", f); p.tone = "crit" }
        return p
    }

    // Mirrors resetPhrase() in chart-lib.js. Sub-minute counts down in seconds
    // rather than collapsing to a useless "now"; once the reset time has passed,
    // which it can between the rollover and the next poll, it states when.
    static func phrase(_ resetsAt: TimeInterval) -> String {
        let d = Int(resetsAt - Date().timeIntervalSince1970)
        if d <= 0 {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return "reset at " + f.string(from: Date(timeIntervalSince1970: resetsAt))
        }
        if d >= 86400 { return "resets in \(d / 86400)d \(d % 86400 / 3600)h" }
        if d >= 3600  { return "resets in \(d / 3600)h \(d % 3600 / 60)m" }
        if d >= 60    { return "resets in \(d / 60)m" }
        return "resets in \(d)s"
    }
}

// ------------------------------------------------------------------- window --

// Lives on the desktop: never in Cmd-Tab, never takes focus, no Dock icon.
final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PanelView: NSView {
    var data: Snapshot?
    var everRead = false
    var onDragEnd: (() -> Void)?

    // Top-left origin, so every layout constant below is the same number as in
    // CcmonWidget.cs. NSAttributedString.draw(at:) follows the context's
    // flippedness too, so the text lands the same way DrawString does.
    override var isFlipped: Bool { true }

    // Mandatory, and it has no Windows analogue: macOS gives the first click on
    // an inactive app's window to activation rather than to the view, so
    // without this every drag needs two clicks and the first does nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func draw(_ s: String, _ font: NSFont, _ color: NSColor, _ x: CGFloat, _ y: CGFloat) {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            .draw(at: NSPoint(x: x, y: y))
    }
    private func width(_ s: String, _ font: NSFont) -> CGFloat {
        NSAttributedString(string: s, attributes: [.font: font]).size().width
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: RADIUS, yRadius: RADIUS)
        cSurface.withAlphaComponent(0.90).setFill()
        shape.fill()
        // The half-point inset is what makes a 1pt stroke land on the pixel
        // grid rather than straddling it.
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: RADIUS, yRadius: RADIUS)
        cBorder.setStroke(); border.lineWidth = 1; border.stroke()

        let stale = data == nil || data!.stale
        let labels = ["5h session", "7d all models"]
        let values = [data?.fiveHour, data?.sevenDay]
        let resets = [data?.fiveHourResets ?? 0, data?.sevenDayResets ?? 0]
        let windows = [WINDOW_5H, WINDOW_7D]

        var y = PAD
        for i in 0..<2 {
            let pc = Pace.of(stale ? nil : values[i], resets[i], windows[i])

            draw(labels[i], fLabel, cMuted, PAD, y)
            let txt = values[i] == nil ? "--" : "\(Int(values[i]!.rounded()))%"
            draw(txt, fBig, stale ? cMuted : cText, W - PAD - width(txt, fBig), y - 6)

            let barY = y + 30, barW = W - 2 * PAD
            cTrack.setFill()
            NSBezierPath(roundedRect: NSRect(x: PAD, y: barY, width: barW, height: 6),
                         xRadius: 3, yRadius: 3).fill()
            if let v = values[i], v > 0 {
                let fw = max(6, barW * min(v, 100) / 100)
                toneColor(pc.tone).setFill()    // stale already resolves to muted
                NSBezierPath(roundedRect: NSRect(x: PAD, y: barY, width: fw, height: 6),
                             xRadius: 3, yRadius: 3).fill()
            }
            // Where usage would be if the window were spent evenly to 95%. The
            // gap between this tick and the end of the fill is the whole point.
            if !stale, pc.paceNow > 0, pc.paceNow < 100 {
                cText.setFill()
                NSBezierPath(rect: NSRect(x: PAD + barW * pc.paceNow / 100,
                                          y: barY - 3, width: 2, height: 12)).fill()
            }

            let when = resets[i] > 0 ? Pace.phrase(resets[i]) : ""
            draw(when, fSmall, cMuted, PAD, barY + 12)
            if !stale {
                draw(pc.verdict, fSmall, toneColor(pc.tone),
                     W - PAD - width(pc.verdict, fSmall), barY + 12)
            }
            y += 74
        }

        let foot: String
        if !everRead          { foot = "waiting for the poller..." }
        else if data == nil   { foot = "snapshot unreadable" }
        else if data!.stale   { foot = "stale - " + data!.reason }
        else {
            let age = (Date().timeIntervalSince1970 * 1000 - data!.fetchedAtMs) / 1000
            foot = age < 90 ? "updated \(Int(age))s ago" : "updated \(Int(age / 60))m ago"
        }
        draw(foot, fSmall, cMuted, PAD, H - PAD - 6)
    }

    // Hand-rolled rather than isMovableByWindowBackground, which gives no
    // mouse-up hook to clamp the widget back onto a screen with.
    private var dragging = false
    private var dragOrigin = NSPoint.zero
    override func mouseDown(with event: NSEvent) { dragging = true; dragOrigin = NSEvent.mouseLocation }
    override func mouseDragged(with event: NSEvent) {
        guard dragging, let w = window else { return }
        let now = NSEvent.mouseLocation
        w.setFrameOrigin(NSPoint(x: w.frame.origin.x + now.x - dragOrigin.x,
                                 y: w.frame.origin.y + now.y - dragOrigin.y))
        dragOrigin = now
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onDragEnd?()
    }
}

// ---------------------------------------------------------------- the thing --

final class Controller: NSObject, NSMenuDelegate {
    var snapshotPath = "", wallboardURL = "", pollerPath = "", updateCommand = ""
    var refreshSeconds: TimeInterval = 30
    // .desktopIconWindow sits above the wallpaper and above the Dock's own
    // desktop window, and below every ordinary window - which is the Windows
    // HWND_BOTTOM position. It is settable because that is the one thing about
    // this port that cannot be established without a screen to look at: if the
    // widget ever turns up visible but unclickable, something is drawing the
    // desktop above us and `--level normal` is the way out.
    var levelName = "desktop"

    var window: DesktopWindow!
    var panel: PanelView!
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var miTop: NSMenuItem!, miHide: NSMenuItem!
    var timer: Timer?
    var settle: Timer?
    var data: Snapshot?
    var everRead = false
    var onTop = false               // false = pinned to the desktop
    var lastGeometry: [NSRect] = []

    // ---- geometry ----

    // Every screen's work area, not just the primary's. The Windows version
    // compares only the primary because reading them all was not cheap there
    // and because its event also fired for wallpaper changes. Neither applies
    // here, and comparing all of them means a monitor arriving that did not
    // change the primary still counts as the desktop changing shape - which is
    // what the comment in CcmonWidget.cs says should happen.
    func geometry() -> [NSRect] { NSScreen.screens.map { $0.visibleFrame } }

    func workArea() -> NSRect {
        NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    // Home is the top-right corner of the work area, one margin in. The window
    // origin is its bottom-left corner, hence the H.
    func home(_ vf: NSRect) -> NSPoint {
        NSPoint(x: vf.maxX - W - MARGIN, y: vf.maxY - H - MARGIN)
    }

    // Pull a position wholly inside the work area. The nesting is inverted
    // relative to the Windows source on the y axis only: there "top" is the
    // smaller number and Max wraps Min, here "top" is maxY so Min wraps Max.
    // Both say the same thing - on a screen too small for both edges, the left
    // and top edges win.
    func clamp(_ vf: NSRect, _ p: NSPoint) -> NSPoint {
        NSPoint(x: max(vf.minX + MARGIN, min(p.x, vf.maxX - W - MARGIN)),
                y: min(vf.maxY - H - MARGIN, max(p.y, vf.minY + MARGIN)))
    }

    func goHome() {
        lastGeometry = geometry()
        window.setFrameOrigin(home(workArea()))
    }

    // One dock, undock or resolution change produces a burst, and the work area
    // is final at none of them - the screen changes first and the Dock and menu
    // bar settle afterwards. Each event restarts a short timer; only the last
    // one repositions, and only if the geometry really moved.
    @objc func screensChanged() {
        settle?.invalidate()
        settle = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.geometry() != self.lastGeometry { self.goHome() }
            self.applyLevel()
        }
    }

    // ---- window level ----

    func wantedLevel() -> NSWindow.Level {
        if onTop { return .floating }
        switch levelName {
        case "normal":   return .normal
        case "floating": return .floating
        default:         return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        }
    }

    // No per-tick SetWindowPos(HWND_BOTTOM) equivalent is needed: on macOS the
    // level is absolute and the window server enforces it, so there is nothing
    // to keep fighting. Reasserting is still cheap insurance after a space
    // switch or a screen change, which can reorder within a level.
    func applyLevel() {
        let want = wantedLevel()
        if window.level != want { window.level = want }
        if window.isVisible { window.orderFrontRegardless() }
    }

    // ---- data ----

    func poll() {
        if let s = Snapshot.read(snapshotPath) { data = s; everRead = true } else { data = nil }
        panel.data = data
        panel.everRead = everRead
        panel.needsDisplay = true
        updateStatusItem()
    }

    func worstTone() -> String {
        guard let d = data, !d.stale else { return "muted" }
        let t5 = Pace.of(d.fiveHour, d.fiveHourResets, WINDOW_5H).tone
        let t7 = Pace.of(d.sevenDay, d.sevenDayResets, WINDOW_7D).tone
        return toneRank(t7) > toneRank(t5) ? t7 : t5
    }

    func dot(_ tone: String) -> NSImage {
        // 18x18 with a 12pt dot centred: the menu bar's icon box is 18pt tall,
        // and the Windows 16x16 at (2,2) sits visibly low in it. The block form
        // re-runs per backing scale, so Retina needs no second asset.
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            toneColor(tone).setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12)).fill()
            return true
        }
        // The colour IS the signal. A template image would be re-tinted to the
        // menu bar's own colour and the verdict would vanish.
        img.isTemplate = false
        return img
    }

    func updateStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = dot(worstTone())
        if let d = data, !d.stale {
            button.toolTip = "ccmon  5h \(Int((d.fiveHour ?? 0).rounded()))%  7d \(Int((d.sevenDay ?? 0).rounded()))%"
        } else {
            button.toolTip = "ccmon - no data"
        }
    }

    // ---- menu ----

    func updateMenuLabels() {
        miTop.title = onTop ? "Send to desktop" : "Bring to front"
        miHide.title = window.isVisible ? "Hide widget" : "Show widget"
    }

    @objc func toggleTop() {
        onTop.toggle()
        if !window.isVisible { window.orderFrontRegardless() }
        applyLevel()
        updateMenuLabels()
    }

    @objc func toggleHidden() {
        if window.isVisible { window.orderOut(nil) } else { window.orderFrontRegardless(); applyLevel() }
        updateMenuLabels()
    }

    @objc func openWallboard() {
        guard !wallboardURL.isEmpty, let u = URL(string: wallboardURL) else {
            alert("No wallboard URL configured. Run ./ccmon."); return
        }
        NSWorkspace.shared.open(u)
    }

    @objc func refreshNow() {
        guard !pollerPath.isEmpty else { alert("No poller configured. Run ./ccmon."); return }
        // Unlike the C#, which re-reads immediately after *starting* the poller
        // and so repaints with the values it already had, this waits for it.
        run(pollerPath) { [weak self] _ in self?.poll() }
    }

    @objc func updateCcmon() {
        guard !updateCommand.isEmpty else { alert("No repo configured. Run ./ccmon."); return }
        // Deliberately not a Process here. ./ccmon update reaches the widget
        // stage, which boots this agent out - and launchd tears down the job's
        // whole process group, including the shell that is running the update.
        // Opening the .command hands it to Terminal, in a process tree launchd
        // is not about to kill, and the Terminal window doubles as the progress
        // report that a balloon tip used to be.
        NSWorkspace.shared.open(URL(fileURLWithPath: updateCommand))
    }

    @objc func quit() { NSApp.terminate(nil) }

    // An accessory app has no menu bar of its own to put a message in, and
    // UNUserNotificationCenter needs an authorisation keyed to a code signature
    // that every ad-hoc rebuild changes. These two cases are genuine
    // misconfiguration and rare, so an alert is the honest way to say so.
    func alert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "ccmon"
        a.informativeText = text
        a.runModal()
    }

    func run(_ command: String, then: ((Int32) -> Void)? = nil) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // -l is not cargo-culted from the Windows version. A launchd-spawned
        // process inherits PATH=/usr/bin:/bin:/usr/sbin:/sbin with no Homebrew
        // in it, and the poller needs jq - which is Homebrew's on any Mac
        // before 15.4. Only a login shell runs path_helper.
        p.arguments = ["-lc", command]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if let then {
            p.terminationHandler = { pr in DispatchQueue.main.async { then(pr.terminationStatus) } }
        }
        try? p.run()
    }

    func buildMenu() {
        menu = NSMenu()
        menu.delegate = self
        func item(_ title: String, _ sel: Selector) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self     // a nil target walks the responder chain, which
            return mi            // an accessory app with no key window can drop
        }
        miTop = item("Bring to front", #selector(toggleTop))
        miHide = item("Hide widget", #selector(toggleHidden))
        menu.addItem(miTop)
        menu.addItem(miHide)
        menu.addItem(.separator())
        menu.addItem(item("Open wallboard", #selector(openWallboard)))
        menu.addItem(item("Refresh now", #selector(refreshNow)))
        menu.addItem(item("Update ccmon", #selector(updateCcmon)))
        menu.addItem(.separator())
        let q = item("Quit", #selector(quit))
        q.keyEquivalent = "q"
        menu.addItem(q)
        updateMenuLabels()
    }

    // statusItem.menu stays nil: assigning it makes AppKit handle the click
    // itself and the left-click toggle never fires.
    @objc func statusClicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        // Control-click counts as a right click - it is how a one-button
        // trackpad opens a context menu, and Windows has no equivalent of it
        // to forget about.
        let rightish = e?.type == .rightMouseUp
            || (e?.type == .leftMouseUp && e?.modifierFlags.contains(.control) == true)
        if rightish {
            updateMenuLabels()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 2), in: sender)
        } else {
            toggleTop()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { updateMenuLabels() }

    // ---- start ----

    func start() {
        window = DesktopWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                               styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        // No shadow, deliberately: the borderless WinForms panel has none
        // either, the hairline border is the depth cue the design already uses,
        // and a real macOS shadow over a wallpaper reads as "floating panel",
        // which is the impression this is trying not to give.
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel = PanelView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        panel.onDragEnd = { [weak self] in
            guard let self else { return }
            // A drag can end off-screen, on any number of monitors. window.screen
            // is the display holding most of the window, and nil once it holds
            // none - where the primary is the same answer Windows lands on.
            let vf = self.window.screen?.visibleFrame ?? self.workArea()
            self.window.setFrameOrigin(self.clamp(vf, self.window.frame.origin))
        }
        window.contentView = panel
        lastGeometry = geometry()
        window.setFrameOrigin(home(workArea()))
        applyLevel()
        window.orderFrontRegardless()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        buildMenu()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // A space switch can reorder within a level and leave a desktop-level
        // window behind whatever else is down there.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screensChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        poll()

        // Fast until the first read lands, then the configured cadence.
        var interval: TimeInterval = 3
        func schedule() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.poll()
                // Belt and braces for the notifications above: a screen change
                // that produced none, or produced them all before the desktop
                // had finished moving, is caught here within one refresh rather
                // than leaving the widget stranded until the next login.
                if self.geometry() != self.lastGeometry { self.goHome() }
                self.applyLevel()
                if self.everRead, interval != self.refreshSeconds {
                    interval = self.refreshSeconds
                    schedule()
                }
            }
        }
        schedule()
    }
}

@main enum CcmonWidget {
    static var controller: Controller?

    static func main() {
        let app = NSApplication.shared
        let c = Controller()
        var args = Array(CommandLine.arguments.dropFirst())
        while args.count >= 2 {
            let flag = args.removeFirst()
            let value = args.removeFirst()
            switch flag {
            case "--snapshot":  c.snapshotPath = value
            case "--wallboard": c.wallboardURL = value
            case "--poller":    c.pollerPath = value
            case "--update":    c.updateCommand = value
            case "--level":     c.levelName = value
            case "--refresh":   c.refreshSeconds = TimeInterval(value) ?? 30
            default: break
            }
        }
        guard !c.snapshotPath.isEmpty else {
            // stderr, not a dialog: the Windows version needs a MessageBox
            // because a /target:winexe process has no console, while here this
            // goes to the agent's log where launchctl and Console can find it.
            let usage = "usage: CcmonWidget --snapshot <path> [--wallboard <url>] [--poller <path>]\n"
                      + "                   [--update <path>] [--level desktop|normal|floating] [--refresh <s>]\n"
            FileHandle.standardError.write(usage.data(using: .utf8)!)
            exit(2)
        }
        app.setActivationPolicy(.accessory)
        controller = c
        c.start()
        app.run()
    }
}
