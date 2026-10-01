// ccmon desktop widget.
//
// Built as its own executable rather than hosted by powershell.exe, because
// Windows keys a tray icon's identity on (executable path + uID). Every
// PowerShell-hosted icon therefore collides with every other one - on this
// machine ours hashed to a stale Citrix installer entry - and can never get its
// own row in Settings > Taskbar, which is what "always show" needs.
//
// Reads only the snapshots the WSL pollers write - the subscription's and, when
// ./ccmon has configured one, the Bedrock gateway's. No credentials, no network.
//
// Build: csc /target:winexe /out:ccmon-widget.exe CcmonWidget.cs

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Windows.Forms;

static class Native {
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
    static readonly IntPtr BOTTOM = new IntPtr(1), TOPMOST = new IntPtr(-1), NOTOPMOST = new IntPtr(-2);
    const uint NOSIZE = 0x1, NOMOVE = 0x2, NOACTIVATE = 0x10;
    public static void Sink(IntPtr h) { SetWindowPos(h, BOTTOM, 0, 0, 0, 0, NOSIZE | NOMOVE | NOACTIVATE); }
    public static void Lift(IntPtr h) { SetWindowPos(h, TOPMOST, 0, 0, 0, 0, NOSIZE | NOMOVE | NOACTIVATE); }
    public static void Drop(IntPtr h) { SetWindowPos(h, NOTOPMOST, 0, 0, 0, 0, NOSIZE | NOMOVE | NOACTIVATE); }

    // System.Windows.Forms.Screen caches both the monitor list and each
    // monitor's work area, and the invalidation hangs off SystemEvents - the
    // same events we are reacting to, with no ordering guarantee between their
    // handlers and ours. Reading a stale work area is how the widget ends up
    // anchored to a screen that no longer exists, so ask Win32 every time.
    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }

    [DllImport("user32.dll")]
    static extern bool SystemParametersInfo(uint action, uint param, ref RECT v, uint winIni);
    [DllImport("user32.dll")]
    static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO mi);

    const uint SPI_GETWORKAREA = 0x0030, MONITOR_DEFAULTTONEAREST = 2;

    static Rectangle Of(RECT r) {
        return Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
    }

    // The primary monitor's work area - the desktop minus the taskbar.
    public static Rectangle PrimaryWorkArea() {
        RECT r = new RECT();
        if (SystemParametersInfo(SPI_GETWORKAREA, 0, ref r, 0)) return Of(r);
        return Screen.PrimaryScreen.WorkingArea;            // cannot happen; not worth crashing over
    }

    // The work area of whichever monitor the window is mostly on. NEAREST means
    // a window left behind on an unplugged monitor resolves to a real one.
    public static Rectangle WorkAreaFor(IntPtr h) {
        MONITORINFO mi = new MONITORINFO();
        mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        IntPtr m = MonitorFromWindow(h, MONITOR_DEFAULTTONEAREST);
        if (m != IntPtr.Zero && GetMonitorInfo(m, ref mi)) return Of(mi.rcWork);
        return PrimaryWorkArea();
    }
}

// One bar on a panel: what is used of an allowance that renews at ResetsAt.
// Note, when there is one, leads the small print under the bar.
class Row {
    public string Label, Value, Note = "";
    public double? Util;                // percent of the allowance used; null = nothing to draw
    public long ResetsAt, WindowSec;    // epoch seconds, 0 when absent
}

// What a panel shows: its rows, and whether to believe them. Each snapshot
// kind has its own reader; painting, pacing and the tray only see rows.
class Reading {
    public Row[] Rows = new Row[0];
    public bool Stale = true;
    public string Reason = "", Alert = "", Summary = "";
    public string Link = "";            // a page with the detail behind it, if any
    public double FetchedAtMs;

    public const int WINDOW_5H = 5 * 3600, WINDOW_7D = 7 * 86400;

