// ccmon's desktop widget on macOS - the counterpart of CcmonWidget.cs, which is
// the same panel and the same menu on Windows. Built on the fly by lib/macos.sh
// with the swiftc that ships in the Command Line Tools, for the same reason the
// Windows one is built with csc: nothing to install, and the source is what is
// distributed rather than a binary.
//
// It reads the snapshots the pollers write - usage-snapshot.json and, when
// ./ccmon has configured one, bedrock-snapshot.json - and nothing else. No
// network, no credentials: the pollers own both, and the widget is only ever a
// view onto their output.
//
// Do not rename this file to main.swift - it is compiled with -parse-as-library
// and an explicit @main, which is what keeps the entry point unambiguous.

import AppKit
import ImageIO

// ----------------------------------------------------------------- geometry --

// A panel is as tall as its rows: two on the subscription panel, one or two on
// the Bedrock one. 190 for two.
let W: CGFloat = 268, ROW: CGFloat = 74, FOOT: CGFloat = 26
let PAD: CGFloat = 16, RADIUS: CGFloat = 16, MARGIN: CGFloat = 24, GAP: CGFloat = 12
func heightFor(_ rows: Int) -> CGFloat { PAD + CGFloat(rows) * ROW + FOOT }
let WINDOW_5H: TimeInterval = 5 * 3600
let WINDOW_7D: TimeInterval = 7 * 86400

// sRGB explicitly, never calibrated: these hex values are shared with the
// wallboard's CSS, and the calibrated colour space shifts the green and the
// yellow enough to see.
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
struct Palette {
    let surface, text, muted, track, good, warn, crit: NSColor
    let isDark: Bool
}

// Both sets are lifted from wallboard/index.html - dark :25-30, light :32-37 -
// so the widget, the chart and the published page cannot drift apart. The light
// tones are not lightened dark ones: --warn goes amber -> bronze precisely
// because amber cannot make contrast on white.
//
// Two deliberate substitutions on the light side, both because the wallboard's
// value cannot carry small text on a light surface, and both measured:
//
//   muted  --text-muted #82817c is 3.8:1 on #fcfcfb, which no amount of scrim
//          can rescue, so the muted role takes --text-secondary #52514e (7.7:1).
//   good   --good #1baf7a is 2.74:1 - the odd one out in a set whose warn is
//          4.80 and crit 6.30, and on a real wallpaper it measured 1.0:1 at the
//          alpha the widget had chosen, which is invisible. The verdict is the
//          one thing on the panel that carries a message, so it cannot be the
//          least legible thing on it. #15805c is 4.79:1, in line with the other
//          two tones. The wallboard keeps #1baf7a, where it is used at headline
//          size and passes on that basis.
//
// The dark side needs neither: its muted is 5.3:1 and its good 5.1:1.
let paletteDark = Palette(
    surface: rgb(0x1a, 0x1a, 0x19), text: rgb(0xf5, 0xf5, 0xf3),
    muted:   rgb(0x8f, 0x8e, 0x86), track: rgb(0x38, 0x38, 0x34),
    good:    rgb(0x19, 0x9e, 0x70), warn:  rgb(0xea, 0xb3, 0x08),
    crit:    rgb(0xe6, 0x67, 0x67), isDark: true)

let paletteLight = Palette(
    surface: rgb(0xfc, 0xfc, 0xfb), text: rgb(0x0b, 0x0b, 0x0b),
    muted:   rgb(0x52, 0x51, 0x4e), track: rgb(0xe6, 0xe5, 0xe1),
    good:    rgb(0x15, 0x80, 0x5c), warn:  rgb(0xa1, 0x62, 0x07),
    crit:    rgb(0xb9, 0x1c, 0x1c), isDark: false)

// How far the scrim fades from the centre of the panel to its edge, and the
// least it is ever allowed to be. The floor is what keeps the widget a panel
// rather than a set of glyphs loose on the wallpaper.
let FEATHER: CGFloat = 0.70
let SCRIM_FLOOR: CGFloat = 0.15

// WinForms point sizes render at 96 DPI, where a point is 4/3 of a pixel; on
// macOS a point is the drawing unit itself. The geometry above transfers 1:1,
// so the fonts have to be scaled by that 4/3 to keep the same proportion of
// text to panel: 8.5 -> 11, 21 -> 28, 7.5 -> 10.
let fLabel = NSFont.systemFont(ofSize: 11)
// Monospaced digits for this one only: it is redrawn every refresh, and SF's
// proportional figures make a right-aligned number's left edge twitch.
let fBig   = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
let fSmall = NSFont.systemFont(ofSize: 10)

func toneColor(_ tone: String, _ p: Palette) -> NSColor {
    switch tone {
    case "good": return p.good
    case "warn": return p.warn
    case "crit": return p.crit
    default:     return p.muted
    }
}

// Ranked so the menu bar, which has one dot for several bars, can show the worst.
func toneRank(_ tone: String) -> Int {
    switch tone {
    case "crit": return 3
    case "warn": return 2
    case "good": return 1
    default:     return 0    // muted: no reading, or a window too young to judge
    }
}

// ---------------------------------------------------------------- snapshots --

// One bar on a panel: what is used of an allowance that renews at resetsAt.
// note, when there is one, leads the small print under the bar.
struct Row {
    var label: String
    var value: String
    var util: Double? = nil             // percent of the allowance used; nil = nothing to draw
    var resetsAt: TimeInterval = 0      // epoch seconds, 0 when absent
    var windowSec: TimeInterval = 0
    var note = ""
}

// What a panel shows: its rows, and whether to believe them. Each snapshot kind
// has its own reader; drawing, pacing and the menu bar only ever see rows.
struct Reading {
    var rows: [Row] = []
    var stale = true
    var reason = ""
    var alert = ""
    var summary = ""
    var link = ""                       // a page with the detail behind it, if any
    var fetchedAtMs: Double = 0

