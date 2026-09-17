// ccmon desktop widget.
//
// Built as its own executable rather than hosted by powershell.exe, because
// Windows keys a tray icon's identity on (executable path + uID). Every
// PowerShell-hosted icon therefore collides with every other one - on this
// machine ours hashed to a stale Citrix installer entry - and can never get its
// own row in Settings > Taskbar, which is what "always show" needs.
//
// Reads only the snapshot the WSL poller writes. No credentials, no network.
//
// Build: csc /target:winexe /out:ccmon-widget.exe CcmonWidget.cs

using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
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

class Snapshot {
    public double? FiveHour, SevenDay;
    public bool Stale = true;
    public string Reason = "";
    public double FetchedAtMs;
    public long FiveHourResets, SevenDayResets;   // epoch seconds, 0 when absent

    public static Snapshot Read(string path) {
        var s = new Snapshot();
        try {
            string text = File.ReadAllText(path);
            var d = (System.Collections.Generic.Dictionary<string, object>)
                    new JavaScriptSerializer().DeserializeObject(text);
            s.FiveHour = Num(d, "five_hour");
            s.SevenDay = Num(d, "seven_day");
            s.Stale = d.ContainsKey("stale") && Convert.ToBoolean(d["stale"]);
            s.Reason = d.ContainsKey("reason") && d["reason"] != null ? d["reason"].ToString() : "";
            s.FetchedAtMs = Num(d, "fetchedAtMs") ?? Num(d, "checkedAtMs") ?? 0;
            s.FiveHourResets = Epoch(d, "five_hour_resets_at");
            s.SevenDayResets = Epoch(d, "seven_day_resets_at");
            return s;
        } catch { return null; }
    }
    static long Epoch(System.Collections.Generic.Dictionary<string, object> d, string k) {
        if (!d.ContainsKey(k) || d[k] == null) return 0;
        try { return DateTimeOffset.Parse(d[k].ToString()).ToUnixTimeSeconds(); } catch { return 0; }
    }
    static double? Num(System.Collections.Generic.Dictionary<string, object> d, string k) {
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

static class Program {
    const int W = 268, H = 190, PAD = 16, RADIUS = 16, MARGIN = 24;
    const int WINDOW_5H = 5 * 3600, WINDOW_7D = 7 * 86400;

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

    static string snapshotPath = "", wallboardUrl = "", distro = "", repo = "";
    static int refreshSeconds = 30;

    static DesktopForm form;
    static NotifyIcon tray;
    static Timer timer;
    static Snapshot data;
    static bool everRead = false;
    static bool onTop = false;      // false = pinned to the desktop
    static IntPtr trayHandle = IntPtr.Zero;

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
    // Home is the top-right corner of the work area, one margin in.
    static Point HomeIn(Rectangle wa) {
        return new Point(wa.Right - W - MARGIN, wa.Top + MARGIN);
    }

    // Pull a position wholly inside the work area, keeping the margin where
    // there is room for one. Max wraps Min so that on a screen too small for
    // both the left and top edges win: a widget hanging off the right is the
    // bug being fixed, and one hanging off the left would just be its mirror.
    static Point ClampInto(Rectangle wa, Point p) {
        return new Point(
            Math.Max(wa.Left + MARGIN, Math.Min(p.X, wa.Right  - W - MARGIN)),
            Math.Max(wa.Top  + MARGIN, Math.Min(p.Y, wa.Bottom - H - MARGIN)));
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
        form.Location = HomeIn(lastWorkArea);
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
        try { form.BeginInvoke((MethodInvoker)delegate { DisplayChanged(); }); } catch { }
    }

    // Ranked so the tray, which has one dot for two windows, can show the worse.
    static int ToneRank(string tone) {
        if (tone == "crit") return 3;
        if (tone == "warn") return 2;
        if (tone == "good") return 1;
        return 0;               // muted: no reading, or a window too young to judge
    }

    [STAThread]
    static int Main(string[] args) {
        for (int i = 0; i < args.Length - 1; i++) {
            if (args[i] == "--snapshot")  snapshotPath  = args[i + 1];
            if (args[i] == "--wallboard") wallboardUrl  = args[i + 1];
            if (args[i] == "--distro")    distro        = args[i + 1];
            if (args[i] == "--repo")      repo          = args[i + 1];
            if (args[i] == "--refresh")   int.TryParse(args[i + 1], out refreshSeconds);
        }
        if (snapshotPath.Length == 0) {
            MessageBox.Show("Usage: ccmon-widget.exe --snapshot <path> "
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

        form = new DesktopForm();
        form.Text = "ccmon";
        form.FormBorderStyle = FormBorderStyle.None;
        form.StartPosition = FormStartPosition.Manual;
        form.ShowInTaskbar = false;
        form.TopMost = false;
        form.BackColor = cSurface;
        form.Opacity = 0.90;
        form.Size = new Size(W, H);
        lastWorkArea = Native.PrimaryWorkArea();
        form.Location = HomeIn(lastWorkArea);
        form.Region = new Region(RoundedPath(0, 0, W, H, RADIUS));
        form.Paint += Paint;
        HookDrag();

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
            Poll();
            form.Invalidate();
            UpdateTray();
            UpdateZOrder();
            // Belt and braces for the events above: a display change that
            // produced none, or produced them all before the desktop had
            // finished moving, is caught here within one refresh instead of
            // leaving the widget stranded until the next logon.
            if (Native.PrimaryWorkArea() != lastWorkArea) GoHome();
            if (everRead && timer.Interval != refreshSeconds * 1000)
                timer.Interval = refreshSeconds * 1000;
        };
        timer.Start();

        Poll();
        UpdateTray();
        form.Show();
        UpdateZOrder();
        Application.Run();
        return 0;
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

    static void Poll() {
        Snapshot s = Snapshot.Read(snapshotPath);
        if (s != null) { data = s; everRead = true; } else { data = null; }
    }

    static Brush ToneBrush(string tone) {
        if (tone == "good") return bGood;
        if (tone == "warn") return bWarn;
        if (tone == "crit") return bCrit;
        return bMuted;
    }

    static void Paint(object sender, PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

        using (GraphicsPath border = RoundedPath(0, 0, W - 1, H - 1, RADIUS))
            g.DrawPath(pBorder, border);

        bool stale = data == null || data.Stale;
        string[] labels = { "5h session", "7d all models" };
        double?[] values = { data == null ? null : data.FiveHour, data == null ? null : data.SevenDay };
        long[] resets = { data == null ? 0 : data.FiveHourResets, data == null ? 0 : data.SevenDayResets };
        int[] windows = { WINDOW_5H, WINDOW_7D };

        int y = PAD;
        for (int i = 0; i < 2; i++) {
            Pace pc = Pace.Of(stale ? null : values[i], resets[i], windows[i]);

            g.DrawString(labels[i], fLabel, bMuted, PAD, y);
            string txt = values[i] == null ? "--" : Math.Round(values[i].Value) + "%";
            SizeF sz = g.MeasureString(txt, fBig);
            g.DrawString(txt, fBig, stale ? bMuted : bText, W - PAD - sz.Width, y - 6);

            int barY = y + 30, barW = W - 2 * PAD;
            using (GraphicsPath t = RoundedPath(PAD, barY, barW, 6, 3))
                g.FillPath(bTrack, t);
            if (values[i] != null && values[i] > 0) {
                int fw = Math.Max(6, (int)(barW * Math.Min(values[i].Value, 100) / 100));
                using (GraphicsPath f = RoundedPath(PAD, barY, fw, 6, 3))
                    g.FillPath(ToneBrush(pc.Tone), f);   // stale already resolves to muted
            }
            // Where usage would be if the window were spent evenly to 95%. The
            // gap between this tick and the bar end is the whole point.
            if (!stale && pc.PaceNow > 0 && pc.PaceNow < 100) {
                int px = PAD + (int)(barW * pc.PaceNow / 100);
                g.FillRectangle(bText, px, barY - 3, 2, 12);
            }

            string when = resets[i] > 0 ? Pace.Phrase(resets[i]) : "";
            g.DrawString(when, fSmall, bMuted, PAD, barY + 12);
            if (!stale) {
                SizeF vs = g.MeasureString(pc.Verdict, fSmall);
                g.DrawString(pc.Verdict, fSmall, ToneBrush(pc.Tone), W - PAD - vs.Width, barY + 12);
            }
            y += 74;
        }

        string foot;
        if (!everRead)          foot = "waiting for WSL...";
        else if (data == null)  foot = "snapshot unreadable";
        else if (data.Stale)    foot = "stale - " + data.Reason;
        else {
            double age = (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - data.FetchedAtMs) / 1000.0;
            foot = age < 90 ? "updated " + (int)age + "s ago" : "updated " + (int)(age / 60) + "m ago";
        }
        g.DrawString(foot, fSmall, bMuted, PAD, H - PAD - 6);
    }

    // Other windows reorder constantly, so re-sink every tick unless the tray
    // icon has deliberately lifted us.
    static void UpdateZOrder() {
        if (onTop) {
            if (!form.TopMost) form.TopMost = true;
            Native.Lift(form.Handle);
        } else {
            if (form.TopMost) { form.TopMost = false; Native.Drop(form.Handle); }
            Native.Sink(form.Handle);
        }
    }

    // Left-clicking the tray toggles between the desktop and the front, and
    // shows the widget again if it was hidden - otherwise the click would look
    // like it did nothing.
    static void ToggleTop() {
        onTop = !onTop;
        if (!form.Visible) { form.Show(); miHide.Text = "Hide widget"; }
        UpdateZOrder();
        UpdateMenuLabels();
    }

    static void ToggleHidden() {
        if (form.Visible) form.Hide();
        else { form.Show(); UpdateZOrder(); }
        UpdateMenuLabels();
    }

    static void UpdateMenuLabels() {
        miTop.Text = onTop ? "Send to desktop" : "Bring to front";
        miHide.Text = form.Visible ? "Hide widget" : "Show widget";
    }

    static ToolStripMenuItem miHide, miTop, miUpdate;

    static void BuildTray() {
        var menu = new ContextMenuStrip();
        miTop = new ToolStripMenuItem("Bring to front");
        var miBoard = new ToolStripMenuItem("Open wallboard");
        var miRefresh = new ToolStripMenuItem("Refresh now");
        miUpdate = new ToolStripMenuItem("Update ccmon");
        miHide = new ToolStripMenuItem("Hide widget");
        var miExit = new ToolStripMenuItem("Exit");

        miTop.Click += delegate { ToggleTop(); };
        miBoard.Click += delegate {
            if (wallboardUrl.Length > 0) Process.Start(wallboardUrl);
            else tray.ShowBalloonTip(4000, "ccmon", "No wallboard URL configured. Run ./ccmon.", ToolTipIcon.Info);
        };
        miRefresh.Click += delegate {
            RunInWsl("$HOME/.claude/ccmon/usage-poll.sh", null);
            Poll(); form.Invalidate(); UpdateTray();
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

        menu.Items.AddRange(new ToolStripItem[] {
            miTop, miHide, new ToolStripSeparator(),
            miBoard, miRefresh, miUpdate, new ToolStripSeparator(), miExit });

        tray = new NotifyIcon();
        tray.ContextMenuStrip = menu;
        tray.Text = "ccmon";
        tray.Icon = MakeIcon("muted");   // until the first snapshot lands
        tray.Visible = true;
        tray.MouseClick += delegate(object s, MouseEventArgs e) {
            if (e.Button == MouseButtons.Left) ToggleTop();
        };
        UpdateMenuLabels();
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
                    try { form.BeginInvoke((MethodInvoker)delegate { onExit(code); }); } catch { }
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

    static void UpdateTray() {
        bool stale = data == null || data.Stale;
        // One dot, two windows: whichever is pacing worse gets to speak. Ranked
        // by tone rather than by percentage, so a mid-week 60% on the weekly
        // quota no longer outranks a session that is genuinely being overspent.
        string tone = "muted";
        if (!stale) {
            string t5 = Pace.Of(data.FiveHour, data.FiveHourResets, WINDOW_5H).Tone;
            string t7 = Pace.Of(data.SevenDay, data.SevenDayResets, WINDOW_7D).Tone;
            tone = ToneRank(t7) > ToneRank(t5) ? t7 : t5;
        }
        tray.Icon = MakeIcon(tone);
        tray.Text = stale
            ? "ccmon - no data"
            : "ccmon  5h " + Math.Round(data.FiveHour ?? 0) + "%  7d " + Math.Round(data.SevenDay ?? 0) + "%";
    }

    static bool dragging; static Point dragOrigin;
    static void HookDrag() {
        form.MouseDown += delegate(object s, MouseEventArgs e) {
            if (e.Button == MouseButtons.Left) { dragging = true; dragOrigin = Cursor.Position; }
        };
        form.MouseUp += delegate {
            if (dragging) {
                dragging = false;
                // A drag can also end off-screen, on any number of monitors.
                // It survives until the desktop next changes shape.
                form.Location = ClampInto(Native.WorkAreaFor(form.Handle), form.Location);
            }
        };
        form.MouseMove += delegate {
            if (!dragging) return;
            Point now = Cursor.Position;
            form.Location = new Point(form.Location.X + now.X - dragOrigin.X,
                                      form.Location.Y + now.Y - dragOrigin.Y);
            dragOrigin = now;
        };
    }
}