    static Dictionary<string, object> Load(string path, Reading r) {
        var d = (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(File.ReadAllText(path));
        r.Stale = d.ContainsKey("stale") && Convert.ToBoolean(d["stale"]);
        r.Reason = d.ContainsKey("reason") && d["reason"] != null ? d["reason"].ToString() : "";
        r.FetchedAtMs = Num(d, "fetchedAtMs") ?? Num(d, "checkedAtMs") ?? 0;
        return d;
    }

    public static Reading Subscription(string path) {
        var r = new Reading();
        try {
            var d = Load(path, r);
            r.Rows = new Row[] {
                Percent("5h session",    Num(d, "five_hour"), Epoch(d, "five_hour_resets_at"), WINDOW_5H),
                Percent("7d all models", Num(d, "seven_day"), Epoch(d, "seven_day_resets_at"), WINDOW_7D) };
            r.Summary = "5h " + Math.Round(r.Rows[0].Util ?? 0) + "%  7d " + Math.Round(r.Rows[1].Util ?? 0) + "%";
            return r;
        } catch { return null; }
    }

    static Row Percent(string label, double? util, long resetsAt, long windowSec) {
        return new Row { Label = label, Util = util, ResetsAt = resetsAt, WindowSec = windowSec,
                         Value = util == null ? "--" : Math.Round(util.Value) + "%" };
    }

    // The gateway counts "tokens" weighted by price - a million of them is a
    // dollar - so a token count left means nothing to anyone. The big number
    // is a percentage, as on the subscription panel and the gateway's own
    // dashboard, and what is left is stated in dollars underneath.
    public static Reading Bedrock(string path) {
        var r = new Reading();
        try {
            var d = Load(path, r);
            long resets = Epoch(d, "resets_at");
            DateTimeOffset start = resets > 0
                ? DateTimeOffset.FromUnixTimeSeconds(resets).AddMonths(-1)
                : DateTimeOffset.UtcNow;
            long window = resets > 0 ? resets - start.ToUnixTimeSeconds() : 30 * 86400;

            double used = Num(d, "used") ?? 0, limit = Num(d, "limit") ?? 0;
            bool unlimited = d.ContainsKey("unlimited") && Convert.ToBoolean(d["unlimited"]);
            var rows = new List<Row>();
            Row own = Quota("Bedrock \u00b7 " + start.ToString("MMM"), used, limit, resets, window);
            if (unlimited) { own.Value = "unlimited"; own.Util = null; own.Note = ""; }
            rows.Add(own);
            r.Summary = "Bedrock " + own.Value + (own.Note.Length > 0 ? " \u00b7 " + own.Note : "");

            // The shared pool this user draws from, whichever is fullest. Once
            // it is spent everyone in it is blocked, own quota or not - but
            // until it is fuller than the user's own quota it cannot be what
            // stops them, and a row for it would be noise.
            var pool = d.ContainsKey("pool") ? d["pool"] as Dictionary<string, object> : null;
            if (pool != null && pool.ContainsKey("binding") && Convert.ToBoolean(pool["binding"])) {
                double pu = Num(pool, "used") ?? 0, pl = Num(pool, "limit") ?? 0;
                string name = pool.ContainsKey("name") && pool["name"] != null ? pool["name"].ToString() : "shared";
                if (pl > 0) rows.Add(Quota(name.ToLowerInvariant() + " pool", pu, pl, resets, window));
            }
            r.Rows = rows.ToArray();

            if (d.ContainsKey("blocked") && Convert.ToBoolean(d["blocked"])) {
                var why = d.ContainsKey("block_reasons") ? d["block_reasons"] as object[] : null;
                r.Alert = "BLOCKED" + (why != null && why.Length > 0 ? " (" + string.Join(", ", why) + ")" : "");
            }

            // The dashboard's own filter is a case-insensitive substring match,
            // so the address goes in lowercased; its month is the UTC one.
            string dash = d.ContainsKey("dashboard") && d["dashboard"] != null ? d["dashboard"].ToString() : "";
            string email = d.ContainsKey("email") && d["email"] != null ? d["email"].ToString() : "";
            if (dash.Length > 0 && email.Length > 0)
                r.Link = dash.TrimEnd('/') + "/?month=" + DateTime.UtcNow.ToString("yyyy-MM", CultureInfo.InvariantCulture)
                       + "&filter=" + Uri.EscapeDataString(email.ToLowerInvariant());
            return r;
        } catch { return null; }
    }

    static Row Quota(string label, double used, double limit, long resetsAt, long windowSec) {
        double? util = limit > 0 ? used / limit * 100 : (double?)null;
        return new Row { Label = label, Util = util, ResetsAt = resetsAt, WindowSec = windowSec,
                         Value = util == null ? "--" : Math.Round(util.Value) + "%",
                         Note = limit > 0 ? Dollars(limit - used) + " left" : "" };
    }

    // $182, $9.37, $190k: whole dollars, cents only once they are all there is,
    // and thousands for a pool. Rounded down, as ./ccmon's own summary is: what
    // is left should never read as more than there is.
    public static string Dollars(double weighted) {
        double v = Math.Max(0, weighted / 1e6);
        CultureInfo ic = CultureInfo.InvariantCulture;
        if (v < 10)  return "$" + (Math.Floor(v * 100) / 100).ToString("0.00", ic);
        if (v < 1e4) return "$" + Math.Floor(v).ToString("0", ic);
        if (v < 1e6) return "$" + Math.Floor(v / 1e3).ToString("0", ic) + "k";
        return "$" + (Math.Floor(v / 1e5) / 10).ToString("0.#", ic) + "M";
    }

    static long Epoch(Dictionary<string, object> d, string k) {
        if (!d.ContainsKey(k) || d[k] == null) return 0;
        try { return DateTimeOffset.Parse(d[k].ToString()).ToUnixTimeSeconds(); } catch { return 0; }
    }
    static double? Num(Dictionary<string, object> d, string k) {
        if (!d.ContainsKey(k) || d[k] == null) return null;
        try { return Convert.ToDouble(d[k]); } catch { return null; }
    }
}

// The point of the project: not "how much have I used" but "speed up or slow
// down to finish this window at TARGET". Mirrors pace() in chart-lib.js - keep
// the two in step.
class Pace {
    public const double TARGET = 95;
    public long Remaining;
    public double Elapsed;      // 0..1 through the window
    public double PaceNow;      // where usage would be if spent evenly
    public double? Headroom, Factor, PerHour, PerDay;
    public string Verdict = "no data";
    public string Tone = "muted";