    private static func load(_ path: String) -> (Reading, [String: Any])? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let d = obj as? [String: Any] else { return nil }
        var r = Reading()
        r.stale = (d["stale"] as? Bool) ?? false
        r.reason = (d["reason"] as? String) ?? ""
        r.fetchedAtMs = num(d["fetchedAtMs"]) ?? num(d["checkedAtMs"]) ?? 0
        return (r, d)
    }

    static func subscription(_ path: String) -> Reading? {
        guard let loaded = load(path) else { return nil }
        var r = loaded.0
        let d = loaded.1
        r.rows = [percent("5h session", num(d["five_hour"]),
                          epoch(d["five_hour_resets_at"] as? String), WINDOW_5H),
                  percent("7d all models", num(d["seven_day"]),
                          epoch(d["seven_day_resets_at"] as? String), WINDOW_7D)]
        r.summary = "5h \(Int((r.rows[0].util ?? 0).rounded()))%  7d \(Int((r.rows[1].util ?? 0).rounded()))%"
        return r
    }

    private static func percent(_ label: String, _ util: Double?,
                                _ resetsAt: TimeInterval, _ windowSec: TimeInterval) -> Row {
        Row(label: label, value: util == nil ? "--" : "\(Int(util!.rounded()))%",
            util: util, resetsAt: resetsAt, windowSec: windowSec)
    }

    // The gateway counts "tokens" weighted by price - a million of them is a
    // dollar - so a token count left means nothing to anyone. The big number is
    // a percentage, as on the subscription panel and the gateway's own
    // dashboard, and what is left is stated in dollars underneath.
    static func bedrock(_ path: String) -> Reading? {
        guard let loaded = load(path) else { return nil }
        var r = loaded.0
        let d = loaded.1
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let resets = epoch(d["resets_at"] as? String)
        let start = resets > 0
            ? utc.date(byAdding: .month, value: -1, to: Date(timeIntervalSince1970: resets)) ?? Date()
            : Date()
        let window = resets > 0 ? resets - start.timeIntervalSince1970 : 30 * 86400
        let month = DateFormatter()
        month.dateFormat = "MMM"
        month.timeZone = utc.timeZone

        let used = num(d["used"]) ?? 0, limit = num(d["limit"]) ?? 0
        let unlimited = (d["unlimited"] as? Bool) ?? false
        var own = quota("Bedrock \u{00b7} " + month.string(from: start), used, limit, resets, window)
        if unlimited { own.value = "unlimited"; own.util = nil; own.note = "" }
        var rows = [own]
        r.summary = "Bedrock " + own.value + (own.note.isEmpty ? "" : " \u{00b7} " + own.note)

        // The shared pool this user draws from, whichever is fullest. Once it is
        // spent everyone in it is blocked, own quota or not - but until it is
        // fuller than the user's own quota it cannot be what stops them, and a
        // row for it would be noise.
        if let pool = d["pool"] as? [String: Any], (pool["binding"] as? Bool) == true {
            let pu = num(pool["used"]) ?? 0, pl = num(pool["limit"]) ?? 0
            let name = (pool["name"] as? String) ?? "shared"
            if pl > 0 { rows.append(quota(name.lowercased() + " pool", pu, pl, resets, window)) }
        }
        r.rows = rows

        if (d["blocked"] as? Bool) == true {
            let why = (d["block_reasons"] as? [Any])?.map { "\($0)" } ?? []
            r.alert = "BLOCKED" + (why.isEmpty ? "" : " (" + why.joined(separator: ", ") + ")")
        }

        // The dashboard's own filter is a case-insensitive substring match, so
        // the address goes in lowercased; its month is the UTC one.
        if let dash = d["dashboard"] as? String, !dash.isEmpty,
           let email = d["email"] as? String, !email.isEmpty {
            let ym = DateFormatter()
            ym.dateFormat = "yyyy-MM"
            ym.timeZone = utc.timeZone
            ym.locale = Locale(identifier: "en_US_POSIX")
            var q = CharacterSet.urlQueryAllowed
            q.remove(charactersIn: "&=+@")
            let filter = email.lowercased().addingPercentEncoding(withAllowedCharacters: q) ?? ""
            var base = dash
            while base.hasSuffix("/") { base.removeLast() }
            r.link = base + "/?month=" + ym.string(from: Date()) + "&filter=" + filter
        }
        return r
    }

    private static func quota(_ label: String, _ used: Double, _ limit: Double,
                              _ resetsAt: TimeInterval, _ windowSec: TimeInterval) -> Row {
        let util: Double? = limit > 0 ? used / limit * 100 : nil
        return Row(label: label, value: util == nil ? "--" : "\(Int(util!.rounded()))%",
                   util: util, resetsAt: resetsAt, windowSec: windowSec,
                   note: limit > 0 ? dollars(limit - used) + " left" : "")
    }

    // $182, $9.37, $190k: whole dollars, cents only once they are all there is,
    // and thousands for a pool. Rounded down, as ./ccmon's own summary is: what
    // is left should never read as more than there is.
    static func dollars(_ weighted: Double) -> String {
        let v = max(0, weighted / 1e6)
        if v < 10  { return String(format: "$%.2f", (v * 100).rounded(.down) / 100) }
        if v < 1e4 { return "$\(Int(v.rounded(.down)))" }
        if v < 1e6 { return "$\(Int((v / 1e3).rounded(.down)))k" }
        let m = (v / 1e5).rounded(.down) / 10
        return m == m.rounded(.down) ? "$\(Int(m))M" : String(format: "$%.1fM", m)
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

// ----------------------------------------------------------------- backdrop --
//
// Everything here answers one question: how little scrim can the panel wear and
// still be read over whatever the wallpaper happens to be underneath it.

func srgbToLinear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
func linearToSrgb(_ v: CGFloat) -> CGFloat { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
    0.2126 * srgbToLinear(r) + 0.7152 * srgbToLinear(g) + 0.0722 * srgbToLinear(b)
}
func luminance(_ c: NSColor) -> CGFloat {
    guard let s = c.usingColorSpace(.sRGB) else { return 0 }
    return luminance(s.redComponent, s.greenComponent, s.blueComponent)
}
func contrast(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

// What the wallpaper under the panel actually looks like. Linear channels rather
// than encoded ones, so the pessimism below is a scalar multiply.
struct Backdrop {
    var r: CGFloat = 0.25, g: CGFloat = 0.25, b: CGFloat = 0.25   // mean, linear
    var meanY: CGFloat = 0.25
    var sdY: CGFloat = 0
    var chroma: CGFloat = 0
    var confident = false
}

// The scrim composited over the backdrop, as a luminance.
//
// Blending happens on gamma-encoded channels, so this cannot be done on
// luminances directly: lin() is convex, which makes a linear-light model always
// optimistic for a light scrim over a dark backdrop - the one case where being
// wrong means unreadable text.
func compositeLuminance(scrim: NSColor, alpha a: CGFloat, over d: Backdrop, dark: Bool) -> CGFloat {
    // Pessimism about busy-ness, decaying as the scrim thickens. A mean alone
    // under-serves a patch with a long tail, but the scrim itself flattens that
    // tail, so a fixed +/- sd over-charges once it is thick.
    let shift = 1.5 * (1 - a) * d.sdY
    let want = dark ? min(1, d.meanY + shift) : max(0.0001, d.meanY - shift)
    // Scaling all three LINEAR channels by one factor moves luminance exactly
    // while preserving chromaticity, so the pessimism never invents a hue.
    let f = d.meanY > 0.0001 ? want / d.meanY : 1
    let br = linearToSrgb(min(1, d.r * f))
    let bg = linearToSrgb(min(1, d.g * f))
    let bb = linearToSrgb(min(1, d.b * f))
    guard let s = scrim.usingColorSpace(.sRGB) else { return d.meanY }
    return luminance(s.redComponent * a + br * (1 - a),
                     s.greenComponent * a + bg * (1 - a),
                     s.blueComponent * a + bb * (1 - a))
}

// The least scrim that keeps this palette readable on this backdrop, returned as
// the alpha at the panel's *edge* - the thinnest point once the feather is
// applied - so the guarantee holds where the text actually sits.
//
// Two requirements, not one. The slider's ratio is about the headline, and
// measured on a real wallpaper the muted footer binds well before the headline
// does: targeting the big number alone ships a legible 70% above an illegible
// "updated 45s ago".
//
// The secondary requirement tracks the slider rather than sitting at a fixed
// 3:1, and that is not a detail. Pinned, it binds below roughly 7:1 on an
// ordinary wallpaper and the whole lower half of the slider does nothing at all
// - measured, 3:1, 4.5:1 and 7:1 all produced the same alpha. Scaling it keeps
// the travel honest while preserving the ordering the design depends on:
// secondary text is allowed to be secondary, but never by an unbounded amount.
func secondaryTarget(_ target: CGFloat) -> CGFloat { max(2.5, target * 0.6) }

// The tones are in here with the text, and leaving them out was a real bug: the
// solver was choosing a palette on the strength of its headline while the
// verdict underneath measured 1.0:1 against the same backdrop. On this panel the
// verdict is the message - "faster 1.5x" is the reason the widget exists - so
// the worst tone constrains the scrim exactly as the footer does.
func minimumAlpha(_ p: Palette, target: CGFloat, over d: Backdrop) -> CGFloat {
    let yText = luminance(p.text), yMuted = luminance(p.muted)
    let yTones = [p.good, p.warn, p.crit].map(luminance)
    // A thin scrim over a saturated wallpaper tints the surface, and a
    // green-tinted panel next to a green pace bar is a colour that looks like it
    // means something. Buy that off with a little more scrim.
    let bump = 1 + 0.12 * min(1, d.chroma / 0.5)
    func ok(_ a: CGFloat) -> Bool {
        let yc = compositeLuminance(scrim: p.surface, alpha: a, over: d, dark: p.isDark)
        let secondary = secondaryTarget(target) * bump
        return contrast(yText, yc) >= target * bump
            && contrast(yMuted, yc) >= secondary
            && yTones.allSatisfy { contrast($0, yc) >= secondary }
    }
    if ok(0) { return SCRIM_FLOOR }
    var lo: CGFloat = 0, hi: CGFloat = 1
    for _ in 0..<20 {
        let mid = (lo + hi) / 2
        if ok(mid) { hi = mid } else { lo = mid }
    }
    return max(SCRIM_FLOOR, hi)
}

// One proxy pixel per this many screen points. Wallpaper structure finer than
// this is not what makes 10pt text hard to read, and it keeps a screen's proxy
// to about half a megabyte however large the wallpaper is.
let PROXY_STEP: CGFloat = 4

// The wallpaper as WindowServer lays it out, reduced and kept in linear light.
// Built once per wallpaper change; sampled on every drag.
final class WallpaperProxy {
    let key: String
    let w: Int, h: Int
    let screenFrame: NSRect
    let confident: Bool
    var lin: [CGFloat]          // w*h*3, linear sRGB

    init(key: String, w: Int, h: Int, screenFrame: NSRect, confident: Bool, lin: [CGFloat]) {
        self.key = key; self.w = w; self.h = h
        self.screenFrame = screenFrame; self.confident = confident; self.lin = lin
    }
}

// Where macOS draws the image inside the screen. Computed from the ORIGINAL
// pixel dimensions - a thumbnail's own size would put the letterbox bars in the
// wrong place, silently, which is the kind of wrong that reads as "the colours
// are a bit off" rather than as a bug.
func wallpaperImageRect(imageW iw: CGFloat, imageH ih: CGFloat, screen sf: NSRect,
                        opts: [NSWorkspace.DesktopImageOptionKey: Any]) -> NSRect {
    let raw = (opts[.imageScaling] as? NSNumber)?.uintValue
        ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue
    let clip = (opts[.allowClipping] as? NSNumber)?.boolValue ?? false
    let sx = sf.width / iw, sy = sf.height / ih
    var w = iw, h = ih
    switch NSImageScaling(rawValue: raw) ?? .scaleProportionallyUpOrDown {
    case .scaleAxesIndependently:                       // Stretch to Fill Screen
        w = sf.width; h = sf.height
    case .scaleNone:                                    // Centre. Rare, and the
        break                                           // one mode left unverified.
    case .scaleProportionallyDown:
        let s = min(1, min(sx, sy)); w = iw * s; h = ih * s
    default:                                            // Fill / Fit Screen
        let s = clip ? max(sx, sy) : min(sx, sy); w = iw * s; h = ih * s
    }
    return NSRect(x: (sf.width - w) / 2, y: (sf.height - h) / 2, width: w, height: h)
}

// A .heic wallpaper carries several images. Two is the light/dark pair, and more
// than that is a solar sequence whose displayed frame WindowServer picks from the
// sun's position - which is not observable from here. Choose by appearance and
// let the caller charge a confidence penalty for the guess.
func pickRepresentation(_ src: CGImageSource) -> (index: Int, sure: Bool) {
    let n = CGImageSourceGetCount(src)
    if n <= 1 { return (0, true) }
    let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return (dark ? n - 1 : 0, n == 2)
}

func wallpaperKey(for screen: NSScreen) -> String {
    let url = NSWorkspace.shared.desktopImageURL(for: screen)
    let opts = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
    var mtime = "-", size = "-"
    if let u = url, let a = try? FileManager.default.attributesOfItem(atPath: u.path) {
        mtime = "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        size = "\(a[.size] as? Int ?? 0)"
    }
    let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return [url?.path ?? "-", mtime, size,
            "\((opts[.imageScaling] as? NSNumber)?.intValue ?? -1)",
            "\((opts[.allowClipping] as? NSNumber)?.boolValue ?? false)",
            "\((opts[.fillColor] as? NSColor)?.description ?? "-")",
            "\(screen.frame)", "\(dark)"].joined(separator: "|")
}

func buildProxy(for screen: NSScreen) -> WallpaperProxy? {
    let sf = screen.frame
    let w = max(1, Int((sf.width / PROXY_STEP).rounded(.up)))
    let h = max(1, Int((sf.height / PROXY_STEP).rounded(.up)))
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    let opts = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
    // The fill colour goes down first, which is what puts the right pixels under
    // a letterboxed wallpaper with no special case anywhere.
    let fill = (opts[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) ?? .black
    ctx.setFillColor(fill.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

    var confident = false
    // CGImageSource rather than NSImage: it decodes at reduced scale instead of
    // paying thirty megabytes for a phone photo, and a count of zero is a clean
    // way to recognise the video wallpaper it cannot open at all.
    if let url = NSWorkspace.shared.desktopImageURL(for: screen),
       let src = CGImageSourceCreateWithURL(url as CFURL, nil),
       CGImageSourceGetCount(src) > 0 {
        let pick = pickRepresentation(src)
        if let props = CGImageSourceCopyPropertiesAtIndex(src, pick.index, nil) as? [CFString: Any],
           let iw = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let ih = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
           iw > 0, ih > 0,
           let cg = CGImageSourceCreateThumbnailAtIndex(src, pick.index, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: Int(max(sf.width, sf.height) * 2),
               kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
            let r = wallpaperImageRect(imageW: CGFloat(iw), imageH: CGFloat(ih), screen: sf, opts: opts)
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: r.minX / PROXY_STEP, y: r.minY / PROXY_STEP,
                                    width: r.width / PROXY_STEP, height: r.height / PROXY_STEP))
            confident = pick.sure
        }
    }

    guard let data = ctx.data else { return nil }
    let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var lut = [CGFloat](repeating: 0, count: 256)
    for i in 0..<256 { lut[i] = srgbToLinear(CGFloat(i) / 255) }
    var lin = [CGFloat](repeating: 0, count: w * h * 3)
    for i in 0..<(w * h) {
        lin[i * 3]     = lut[Int(px[i * 4])]
        lin[i * 3 + 1] = lut[Int(px[i * 4 + 1])]
        lin[i * 3 + 2] = lut[Int(px[i * 4 + 2])]
    }
    return WallpaperProxy(key: wallpaperKey(for: screen), w: w, h: h,
                          screenFrame: sf, confident: confident, lin: lin)
}

// Accumulate across every screen the panel touches, into one set of sums. That
// is the whole answer to a widget straddling two displays: the pooled mean and
// pooled sd are exact for the union, and the area weighting is implicit in the
// pixel counts, so two screens with different wallpapers need no special case.
func sampleBackdrop(_ rect: NSRect, _ proxies: [WallpaperProxy]) -> Backdrop? {
    var n = 0
    var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, sy: CGFloat = 0, syy: CGFloat = 0
    var anyUnsure = false
    for p in proxies {
        // frame, not visibleFrame: the wallpaper runs under the menu bar and Dock.
        let hit = rect.intersection(p.screenFrame)
        guard !hit.isNull, hit.width > 1, hit.height > 1 else { continue }
        if !p.confident { anyUnsure = true }
        let x0 = Int((hit.minX - p.screenFrame.minX) / PROXY_STEP)
        let y0 = Int((hit.minY - p.screenFrame.minY) / PROXY_STEP)
        let x1 = min(p.w, Int((hit.maxX - p.screenFrame.minX) / PROXY_STEP) + 1)
        let y1 = min(p.h, Int((hit.maxY - p.screenFrame.minY) / PROXY_STEP) + 1)
        guard x1 > x0, y1 > y0 else { continue }
        for y in max(0, y0)..<y1 {
            for x in max(0, x0)..<x1 {
                let i = (y * p.w + x) * 3
                let r = p.lin[i], g = p.lin[i + 1], b = p.lin[i + 2]
                let yy = 0.2126 * r + 0.7152 * g + 0.0722 * b
                sr += r; sg += g; sb += b; sy += yy; syy += yy * yy
                n += 1
            }
        }
    }
    guard n > 16 else { return nil }
    let c = CGFloat(n)
    var d = Backdrop()
    d.r = sr / c; d.g = sg / c; d.b = sb / c
    d.meanY = sy / c
    d.sdY = sqrt(max(0, syy / c - d.meanY * d.meanY))
    let hi = max(d.r, max(d.g, d.b)), lo = min(d.r, min(d.g, d.b))
    d.chroma = hi > 0.0001 ? (hi - lo) / hi : 0
    d.confident = !anyUnsure
    return d
}

// ------------------------------------------------------------------- window --

// Lives on the desktop: never in Cmd-Tab, never takes focus, no Dock icon.
final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// What the panel should wear right now: which palette, and how much of it.
struct Theme {
    var palette = paletteDark
    var alpha: CGFloat = 0.90      // at the panel's edge; the centre is thicker
    var halo = false
}

final class PanelView: NSView {
    var reading: Reading?
    var everRead = false
    var placeholder: [Row] = []
    var theme = Theme()
    var onDragEnd: (() -> Void)?

    // Top-left origin, so every layout constant below is the same number as in
    // CcmonWidget.cs. NSAttributedString.draw(at:) follows the context's
    // flippedness too, so the text lands the same way DrawString does.
    override var isFlipped: Bool { true }

    // Mandatory, and it has no Windows analogue: macOS gives the first click on
    // an inactive app's window to activation rather than to the view, so
    // without this every drag needs two clicks and the first does nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Zero offset plus a blur is a halo, not a drop shadow: the glyph keeps its
    // own shape and simply gains local contrast. It is what rescues text when
    // the scrim is thin, and the only thing that rescues the light palette's
    // green, which measures 2.74:1 on #fcfcfb and cannot be helped by any alpha.
    private func halo(_ on: Bool) -> NSShadow? {
        guard on else { return nil }
        let sh = NSShadow()
        sh.shadowColor = (theme.palette.isDark ? paletteLight : paletteDark)
            .text.withAlphaComponent(0.45)
        sh.shadowBlurRadius = 2.5
        sh.shadowOffset = .zero
        return sh
    }

    private func draw(_ s: String, _ font: NSFont, _ color: NSColor,
                      _ x: CGFloat, _ y: CGFloat, halo forceHalo: Bool = false) {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let sh = halo(theme.halo || forceHalo) { attrs[.shadow] = sh }
        NSAttributedString(string: s, attributes: attrs).draw(at: NSPoint(x: x, y: y))
    }
    private func width(_ s: String, _ font: NSFont) -> CGFloat {
        NSAttributedString(string: s, attributes: [.font: font]).size().width
    }


    override func draw(_ dirtyRect: NSRect) {
        let pal = theme.palette
        let edge = theme.alpha
        // The solver returns the alpha for the thinnest point, so the centre is
        // the one that gets scaled up. Clamped, which means a panel that needs
        // everything it can get stops feathering rather than going translucent
        // in the middle.
        let centre = min(1, edge / FEATHER)

        // Inset by half a point so the fill and the stroke abut instead of
        // overlapping - two translucent layers sharing an edge accumulate into
        // a darker rim, which is invisible at 0.90 and not at 0.15.
        let fillPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: RADIUS, yRadius: RADIUS)
        // Radial rather than flat: a hard rectangle is what makes a widget look
        // stuck onto the desktop instead of part of it.
        if let g = NSGradient(colors: [pal.surface.withAlphaComponent(centre),
                                       pal.surface.withAlphaComponent(edge)]) {
            g.draw(in: fillPath, relativeCenterPosition: NSPoint(x: 0, y: 0))
        }

        // The border's job inverts as the fill thins: with a thick scrim it
        // separates the panel from the wallpaper, with a thin one it *is* the
        // panel. So it strengthens as the fill weakens, and it comes from the
        // text colour - a translucent panel's edge has to contrast with the
        // wallpaper, not with its own surface. At alpha 0.90 this lands on the
        // white @ 70/255 the Windows widget uses, so nothing visibly changes there.
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: RADIUS, yRadius: RADIUS)
        pal.text.withAlphaComponent(0.42 + (0.20 - 0.42) * edge).setStroke()
        border.lineWidth = 1; border.stroke()

        let stale = reading == nil || reading!.stale
        var y = PAD
        for r in reading?.rows ?? placeholder {
            drawRow(r, y, stale, pal)
            y += ROW
        }

        let foot: String
        if !everRead            { foot = "waiting for the poller..." }
        else if reading == nil  { foot = "snapshot unreadable" }
        else if reading!.stale  { foot = "stale - " + reading!.reason }
        else                    { foot = "updated " + age(reading!.fetchedAtMs) + " ago" }
        let h = bounds.height
        draw(foot, fSmall, pal.muted, PAD, h - PAD - 6)
        if let a = reading?.alert, !a.isEmpty {
            draw(a, fSmall, pal.crit, W - PAD - width(a, fSmall), h - PAD - 6,
                 halo: contrast(luminance(pal.crit), luminance(pal.surface)) < 3.0)
        }
    }

    private func age(_ fetchedAtMs: Double) -> String {
        let s = (Date().timeIntervalSince1970 * 1000 - fetchedAtMs) / 1000
        if s < 90        { return "\(Int(s))s" }
        if s < 90 * 60   { return "\(Int(s / 60))m" }
        if s < 48 * 3600 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }

    private func drawRow(_ r: Row, _ y: CGFloat, _ stale: Bool, _ pal: Palette) {
        let pc = Pace.of(stale ? nil : r.util, r.resetsAt, r.windowSec)

        draw(r.label, fLabel, pal.muted, PAD, y)
        draw(r.value, fBig, stale ? pal.muted : pal.text, W - PAD - width(r.value, fBig), y - 6)

        let barY = y + 30, barW = W - 2 * PAD
        pal.track.setFill()
        NSBezierPath(roundedRect: NSRect(x: PAD, y: barY, width: barW, height: 6),
                     xRadius: 3, yRadius: 3).fill()
        if let v = r.util, v > 0 {
            let fw = max(6, barW * min(v, 100) / 100)
            toneColor(pc.tone, pal).setFill()   // stale already resolves to muted
            NSBezierPath(roundedRect: NSRect(x: PAD, y: barY, width: fw, height: 6),
                         xRadius: 3, yRadius: 3).fill()
        }
        // Where usage would be if the window were spent evenly to 95%. The gap
        // between this tick and the end of the fill is the whole point.
        if !stale, r.util != nil, pc.paceNow > 0, pc.paceNow < 100 {
            pal.text.setFill()
            NSBezierPath(rect: NSRect(x: PAD + barW * pc.paceNow / 100,
                                      y: barY - 3, width: 2, height: 12)).fill()
        }

        var when = r.resetsAt > 0 ? Pace.phrase(r.resetsAt) : ""
        if !r.note.isEmpty { when = when.isEmpty ? r.note : r.note + " \u{00b7} " + when }
        draw(when, fSmall, pal.muted, PAD, barY + 12)
        if !stale, r.util != nil {
            // The tone gets a halo of its own when the palette cannot carry it,
            // independently of how thick the scrim is.
            let tone = toneColor(pc.tone, pal)
            let weak = contrast(luminance(tone), luminance(pal.surface)) < 3.0
            draw(pc.verdict, fSmall, tone,
                 W - PAD - width(pc.verdict, fSmall), barY + 12, halo: weak)
        }
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

// A slider inside a menu needs a view to live in, and the view needs a real
// frame before the menu first opens - AppKit measures the menu's width from its
// item views, and a zero-width one collapses the whole menu.
final class SliderItemView: NSView {
    let label = NSTextField(labelWithString: "")
    let slider = NSSlider()

    init(target: AnyObject, action: Selector, value: Double) {
        super.init(frame: NSRect(x: 0, y: 0, width: 236, height: 46))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 26, width: 210, height: 14)
        slider.minValue = 3
        slider.maxValue = 12
        slider.doubleValue = value
        slider.isContinuous = true          // the widget itself is the preview
        slider.target = target
        slider.action = action
        slider.frame = NSRect(x: 12, y: 4, width: 212, height: 20)
        addSubview(label)
        addSubview(slider)
    }
    required init?(coder: NSCoder) { nil }
}

// One panel on the desktop and everything particular to it: its snapshot, and
// the wallpaper it happens to sit over - two stacked panels can sit over very
// different parts of it. Slot is its place in the stack: home for slot 1 is
// directly below slot 0.
final class PanelHost {
    let path: String
    let read: (String) -> Reading?
    let slot: Int
    let optional: Bool
    var window: DesktopWindow!
    var view: PanelView!
    var reading: Reading?
    var everRead = false
    var backdrop: Backdrop?
    var polarity: Palette = paletteDark
    var dwell = 0
    var lastDecision = ""
    var placeholder: [Row]
    var height: CGFloat             // follows the number of rows; see Controller.fit

    init(path: String, read: @escaping (String) -> Reading?, slot: Int, optional: Bool,
         placeholder: [Row]) {
        self.path = path; self.read = read; self.slot = slot; self.optional = optional
        self.placeholder = placeholder
        self.height = heightFor(placeholder.count)
    }

    var rows: [Row] { reading?.rows ?? placeholder }

    // The Bedrock snapshot only exists on a machine ./ccmon has configured for
    // it. The subscription panel is always wanted, if only to say that the
    // poller has not run yet.
    var available: Bool { !optional || everRead }

    func poll() {
        if optional, !FileManager.default.fileExists(atPath: path) {
            reading = nil; everRead = false
        } else if let r = read(path) {
            reading = r; everRead = true
        } else {
            reading = nil
        }
        view.reading = reading
        view.everRead = everRead
        view.needsDisplay = true
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

final class Controller: NSObject, NSMenuDelegate {
    var snapshotPath = "", bedrockPath = "", profilesDir = "", profileCmd = ""
    var wallboardURL = "", pollerPath = "", updateCommand = ""
    var refreshSeconds: TimeInterval = 30
    // Finder's desktop window - the one that draws the icons and handles clicks
    // on the desktop - covers the whole screen at kCGDesktopIconWindowLevel.
    // That forces a choice, because a window below it cannot receive the clicks
    // that pass over it:
    //
    //   desktop  (default)  kCGDesktopWindowLevel, under the icons. Finder is
    //                       above us everywhere, so the panel cannot be dragged
    //                       directly - "Move widget" in the menu is how it moves.
    //   icons                kCGDesktopIconWindowLevel, the same level as Finder's
    //                       window, ordered in front of it. Draggable directly,
    //                       at the price of painting over the desktop icons.
    //   normal / floating    ordinary windows, for when neither of the above
    //                       behaves on some future macOS.
    var levelName = "desktop"

    var main: PanelHost!
    var bedrock: PanelHost?         // nil when no --bedrock was given
    var panels: [PanelHost] {
        let m: PanelHost = main
        if let b = bedrock { return [m, b] }
        return [m]
    }

    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var miTop: NSMenuItem!, miHide: NSMenuItem!, miMove: NSMenuItem!, miBedrock: NSMenuItem!
    var miProfile: NSMenuItem!, miBedrockBoard: NSMenuItem!
    var sliderView: SliderItemView!
    var miAuto: NSMenuItem!, miLight: NSMenuItem!, miDark: NSMenuItem!, miAdapt: NSMenuItem!
    var timer: Timer?
    var settle: Timer?
    var onTop = false               // false = pinned to the desktop
    var moving = false              // temporarily lifted so it can be dragged
    var hidden = false              // the whole widget, from the menu
    var showBedrock = true          // the Bedrock panel alone; remembered

    // Appearance state. readability is the contrast the headline must reach;
    // the scrim's alpha is derived from it and never set directly.
    var proxies: [WallpaperProxy] = []
    var readability: CGFloat = 4.5
    var appearanceMode = "auto"     // auto | light | dark
    var adaptOpacity = true
    var wallpaperTick = 0
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

    // Home is the top-right corner of the work area, one margin in, with each
    // further panel stacked below the ones before - however tall they are now.
    // The window origin is its bottom-left corner, hence its own height.
    func home(_ vf: NSRect, _ p: PanelHost) -> NSPoint {
        var top = vf.maxY - MARGIN
        for q in [main, bedrock].compactMap({ $0 }) where q.slot < p.slot { top -= q.height + GAP }
        return NSPoint(x: vf.maxX - W - MARGIN, y: top - p.height)
    }

    // Pull a position wholly inside the work area. The nesting is inverted
    // relative to the Windows source on the y axis only: there "top" is the
    // smaller number and Max wraps Min, here "top" is maxY so Min wraps Max.
    // Both say the same thing - on a screen too small for both edges, the left
    // and top edges win.
    func clamp(_ vf: NSRect, _ p: NSPoint, _ h: CGFloat) -> NSPoint {
        NSPoint(x: max(vf.minX + MARGIN, min(p.x, vf.maxX - W - MARGIN)),
                y: min(vf.maxY - h - MARGIN, max(p.y, vf.minY + MARGIN)))
    }

    func goHome() {
        lastGeometry = geometry()
        let vf = workArea()
        for p in panels { p.window.setFrameOrigin(clamp(vf, home(vf, p), p.height)) }
    }

    // A pool row comes and goes with the pool's state, so the panel's height
    // does too. The top edge stays put: home is a top-right corner, and a
    // hand-placed panel growing upwards would look like it had moved.
    func fit(_ p: PanelHost) {
        let h = heightFor(p.rows.count)
        guard h != p.height else { return }
        p.height = h
        let f = p.window.frame
        let vf = p.window.screen?.visibleFrame ?? workArea()
        let o = clamp(vf, NSPoint(x: f.minX, y: f.maxY - h), h)
        p.window.setFrame(NSRect(x: o.x, y: o.y, width: W, height: h), display: true)
        resample(p, settled: true)
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
            // A screen change can also mean a different wallpaper on the screen
            // the widget ended up on.
            self.refreshProxies(force: true)
            self.resampleAll(settled: true)
        }
    }

    // ---- window level ----

    func wantedLevel() -> NSWindow.Level {
        if onTop || moving { return .floating }
        switch levelName {
        case "icons":    return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        case "normal":   return .normal
        case "floating": return .floating
        default:         return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        }
    }

    func wanted(_ p: PanelHost) -> Bool {
        !hidden && p.available && (p !== bedrock || showBedrock)
    }

    // No per-tick SetWindowPos(HWND_BOTTOM) equivalent is needed: on macOS the
    // level is absolute and the window server enforces it, so there is nothing
    // to keep fighting. Reasserting is still cheap insurance after a space
    // switch or a screen change, which can reorder within a level.
    //
    // Also where each panel is shown or put away, since that changes with the
    // data as much as with the menu: the Bedrock panel appears by itself the
    // first time its snapshot does.
    func applyLevel() {
        let want = wantedLevel()
        for p in panels {
            if wanted(p) {
                if p.window.level != want { p.window.level = want }
                p.window.orderFrontRegardless()
            } else if p.window.isVisible {
                p.window.orderOut(nil)
            }
        }
    }

    // ---- appearance ----

    // Rebuilding a proxy costs an image decode, so it happens only when the
    // wallpaper, the screen layout or the system appearance actually changed.
    // Returns true when anything was rebuilt.
    @discardableResult
    func refreshProxies(force: Bool = false) -> Bool {
        let want = NSScreen.screens
        if !force, proxies.count == want.count,
           zip(proxies, want).allSatisfy({ $0.key == wallpaperKey(for: $1) }) { return false }
        proxies = want.compactMap { buildProxy(for: $0) }
        return true
    }

    // Whichever palette reaches the target with less ink wins. No luminance
    // threshold to tune, and it is the definition of low profile.
    //
    // Hysteresis in two parts, because a bare comparison oscillates: the
    // challenger must win by a margin, and on a timed sample it must win twice.
    // A drag is exempt - the user has just placed it and waiting a minute for
    // the colours to settle would look broken.
    func applyTheme(_ p: PanelHost, settled: Bool) {
        guard let d = p.backdrop, adaptOpacity else {
            p.polarity = appearanceMode == "light" ? paletteLight : paletteDark
            p.view.theme = Theme(palette: p.polarity,
                                 alpha: p.polarity.isDark ? 0.90 : 0.93, halo: false)
            p.view.needsDisplay = true
            return
        }

        let aDark  = minimumAlpha(paletteDark,  target: readability, over: d)
        let aLight = minimumAlpha(paletteLight, target: readability, over: d)

        switch appearanceMode {
        case "light": p.polarity = paletteLight
        case "dark":  p.polarity = paletteDark
        default:
            let current = p.polarity.isDark ? aDark : aLight
            let other   = p.polarity.isDark ? aLight : aDark
            if other + 0.06 < current {
                if settled { p.polarity = p.polarity.isDark ? paletteLight : paletteDark }
                else {
                    p.dwell += 1
                    if p.dwell >= 2 { p.polarity = p.polarity.isDark ? paletteLight : paletteDark; p.dwell = 0 }
                }
            } else { p.dwell = 0 }
        }

        var alpha = p.polarity.isDark ? aDark : aLight
        // A guessed frame of a dynamic wallpaper buys a little extra scrim
        // rather than a little extra confidence.
        if !d.confident { alpha = min(1, alpha + 0.08) }
        p.view.theme = Theme(palette: p.polarity, alpha: alpha, halo: alpha < 0.55)
        p.view.needsDisplay = true
        // Only when the verdict actually moved. The slider is continuous, so
        // logging every call turns one slow drag into hundreds of identical
        // lines and buries the wallpaper changes worth reading.
        let decision = String(format: "%@%.2f", p.polarity.isDark ? "d" : "l", alpha)
        defer { p.lastDecision = decision }
        if verbose, decision != p.lastDecision {
            FileHandle.standardError.write(
                String(format: "ccmon: panel %d Y=%.3f sd=%.3f chroma=%.2f target=%.1f -> %@ alpha=%.2f\n",
                       p.slot, d.meanY, d.sdY, d.chroma, readability,
                       p.polarity.isDark ? "dark" : "light", alpha)
                    .data(using: .utf8)!)
        }
    }

    var verbose = UserDefaults.standard.bool(forKey: "verbose")

    func resample(_ p: PanelHost, settled: Bool) {
        p.backdrop = sampleBackdrop(p.window.frame, proxies)
        applyTheme(p, settled: settled)
    }

    func resampleAll(settled: Bool) {
        for p in panels { resample(p, settled: settled) }
    }

    // ---- data ----

    func poll() {
        for p in panels { p.poll(); fit(p) }
        applyLevel()
        updateStatusItem()
    }

    // The worst-pacing bar on a panel. Ranked by tone rather than by
    // percentage, so a mid-week 60% on the weekly quota does not outrank a
    // session that is genuinely being overspent. A block outranks everything:
    // it is the one state in which nothing works.
    func worstTone(_ r: Reading?) -> String {
        guard let r, !r.stale else { return "muted" }
        if !r.alert.isEmpty { return "crit" }
        return r.rows.map { Pace.of($0.util, $0.resetsAt, $0.windowSec).tone }
            .max { toneRank($0) < toneRank($1) } ?? "muted"
    }

    func dot(_ tone: String) -> NSImage {
        // 18x18 with a 12pt dot centred: the menu bar's icon box is 18pt tall,
        // and the Windows 16x16 at (2,2) sits visibly low in it. The block form
        // re-runs per backing scale, so Retina needs no second asset.
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            // Always the dark tone set, whatever the panel is wearing. The menu
            // bar is translucent grey rather than the wallpaper, and the
            // arithmetic favours it: on a light menu bar the dark palette's
            // green reaches 3.29:1 against white where the light set's manages
            // 2.78:1. One dot means the same thing on every machine.
            toneColor(tone, paletteDark).setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12)).fill()
            return true
        }
        // The colour IS the signal. A template image would be re-tinted to the
        // menu bar's own colour and the verdict would vanish.
        img.isTemplate = false
        return img
    }

    // One dot, and it speaks for the account Claude Code is using right now:
    // the Bedrock panel when the active profile is a Bedrock one, the
    // subscription otherwise. Without claude-config to ask, whichever panel has
    // live data, the subscription first.
    func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let sub = main.reading, bed = bedrock?.reading
        let onBedrock = activeIsBedrock()
        var useBedrock = false
        if let bed {
            useBedrock = onBedrock == true
                || (onBedrock == nil && (sub == nil || sub!.stale) && !bed.stale)
        }
        let r = useBedrock ? bed : sub
        button.image = dot(worstTone(r))
        if let r, !r.stale {
            button.toolTip = "ccmon  " + r.summary + (r.alert.isEmpty ? "" : "  " + r.alert)
        } else {
            button.toolTip = "ccmon - no data"
        }
    }

    // ---- profiles ----

    // claude-config's profiles: one JSON file each, the active one named in
    // .active. Read whenever the menu opens rather than cached, since
    // claude-config is as likely to be run from a terminal as from here.
    func profileNames() -> [String] {
        guard !profilesDir.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) else { return [] }
        return files.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func activeProfile() -> String {
        guard !profilesDir.isEmpty,
              let s = try? String(contentsOfFile: profilesDir + "/.active", encoding: .utf8) else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Whether the active profile routes Claude Code through Bedrock. nil when
    // there is no claude-config to ask, and the menu bar has to guess.
    func activeIsBedrock() -> Bool? {
        let name = activeProfile()
        guard !name.isEmpty,
              let data = FileManager.default.contents(atPath: profilesDir + "/" + name + ".json"),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let env = d["env"] as? [String: Any]
        return (env?["CLAUDE_CODE_USE_BEDROCK"] as? String) == "1"
    }

    func fillProfiles() {
        let names = profileCmd.isEmpty ? [] : profileNames()
        miProfile.isHidden = names.isEmpty
        let sub = NSMenu()
        let active = activeProfile()
        for n in names {
            let mi = NSMenuItem(title: n, action: #selector(switchProfile(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = n
            mi.state = n == active ? .on : .off
            sub.addItem(mi)
        }
        // Said here rather than in a notification after the click, which an
        // ad-hoc signed accessory app cannot post (see alert below).
        sub.addItem(.separator())
        let note = NSMenuItem(title: "Applies to Claude Code sessions started after a switch",
                              action: nil, keyEquivalent: "")
        note.isEnabled = false
        sub.addItem(note)
        miProfile.submenu = sub
    }

    @objc func switchProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, name != activeProfile() else { return }
        run(shellQuote(profileCmd) + " " + shellQuote(name)) { [weak self] status in
            guard let self else { return }
            if status != 0 { self.alert("claude-config \(name) failed (exit \(status)).") }
            self.fillProfiles()
            self.updateStatusItem()
        }
    }

    // ---- menu ----

    func updateMenuLabels() {
        miTop.title = onTop ? "Send to desktop" : "Bring to front"
        miHide.title = hidden ? "Show widget" : "Hide widget"
        miMove.title = moving ? "Done moving" : "Move widget"
        miBedrock.isHidden = !(bedrock?.available ?? false)
        miBedrock.title = showBedrock ? "Hide Bedrock panel" : "Show Bedrock panel"
        miBedrockBoard.isHidden = bedrockLink.isEmpty

        miAuto.state  = appearanceMode == "auto"  ? .on : .off
        miLight.state = appearanceMode == "light" ? .on : .off
        miDark.state  = appearanceMode == "dark"  ? .on : .off
        miAdapt.state = adaptOpacity ? .on : .off

        // The slider says what it is promising and what that costs, because a
        // ratio on its own means nothing to most people and an opacity means
        // nothing about legibility. The main panel's figures: the slider moves
        // every panel, and one line has room for one.
        sliderView.slider.isEnabled = adaptOpacity
        sliderView.label.stringValue = adaptOpacity
            ? String(format: "Readability  %.1f:1 · %@ · scrim %.0f%%",
                     readability, main.polarity.isDark ? "dark" : "light", main.view.theme.alpha * 100)
            : "Readability  (not adapting to the wallpaper)"
    }

    // Under the desktop icons the panel never sees a click, so this lifts it
    // just long enough to be dragged and drops it back where it was in the
    // z-order the moment the drag ends. One menu item instead of the two
    // trips through "Bring to front" and "Send to desktop" that it replaces.
    @objc func toggleMoving() {
        moving.toggle()
        if moving { hidden = false }
        applyLevel()
        updateMenuLabels()
    }

    func endMoving() {
        guard moving else { return }
        moving = false
        applyLevel()
        updateMenuLabels()
    }

    @objc func toggleTop() {
        onTop.toggle()
        hidden = false
        applyLevel()
        updateMenuLabels()
    }

    @objc func toggleHidden() {
        hidden.toggle()
        applyLevel()
        updateMenuLabels()
    }

    @objc func toggleBedrock() {
        showBedrock.toggle()
        UserDefaults.standard.set(showBedrock, forKey: "showBedrock")
        applyLevel()
        updateMenuLabels()
    }

    @objc func openWallboard() {
        guard !wallboardURL.isEmpty, let u = URL(string: wallboardURL) else {
            alert("No wallboard URL configured. Run ./ccmon."); return
        }
        NSWorkspace.shared.open(u)
    }

    var bedrockLink: String { bedrock?.reading?.link ?? "" }

    @objc func openBedrockUsage() {
        if let u = URL(string: bedrockLink) { NSWorkspace.shared.open(u) }
    }

    @objc func refreshNow() {
        guard !pollerPath.isEmpty else { alert("No poller configured. Run ./ccmon."); return }
        // The Bedrock poller is installed beside this one and throttles itself
        // to a quarter or a whole hour; a click is the one time it should not.
        let b = (pollerPath as NSString).deletingLastPathComponent + "/bedrock-poll.sh"
        let command = shellQuote(pollerPath) + "; b=" + shellQuote(b) + "; [ ! -x \"$b\" ] || \"$b\" --force"
        // Unlike the C# once did, this waits for the pollers rather than
        // re-reading the moment they start and repainting with the old values.
        run(command) { [weak self] _ in self?.poll() }
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

    @objc func readabilityChanged(_ sender: NSSlider) {
        readability = CGFloat(sender.doubleValue)
        UserDefaults.standard.set(sender.doubleValue, forKey: "readability")
        // Recompute from the cached sample rather than re-reading the wallpaper:
        // dragging a slider is arithmetic, not a measurement.
        for p in panels { applyTheme(p, settled: true) }
        updateMenuLabels()
    }

    @objc func setAppearanceMode(_ sender: NSMenuItem) {
        appearanceMode = sender.representedObject as? String ?? "auto"
        UserDefaults.standard.set(appearanceMode, forKey: "appearance")
        for p in panels { applyTheme(p, settled: true) }
        updateMenuLabels()
    }

    // The escape hatch: stop looking at the wallpaper at all. Also the kill
    // switch if a future macOS takes desktopImageURL away.
    @objc func toggleAdapt() {
        adaptOpacity.toggle()
        UserDefaults.standard.set(adaptOpacity, forKey: "adaptOpacity")
        if adaptOpacity { refreshProxies(force: true) }
        resampleAll(settled: true)
        updateMenuLabels()
    }

    @objc func quit() { NSApp.terminate(nil) }

    // An accessory app has no menu bar of its own to put a message in, and
    // UNUserNotificationCenter needs an authorisation keyed to a code signature
    // that every ad-hoc rebuild changes. These cases are genuine
    // misconfiguration or failure and rare, so an alert is the honest way to
    // say so.
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
        miMove = item("Move widget", #selector(toggleMoving))
        miBedrock = item("Hide Bedrock panel", #selector(toggleBedrock))
        menu.addItem(miMove)
        menu.addItem(miTop)
        menu.addItem(miHide)
        menu.addItem(miBedrock)
        menu.addItem(.separator())

        let appearance = NSMenu()
        func mode(_ title: String, _ key: String) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: #selector(setAppearanceMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = key
            return mi
        }
        miAuto = mode("Auto (follows the wallpaper)", "auto")
        miLight = mode("Light", "light")
        miDark = mode("Dark", "dark")
        miAdapt = item("Adapt opacity to the wallpaper", #selector(toggleAdapt))
        appearance.addItem(miAuto)
        appearance.addItem(miLight)
        appearance.addItem(miDark)
        appearance.addItem(.separator())
        appearance.addItem(miAdapt)
        let miAppearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        miAppearance.submenu = appearance
        menu.addItem(miAppearance)

        // In the main menu rather than the submenu: a slider you have to keep a
        // submenu open to reach is a slider nobody drags.
        sliderView = SliderItemView(target: self, action: #selector(readabilityChanged(_:)),
                                    value: Double(readability))
        let miSlider = NSMenuItem()
        miSlider.view = sliderView
        menu.addItem(miSlider)
        menu.addItem(.separator())
        miProfile = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        menu.addItem(miProfile)
        menu.addItem(item("Open wallboard", #selector(openWallboard)))
        miBedrockBoard = item("Open Bedrock usage", #selector(openBedrockUsage))
        menu.addItem(miBedrockBoard)
        menu.addItem(item("Refresh now", #selector(refreshNow)))
        menu.addItem(item("Update ccmon", #selector(updateCcmon)))
        menu.addItem(.separator())
        let q = item("Quit", #selector(quit))
        q.keyEquivalent = "q"
        menu.addItem(q)
        fillProfiles()
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
            fillProfiles()
            updateMenuLabels()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 2), in: sender)
        } else {
            toggleTop()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { updateMenuLabels() }

    // ---- start ----

    func makePanel(_ path: String, _ read: @escaping (String) -> Reading?,
                   slot: Int, optional: Bool, placeholder: [Row]) -> PanelHost {
        let p = PanelHost(path: path, read: read, slot: slot, optional: optional,
                          placeholder: placeholder)
        let window = DesktopWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: p.height),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        // No shadow, deliberately: the borderless WinForms panel has none
        // either, the hairline border is the depth cue the design already uses,
        // and a real macOS shadow over a wallpaper reads as "floating panel",
        // which is the impression this is trying not to give.
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        let view = PanelView(frame: NSRect(x: 0, y: 0, width: W, height: p.height))
        view.placeholder = placeholder
        view.onDragEnd = { [weak self, weak p] in
            guard let self, let p else { return }
            // A drag can end off-screen, on any number of monitors. window.screen
            // is the display holding most of the window, and nil once it holds
            // none - where the primary is the same answer Windows lands on.
            let vf = p.window.screen?.visibleFrame ?? self.workArea()
            p.window.setFrameOrigin(self.clamp(vf, p.window.frame.origin, p.height))
            self.endMoving()
            self.resample(p, settled: true)
        }
        window.contentView = view
        let vf = workArea()
        window.setFrameOrigin(clamp(vf, home(vf, p), p.height))
        p.window = window
        p.view = view
        return p
    }

    func start() {
        // Before anything builds a menu out of them: the slider is constructed
        // with whatever readability holds, so reading this later would show a
        // saved preference as the default.
        readability = UserDefaults.standard.object(forKey: "readability") as? CGFloat ?? 4.5
        appearanceMode = UserDefaults.standard.string(forKey: "appearance") ?? "auto"
        adaptOpacity = UserDefaults.standard.object(forKey: "adaptOpacity") as? Bool ?? true
        showBedrock = UserDefaults.standard.object(forKey: "showBedrock") as? Bool ?? true

        lastGeometry = geometry()
        // Before the first read there are no rows to lay out, but an empty panel
        // looks broken rather than early.
        main = makePanel(snapshotPath, Reading.subscription, slot: 0, optional: false,
                         placeholder: [Row(label: "5h session", value: "--"),
                                       Row(label: "7d all models", value: "--")])
        if !bedrockPath.isEmpty {
            bedrock = makePanel(bedrockPath, Reading.bedrock, slot: 1, optional: true,
                                placeholder: [Row(label: "Bedrock", value: "--")])
        }

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
        // A space switch can reorder within a level, and each Space can carry
        // its own wallpaper - so this invalidates the proxies, it does not just
        // re-sample them.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screensChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // Exactly when a light/dark .heic pair flips underneath us.
        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.refreshProxies(force: true)
                self.resampleAll(settled: true)
            }

        refreshProxies(force: true)
        resampleAll(settled: true)

        poll()      // also puts each panel on screen, or not

        // Fast until the first read lands, then the configured cadence.
        var interval: TimeInterval = 3
        func schedule() {
            timer?.invalidate()
            let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.poll()
                // The wallpaper has no change notification, so it is polled -
                // but only every fourth tick, since resolving it may cross to
                // WindowServer and two minutes of latency on a manual wallpaper
                // change is not something anyone notices.
                self.wallpaperTick += 1
                if self.wallpaperTick % 4 == 0 {
                    if self.refreshProxies() { self.resampleAll(settled: false) }
                }
                // Belt and braces for the notifications above: a screen change
                // that produced none, or produced them all before the desktop
                // had finished moving, is caught here within one refresh rather
                // than leaving the widget stranded until the next login.
                if self.geometry() != self.lastGeometry { self.goHome() }
                if self.main.everRead, interval != self.refreshSeconds {
                    interval = self.refreshSeconds
                    schedule()
                }
            }
            // .common, not the default mode: a timer in the default mode stops
            // firing while a menu is open, and the countdown visibly freezes
            // under the menu the user opened to look at it.
            RunLoop.main.add(t, forMode: .common)
            timer = t
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
            case "--snapshot":    c.snapshotPath = value
            case "--bedrock":     c.bedrockPath = value
            case "--profiles":    c.profilesDir = value
            case "--profile-cmd": c.profileCmd = value
            case "--wallboard":   c.wallboardURL = value
            case "--poller":      c.pollerPath = value
            case "--update":      c.updateCommand = value
            case "--level":       c.levelName = value
            case "--refresh":     c.refreshSeconds = TimeInterval(value) ?? 30
            default: break
            }
        }
        guard !c.snapshotPath.isEmpty else {
            // stderr, not a dialog: the Windows version needs a MessageBox
            // because a /target:winexe process has no console, while here this
            // goes to the agent's log where launchctl and Console can find it.
            let usage = "usage: CcmonWidget --snapshot <path> [--bedrock <path>] [--profiles <dir>]\n"
                      + "                   [--profile-cmd <path>] [--wallboard <url>] [--poller <path>]\n"
                      + "                   [--update <path>] [--level desktop|icons|normal|floating] [--refresh <s>]\n"
            FileHandle.standardError.write(usage.data(using: .utf8)!)
            exit(2)
        }
        app.setActivationPolicy(.accessory)
        controller = c
        c.start()
        app.run()
    }
}