    public static Pace Of(double? util, long resetsAt, long windowSec) {
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var p = new Pace();
        if (resetsAt <= 0) return p;
        p.Remaining = Math.Max(0, resetsAt - now);
        p.Elapsed = Math.Min(1, Math.Max(0, (windowSec - p.Remaining) / (double)windowSec));
        p.PaceNow = TARGET * p.Elapsed;
        if (util == null) return p;

        double u = util.Value;
        p.Headroom = TARGET - u;
        if (p.Remaining > 0) {
            p.PerHour = p.Headroom / (p.Remaining / 3600.0);
            p.PerDay  = p.Headroom / (p.Remaining / 86400.0);
        }
        if (u >= TARGET)      { p.Verdict = "over budget";  p.Tone = "crit"; return p; }
        if (p.Remaining <= 0) { p.Verdict = "window closed";                 return p; }
        if (p.Elapsed < 0.05) { p.Verdict = "just reset";                    return p; }

        double rateNow = u / p.Elapsed;
        double rateNeeded = p.Headroom.Value / Math.Max(1e-6, 1 - p.Elapsed);
        double f = rateNow > 0 ? rateNeeded / rateNow : double.PositiveInfinity;
        p.Factor = f;

        // The factor explodes at both ends of a window, so cap what is shown.
        if (double.IsInfinity(f) || f >= 3) { p.Verdict = "burn freely"; p.Tone = "good"; }
        else if (f > 1.15)  { p.Verdict = "faster " + f.ToString("0.0") + "x";    p.Tone = "good"; }
        else if (f >= 0.85) { p.Verdict = "on pace";                              p.Tone = "good"; }
        else if (f >= 0.5)  { p.Verdict = "ease off " + f.ToString("0.0") + "x";  p.Tone = "warn"; }
        else                { p.Verdict = "slow down " + f.ToString("0.0") + "x"; p.Tone = "crit"; }
        return p;
    }

    // Mirrors resetPhrase() in chart-lib.js. Sub-minute counts down in seconds
    // rather than collapsing to a useless "now"; once the reset time has passed,
    // which it can between the rollover and the next poll, it states when.
    public static string Phrase(long resetsAt) {
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        long d = resetsAt - now;
        if (d <= 0)
            return "reset at " + DateTimeOffset.FromUnixTimeSeconds(resetsAt).ToLocalTime().ToString("HH:mm");
        if (d >= 86400) return string.Format("resets in {0}d {1}h", d / 86400, d % 86400 / 3600);
        if (d >= 3600)  return string.Format("resets in {0}h {1}m", d / 3600, d % 3600 / 60);
        if (d >= 60)    return string.Format("resets in {0}m", d / 60);
        return "resets in " + d + "s";
    }
}

// Lives on the desktop: never in alt-tab, never takes focus.
class DesktopForm : Form {
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x00000080;   // WS_EX_TOOLWINDOW
            cp.ExStyle |= 0x08000000;   // WS_EX_NOACTIVATE
            return cp;
        }
    }
    protected override bool ShowWithoutActivation { get { return true; } }
}

// One panel on the desktop and the snapshot behind it. Slot is its place in
// the stack: home for slot 1 is directly below slot 0.
class PanelHost {
    public DesktopForm Form;
    public string Path;
    public Func<string, Reading> Read;
    public Row[] Placeholder;
    public Reading Data;
    public bool EverRead;
    public int Slot;
    public int Height;          // follows the number of rows; see Program.Fit
    public bool Dragging;
    public Point DragOrigin;

    // Whether there is anything to show. The Bedrock snapshot only exists on
    // a machine ./ccmon has configured for it; the subscription panel is
    // always wanted, if only to say that WSL is not up yet.
    public bool Optional;
    public bool Available { get { return !Optional || EverRead; } }

    public Row[] Rows { get { return Data != null ? Data.Rows : Placeholder; } }

    public void Poll() {
        if (Optional && !File.Exists(Path)) { Data = null; EverRead = false; return; }
        Reading r = Read(Path);
        if (r != null) { Data = r; EverRead = true; } else { Data = null; }
    }
}

static class Program {
    // A panel is as tall as its rows: two on the subscription panel, one or two
    // on the Bedrock one. 190 for two.
    const int W = 268, PAD = 16, ROW = 74, FOOT = 26, RADIUS = 16, MARGIN = 24, GAP = 12;
    static int HeightFor(int rows) { return PAD + rows * ROW + FOOT; }

    static readonly Color cSurface = Color.FromArgb(26, 26, 25);
    static readonly Color cText    = Color.FromArgb(245, 245, 243);
    static readonly Color cMuted   = Color.FromArgb(143, 142, 134);
    static readonly Color cTrack   = Color.FromArgb(56, 56, 52);
    static readonly Color cGood    = Color.FromArgb(25, 158, 112);
    static readonly Color cWarn    = Color.FromArgb(234, 179, 8);
    static readonly Color cCrit    = Color.FromArgb(230, 103, 103);

    // Brushes and fonts are created once: rebuilding them per repaint leaks GDI
    // handles in something meant to run for days.
    static SolidBrush bText, bMuted, bTrack, bGood, bWarn, bCrit;
    static Pen pBorder;
    static Font fLabel, fBig, fSmall;

    static string snapshotPath = "", bedrockPath = "", profilesDir = "", profileCmd = "";
    static string wallboardUrl = "", distro = "", repo = "";
    static int refreshSeconds = 30;

    static PanelHost main, bedrock;     // bedrock is null when no --bedrock was given
    static NotifyIcon tray;
    static Timer timer;
    static bool onTop = false;      // false = pinned to the desktop
    static bool hidden = false;     // the whole widget, from the tray
    static bool showBedrock = true; // the Bedrock panel alone; remembered
    static IntPtr trayHandle = IntPtr.Zero;

    static IEnumerable<PanelHost> Panels() {
        yield return main;
        if (bedrock != null) yield return bedrock;
    }

    static bool Wanted(PanelHost p) {
        return !hidden && p.Available && (p != bedrock || showBedrock);
    }

    // Colour comes from the pace tone and nowhere else - see pace() in
    // chart-lib.js. Tinting by raw utilisation instead would put a threshold
    // that cannot see the clock next to a verdict that can, and past the
    // halfway mark of a window the two disagree: 51% used is on budget.
    static Color ToneColor(string tone) {
        if (tone == "good") return cGood;
        if (tone == "warn") return cWarn;
        if (tone == "crit") return cCrit;
        return cMuted;
    }
    // Home is the top-right corner of the work area, one margin in, with each
    // further panel stacked below the ones before - however tall they are now.
    static Point HomeIn(Rectangle wa, PanelHost p) {
        int y = wa.Top + MARGIN;
        foreach (PanelHost q in Panels())
            if (q != null && q.Slot < p.Slot) y += q.Height + GAP;
        return new Point(wa.Right - W - MARGIN, y);
    }

    // Pull a position wholly inside the work area, keeping the margin where
    // there is room for one. Max wraps Min so that on a screen too small for
    // both the left and top edges win: a widget hanging off the right is the
    // bug being fixed, and one hanging off the left would just be its mirror.
    static Point ClampInto(Rectangle wa, Point p, int h) {
        return new Point(
            Math.Max(wa.Left + MARGIN, Math.Min(p.X, wa.Right  - W - MARGIN)),
            Math.Max(wa.Top  + MARGIN, Math.Min(p.Y, wa.Bottom - h - MARGIN)));
    }

    // Windows leaves a borderless, never-activated tool window exactly where it
    // was when the desktop changes shape, so the widget has to move itself.
    //
    // Always home, even when it has been dragged: the arrangement it was placed
    // in no longer exists, and after switching to a single wide screen its old
    // spot is nowhere in particular - the middle of the width, in the report
    // that prompted this. A hand-placed position survives everything else.
    static void GoHome() {
        lastWorkArea = Native.PrimaryWorkArea();
        foreach (PanelHost p in Panels())
            p.Form.Location = ClampInto(lastWorkArea, HomeIn(lastWorkArea, p), p.Height);
    }

    static Rectangle lastWorkArea = Rectangle.Empty;
    static Timer settle;

    // One Win+P, unplug or dock produces a burst of events, and the work area is
    // final at none of them: the resolution changes first and the taskbar
    // settles afterwards, so anything read on the event itself describes a
    // desktop that is still moving. Each event restarts a short timer; only the
    // last one repositions.
    //
    // The Desktop preference category also covers wallpaper, so the tick
    // compares the work area it finds against the last one and does nothing
    // unless the geometry really moved - otherwise changing the background
    // would send a hand-placed widget home.
    static void DisplayChanged() {
        if (settle == null) {
            settle = new Timer();
            settle.Interval = 900;
            settle.Tick += delegate {
                settle.Stop();
                if (Native.PrimaryWorkArea() != lastWorkArea) GoHome();
            };
        }
        settle.Stop();
        settle.Start();
    }

    static void OnDisplayEvent() {
        try { main.Form.BeginInvoke((MethodInvoker)delegate { DisplayChanged(); }); } catch { }
    }

    // Ranked so the tray, which has one dot for several bars, can show the worst.
    static int ToneRank(string tone) {
        if (tone == "crit") return 3;
        if (tone == "warn") return 2;
        if (tone == "good") return 1;
        return 0;               // muted: no reading, or a window too young to judge
    }

    // The Bedrock panel's visibility outlives the process, unlike "bring to
    // front": someone who never uses Bedrock should not have to hide it again
    // at every logon.
    const string REG_KEY = @"Software\ccmon";
    static void LoadPrefs() {
        try {
            using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(REG_KEY))
                if (k != null) showBedrock = Convert.ToInt32(k.GetValue("ShowBedrock", 1)) != 0;
        } catch { }
    }
    static void SavePrefs() {
        try {
            using (var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(REG_KEY))
                k.SetValue("ShowBedrock", showBedrock ? 1 : 0, Microsoft.Win32.RegistryValueKind.DWord);
        } catch { }
    }

    [STAThread]
    static int Main(string[] args) {
        for (int i = 0; i < args.Length - 1; i++) {
            if (args[i] == "--snapshot")    snapshotPath  = args[i + 1];
            if (args[i] == "--bedrock")     bedrockPath   = args[i + 1];
            if (args[i] == "--profiles")    profilesDir   = args[i + 1];
            if (args[i] == "--profile-cmd") profileCmd    = args[i + 1];
            if (args[i] == "--wallboard")   wallboardUrl  = args[i + 1];
            if (args[i] == "--distro")      distro        = args[i + 1];
            if (args[i] == "--repo")        repo          = args[i + 1];
            if (args[i] == "--refresh")     int.TryParse(args[i + 1], out refreshSeconds);
        }
        if (snapshotPath.Length == 0) {
            MessageBox.Show("Usage: ccmon-widget.exe --snapshot <path> [--bedrock <path>] "
                          + "[--profiles <dir>] [--profile-cmd <wsl path>] "
                          + "[--wallboard <url>] [--distro <name>] [--repo <wsl path>]", "ccmon");
            return 2;
        }

        Application.EnableVisualStyles();
        bText = new SolidBrush(cText); bMuted = new SolidBrush(cMuted); bTrack = new SolidBrush(cTrack);
        bGood = new SolidBrush(cGood); bWarn = new SolidBrush(cWarn);   bCrit  = new SolidBrush(cCrit);
        pBorder = new Pen(Color.FromArgb(70, 255, 255, 255), 1);
        fLabel = new Font("Segoe UI", 8.5f);
        fBig   = new Font("Segoe UI Semibold", 21f);
        fSmall = new Font("Segoe UI", 7.5f);
        LoadPrefs();

        lastWorkArea = Native.PrimaryWorkArea();
        // Before the first read there are no rows to lay out, but an empty
        // panel looks broken rather than early.
        main = MakePanel(snapshotPath, Reading.Subscription,
                         new Row[] { new Row { Label = "5h session", Value = "--" },
                                     new Row { Label = "7d all models", Value = "--" } }, 0, false);
        if (bedrockPath.Length > 0)
            bedrock = MakePanel(bedrockPath, Reading.Bedrock,
                                new Row[] { new Row { Label = "Bedrock", Value = "--" } }, 1, true);

        // DisplaySettingsChanged is the resolution, monitors arriving and
        // leaving, and dock or undock. UserPreferenceChanged/Desktop is the work
        // area itself moving - a taskbar change, which lands after the display
        // one and is what makes the first reading wrong. Both are raised off the
        // UI thread, hence the marshalling.
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged += delegate { OnDisplayEvent(); };
        Microsoft.Win32.SystemEvents.UserPreferenceChanged +=
            delegate(object src, Microsoft.Win32.UserPreferenceChangedEventArgs ev) {
                if (ev.Category == Microsoft.Win32.UserPreferenceCategory.Desktop) OnDisplayEvent();
            };

        BuildTray();

        timer = new Timer();
        timer.Interval = 3000;   // fast until the first read; WSL may still be waking
        timer.Tick += delegate {
            Refresh();
            // Belt and braces for the events above: a display change that
            // produced none, or produced them all before the desktop had
            // finished moving, is caught here within one refresh instead of
            // leaving the widget stranded until the next logon.
            if (Native.PrimaryWorkArea() != lastWorkArea) GoHome();
            if (main.EverRead && timer.Interval != refreshSeconds * 1000)
                timer.Interval = refreshSeconds * 1000;
        };
        timer.Start();

        // The main form is shown unconditionally once, so that it has a handle
        // to marshal onto before anything else runs.
        main.Form.Show();
        Refresh();
        Application.Run();
        return 0;
    }

    static PanelHost MakePanel(string path, Func<string, Reading> read, Row[] placeholder,
                               int slot, bool optional) {
        var p = new PanelHost { Path = path, Read = read, Placeholder = placeholder,
                                Slot = slot, Optional = optional };
        p.Height = HeightFor(placeholder.Length);
        var f = new DesktopForm();
        f.Text = "ccmon";
        f.FormBorderStyle = FormBorderStyle.None;
        f.StartPosition = FormStartPosition.Manual;
        f.ShowInTaskbar = false;
        f.TopMost = false;
        f.BackColor = cSurface;
        f.Opacity = 0.90;
        f.Size = new Size(W, p.Height);
        f.Location = ClampInto(lastWorkArea, HomeIn(lastWorkArea, p), p.Height);
        f.Region = new Region(RoundedPath(0, 0, W, p.Height, RADIUS));
        f.Paint += delegate(object s, PaintEventArgs e) { Paint(p, e.Graphics); };
        p.Form = f;
        HookDrag(p);
        return p;
    }

    // Everything a tick does: re-read, show or hide, repaint, re-sink.
    static void Refresh() {
        foreach (PanelHost p in Panels()) {
            p.Poll();
            Fit(p);
            bool want = Wanted(p);
            if (want && !p.Form.Visible) p.Form.Show();
            if (!want && p.Form.Visible) p.Form.Hide();
            if (want) p.Form.Invalidate();
        }
        UpdateTray();
        UpdateZOrder();
        UpdateMenuLabels();
    }

    // A pool row comes and goes with the pool's state, so the panel's height
    // does too. The top edge stays put: home is a top-right corner, and a
    // hand-placed panel growing upwards would look like it had moved.
    static void Fit(PanelHost p) {
        int h = HeightFor(p.Rows.Length);
        if (h == p.Height) return;
        p.Height = h;
        Region old = p.Form.Region;
        p.Form.Size = new Size(W, h);
        p.Form.Region = new Region(RoundedPath(0, 0, W, h, RADIUS));
        if (old != null) old.Dispose();
        p.Form.Location = ClampInto(Native.WorkAreaFor(p.Form.Handle), p.Form.Location, h);
    }

    static GraphicsPath RoundedPath(int x, int y, int w, int h, int r) {
        var p = new GraphicsPath();
        int d = r * 2;
        p.AddArc(x, y, d, d, 180, 90);
        p.AddArc(x + w - d, y, d, d, 270, 90);
        p.AddArc(x + w - d, y + h - d, d, d, 0, 90);
        p.AddArc(x, y + h - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    static Brush ToneBrush(string tone) {
        if (tone == "good") return bGood;
        if (tone == "warn") return bWarn;
        if (tone == "crit") return bCrit;
        return bMuted;
    }

    static void Paint(PanelHost p, Graphics g) {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

        int h = p.Height;
        using (GraphicsPath border = RoundedPath(0, 0, W - 1, h - 1, RADIUS))
            g.DrawPath(pBorder, border);

        Reading data = p.Data;
        bool stale = data == null || data.Stale;
        Row[] rows = p.Rows;

        int y = PAD;
        foreach (Row r in rows) {
            DrawRow(g, y, r, stale);
            y += ROW;
        }

        string foot;
        if (!p.EverRead)        foot = "waiting for WSL...";
        else if (data == null)  foot = "snapshot unreadable";
        else if (data.Stale)    foot = "stale - " + data.Reason;
        else                    foot = "updated " + Age(data.FetchedAtMs) + " ago";
        g.DrawString(foot, fSmall, bMuted, PAD, h - PAD - 6);
        if (data != null && data.Alert.Length > 0) {
            SizeF a = g.MeasureString(data.Alert, fSmall);
            g.DrawString(data.Alert, fSmall, bCrit, W - PAD - a.Width, h - PAD - 6);
        }
    }

    static string Age(double fetchedAtMs) {
        double s = (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - fetchedAtMs) / 1000.0;
        if (s < 90)        return (int)s + "s";
        if (s < 90 * 60)   return (int)(s / 60) + "m";
        if (s < 48 * 3600) return (int)(s / 3600) + "h";
        return (int)(s / 86400) + "d";
    }

    static void DrawRow(Graphics g, int y, Row r, bool stale) {
        Pace pc = Pace.Of(stale ? null : r.Util, r.ResetsAt, r.WindowSec);

        g.DrawString(r.Label, fLabel, bMuted, PAD, y);
        SizeF sz = g.MeasureString(r.Value, fBig);
        g.DrawString(r.Value, fBig, stale ? bMuted : bText, W - PAD - sz.Width, y - 6);

        int barY = y + 30, barW = W - 2 * PAD;
        using (GraphicsPath t = RoundedPath(PAD, barY, barW, 6, 3))
            g.FillPath(bTrack, t);
        if (r.Util != null && r.Util > 0) {
            int fw = Math.Max(6, (int)(barW * Math.Min(r.Util.Value, 100) / 100));
            using (GraphicsPath f = RoundedPath(PAD, barY, fw, 6, 3))
                g.FillPath(ToneBrush(pc.Tone), f);   // stale already resolves to muted
        }
        // Where usage would be if the window were spent evenly to 95%. The
        // gap between this tick and the bar end is the whole point.
        if (!stale && r.Util != null && pc.PaceNow > 0 && pc.PaceNow < 100) {
            int px = PAD + (int)(barW * pc.PaceNow / 100);
            g.FillRectangle(bText, px, barY - 3, 2, 12);
        }

        string when = r.ResetsAt > 0 ? Pace.Phrase(r.ResetsAt) : "";
        if (r.Note.Length > 0) when = when.Length > 0 ? r.Note + " \u00b7 " + when : r.Note;
        g.DrawString(when, fSmall, bMuted, PAD, barY + 12);
        if (!stale && r.Util != null) {
            SizeF vs = g.MeasureString(pc.Verdict, fSmall);
            g.DrawString(pc.Verdict, fSmall, ToneBrush(pc.Tone), W - PAD - vs.Width, barY + 12);
        }
    }

    // Other windows reorder constantly, so re-sink every tick unless the tray
    // icon has deliberately lifted us.
    static void UpdateZOrder() {
        foreach (PanelHost p in Panels()) {
            if (!p.Form.Visible) continue;
            DesktopForm f = p.Form;
            if (onTop) {
                if (!f.TopMost) f.TopMost = true;
                Native.Lift(f.Handle);
            } else {
                if (f.TopMost) { f.TopMost = false; Native.Drop(f.Handle); }
                Native.Sink(f.Handle);
            }
        }
    }

    // Left-clicking the tray toggles between the desktop and the front, and
    // shows the widget again if it was hidden - otherwise the click would look
    // like it did nothing.
    static void ToggleTop() {
        onTop = !onTop;
        hidden = false;
        Refresh();
    }

    static void ToggleHidden() {
        hidden = !hidden;
        Refresh();
    }

    static void ToggleBedrock() {
        showBedrock = !showBedrock;
        SavePrefs();
        Refresh();
    }

    static void UpdateMenuLabels() {
        miTop.Text = onTop ? "Send to desktop" : "Bring to front";
        miHide.Text = hidden ? "Show widget" : "Hide widget";
        miBedrock.Visible = bedrock != null && bedrock.Available;
        miBedrock.Text = showBedrock ? "Hide Bedrock panel" : "Show Bedrock panel";
        miBedrockBoard.Visible = BedrockLink().Length > 0;
    }

    static string BedrockLink() {
        return bedrock != null && bedrock.Data != null ? bedrock.Data.Link : "";
    }

    static ToolStripMenuItem miHide, miTop, miBedrock, miBedrockBoard, miProfile, miUpdate;

    static void BuildTray() {
        var menu = new ContextMenuStrip();
        miTop = new ToolStripMenuItem("Bring to front");
        miBedrock = new ToolStripMenuItem("Hide Bedrock panel");
        miProfile = new ToolStripMenuItem("Profile");
        var miBoard = new ToolStripMenuItem("Open wallboard");
        miBedrockBoard = new ToolStripMenuItem("Open Bedrock usage");
        var miRefresh = new ToolStripMenuItem("Refresh now");
        miUpdate = new ToolStripMenuItem("Update ccmon");
        miHide = new ToolStripMenuItem("Hide widget");
        var miExit = new ToolStripMenuItem("Exit");

        miTop.Click += delegate { ToggleTop(); };
        miBedrock.Click += delegate { ToggleBedrock(); };
        miBoard.Click += delegate {
            if (wallboardUrl.Length > 0) Process.Start(wallboardUrl);
            else tray.ShowBalloonTip(4000, "ccmon", "No wallboard URL configured. Run ./ccmon.", ToolTipIcon.Info);
        };
        miBedrockBoard.Click += delegate {
            string link = BedrockLink();
            if (link.Length > 0) Process.Start(link);
        };
        // The Bedrock poller throttles itself to a quarter or a whole hour; a
        // click is the one time it should not.
        miRefresh.Click += delegate {
            RunInWsl("\"$HOME/.claude/ccmon/usage-poll.sh\"; b=\"$HOME/.claude/ccmon/bedrock-poll.sh\"; "
                   + "[ ! -x \"$b\" ] || \"$b\" --force", delegate(int code) { Refresh(); });
        };
        miUpdate.Click += delegate {
            if (repo.Length == 0) {
                tray.ShowBalloonTip(4000, "ccmon", "No repo path configured. Run ./ccmon.", ToolTipIcon.Info);
                return;
            }
            tray.ShowBalloonTip(3000, "ccmon", "Updating - this may restart the widget.", ToolTipIcon.Info);
            // ccmon update may reinstall and restart this very process, in which
            // case the completion balloon never fires. That is fine: the widget
            // coming back is the visible result.
            RunInWsl("cd " + Quote(repo) + " && ./ccmon update --yes", delegate(int code) {
                try {
                    tray.ShowBalloonTip(5000, "ccmon",
                        code == 0 ? "Update finished." : "Update failed (exit " + code + ").",
                        code == 0 ? ToolTipIcon.Info : ToolTipIcon.Warning);
                } catch { }
            });
        };
        miHide.Click += delegate { ToggleHidden(); };
        miExit.Click += delegate {
            tray.Visible = false;
            if (trayHandle != IntPtr.Zero) Native.DestroyIcon(trayHandle);
            Application.Exit();
        };

        // The profile list is read as the menu opens, not cached: claude-config
        // is as likely to be run from a terminal as from here.
        menu.Opening += delegate { FillProfiles(); UpdateMenuLabels(); };

        menu.Items.AddRange(new ToolStripItem[] {
            miTop, miHide, miBedrock, new ToolStripSeparator(),
            miProfile, miBoard, miBedrockBoard, miRefresh, miUpdate, new ToolStripSeparator(), miExit });

        tray = new NotifyIcon();
        tray.ContextMenuStrip = menu;
        tray.Text = "ccmon";
        tray.Icon = MakeIcon("muted");   // until the first snapshot lands
        tray.Visible = true;
        tray.MouseClick += delegate(object s, MouseEventArgs e) {
            if (e.Button == MouseButtons.Left) ToggleTop();
        };
        FillProfiles();
        UpdateMenuLabels();
    }

    // claude-config's profiles: one JSON file each, the active one named in
    // .active. Both read over the same \\wsl$ path as the snapshots.
    static string[] ProfileNames() {
        try {
            if (profilesDir.Length == 0 || !Directory.Exists(profilesDir)) return new string[0];
            string[] files = Directory.GetFiles(profilesDir, "*.json");
            var names = new List<string>();
            foreach (string f in files) names.Add(System.IO.Path.GetFileNameWithoutExtension(f));
            names.Sort(StringComparer.OrdinalIgnoreCase);
            return names.ToArray();
        } catch { return new string[0]; }
    }

    static string ActiveProfile() {
        try {
            string f = System.IO.Path.Combine(profilesDir, ".active");
            return profilesDir.Length > 0 && File.Exists(f) ? File.ReadAllText(f).Trim() : "";
        } catch { return ""; }
    }

    // Whether the active profile routes Claude Code through Bedrock. null when
    // there is no claude-config to ask, and the tray has to guess.
    static bool? ActiveIsBedrock() {
        string name = ActiveProfile();
        if (name.Length == 0) return null;
        try {
            string f = System.IO.Path.Combine(profilesDir, name + ".json");
            var d = (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(File.ReadAllText(f));
            var env = d.ContainsKey("env") ? d["env"] as Dictionary<string, object> : null;
            return env != null && env.ContainsKey("CLAUDE_CODE_USE_BEDROCK")
                && env["CLAUDE_CODE_USE_BEDROCK"] != null
                && env["CLAUDE_CODE_USE_BEDROCK"].ToString() == "1";
        } catch { return null; }
    }

    static void FillProfiles() {
        string[] names = profileCmd.Length > 0 ? ProfileNames() : new string[0];
        miProfile.Visible = names.Length > 0;
        miProfile.DropDownItems.Clear();
        string active = ActiveProfile();
        foreach (string n in names) {
            string name = n;
            var item = new ToolStripMenuItem(name);
            item.Checked = name == active;
            item.Click += delegate { SwitchProfile(name); };
            miProfile.DropDownItems.Add(item);
        }
    }

    static void SwitchProfile(string name) {
        if (name == ActiveProfile()) return;
        RunInWsl(Quote(profileCmd) + " " + Quote(name), delegate(int code) {
            try {
                if (code == 0)
                    tray.ShowBalloonTip(5000, "ccmon", "Switched to " + name
                        + ". Applies to Claude Code sessions started from now on.", ToolTipIcon.Info);
                else
                    tray.ShowBalloonTip(5000, "ccmon", "claude-config " + name
                        + " failed (exit " + code + ").", ToolTipIcon.Warning);
            } catch { }
            Refresh();
        });
    }

    static string Quote(string s) { return "'" + s.Replace("'", "'\\''") + "'"; }

    // wsl.exe with no console window. onExit, when given, fires on completion.
    static void RunInWsl(string command, Action<int> onExit) {
        if (distro.Length == 0) return;
        var psi = new ProcessStartInfo("wsl.exe", "-d " + distro + " -- bash -lc " + Quote(command));
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.CreateNoWindow = true;
        psi.UseShellExecute = false;
        try {
            var proc = new Process { StartInfo = psi, EnableRaisingEvents = onExit != null };
            if (onExit != null) {
                proc.Exited += delegate {
                    int code = proc.ExitCode;
                    try { main.Form.BeginInvoke((MethodInvoker)delegate { onExit(code); }); } catch { }
                };
            }
            proc.Start();
        } catch { }
    }

    static Icon MakeIcon(string tone) {
        using (var bmp = new Bitmap(16, 16))
        using (var g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using (var b = new SolidBrush(ToneColor(tone)))
                g.FillEllipse(b, 2, 2, 12, 12);
            IntPtr h = bmp.GetHicon();
            // GetHicon leaks unless the previous handle is destroyed explicitly.
            if (trayHandle != IntPtr.Zero) Native.DestroyIcon(trayHandle);
            trayHandle = h;
            return Icon.FromHandle(h);
        }
    }

    // The worst-pacing bar on a panel. Ranked by tone rather than by
    // percentage, so a mid-week 60% on the weekly quota does not outrank a
    // session that is genuinely being overspent. A block outranks everything:
    // it is the one state in which nothing works.
    static string WorstTone(Reading r) {
        if (r == null || r.Stale) return "muted";
        if (r.Alert.Length > 0) return "crit";
        string tone = "muted";
        foreach (Row row in r.Rows) {
            string t = Pace.Of(row.Util, row.ResetsAt, row.WindowSec).Tone;
            if (ToneRank(t) > ToneRank(tone)) tone = t;
        }
        return tone;
    }

    // One dot, and it speaks for the account Claude Code is using right now:
    // the Bedrock panel when the active profile is a Bedrock one, the
    // subscription otherwise. Without claude-config to ask, whichever panel
    // has live data, the subscription first.
    static void UpdateTray() {
        Reading sub = main.Data;
        Reading bed = bedrock != null ? bedrock.Data : null;
        bool? onBedrock = ActiveIsBedrock();
        bool useBedrock = bed != null && (onBedrock == true
            || (onBedrock == null && (sub == null || sub.Stale) && !bed.Stale));
        Reading r = useBedrock ? bed : sub;

        tray.Icon = MakeIcon(WorstTone(r));
        string text = r == null || r.Stale ? "ccmon - no data" : "ccmon  " + r.Summary;
        if (r != null && r.Alert.Length > 0) text += "  " + r.Alert;
        tray.Text = text.Length > 63 ? text.Substring(0, 63) : text;   // the limit NotifyIcon enforces
    }

    static void HookDrag(PanelHost p) {
        DesktopForm form = p.Form;
        form.MouseDown += delegate(object s, MouseEventArgs e) {
            if (e.Button == MouseButtons.Left) { p.Dragging = true; p.DragOrigin = Cursor.Position; }
        };
        form.MouseUp += delegate {
            if (p.Dragging) {
                p.Dragging = false;
                // A drag can also end off-screen, on any number of monitors.
                // It survives until the desktop next changes shape.
                form.Location = ClampInto(Native.WorkAreaFor(form.Handle), form.Location, p.Height);
            }
        };
        form.MouseMove += delegate {
            if (!p.Dragging) return;
            Point now = Cursor.Position;
            form.Location = new Point(form.Location.X + now.X - p.DragOrigin.X,
                                      form.Location.Y + now.Y - p.DragOrigin.Y);
            p.DragOrigin = now;
        };
    }
}
