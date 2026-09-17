# Findings

Reference material, not instructions — `./ccmon` owns everything you have to *do*.
This file records what was expensive to work out, so it does not have to be
worked out twice.

## The usage endpoint

Claude Code polls `https://api.anthropic.com/api/oauth/usage`, using the OAuth
access token it stores in `~/.claude/.credentials.json`:

```
Authorization: Bearer <claudeAiOauth.accessToken>
anthropic-beta: oauth-2025-04-20
```

Response shape (fields ccmon uses):

```json
{
  "five_hour":  { "utilization": 21.0, "resets_at": "2026-09-14T11:40:00Z", "locked_reason": null },
  "seven_day":  { "utilization": 23.0, "resets_at": "2026-09-19T05:00:00Z" },
  "limits": [
    { "kind": "session",       "group": "session", "percent": 21, "severity": "normal", "scope": null },
    { "kind": "weekly_all",    "group": "weekly",  "percent": 23, "severity": "normal", "scope": null },
    { "kind": "weekly_scoped", "group": "weekly",  "percent": 16, "severity": "normal",
      "scope": { "model": { "display_name": "Fable" } } }
  ]
}
```

**It returns the current value only. There is no history.** That single fact is
the reason this project exists: whatever is not recorded as it happens is gone.

Other windows (`seven_day_opus`, `seven_day_sonnet`, `seven_day_cowork`, …) exist
in the response but are `null` on a Team plan.

### Rate limiting

Authenticated responses carry **no** rate-limit headers — no `x-ratelimit-*`, no
`retry-after`, no `cache-control`. The call consumes no token quota, and the
community tray apps poll it every 180 s. Polling every 5 minutes from several
machines is not a concern, so ccmon deliberately has **no** coordination layer
between machines: it would add a single point of failure for no benefit.

One caveat found the hard way: *unauthenticated* requests to that path are
throttled per source IP and will return `429`. Behind a shared corporate proxy
that says nothing about your own access, which is why `ccmon`'s reachability
probe hits `https://api.anthropic.com/` instead.

### Token lifetime

The access token lasts roughly 7 hours; the refresh token about 20 days.

**ccmon never refreshes the token.** Refreshing would rotate the refresh token
and could log Claude Code out from under you. Instead the poller reads the
credentials strictly read-only and, once the token has expired, writes
`{"ok": false, "stale": true, "reason": "token-expired"}` while preserving the
last known percentages. Using Claude Code renews the token; the poller recovers
on its own. In practice this means continuous coverage during a working day and
a gap overnight.

## Why the numbers are the same on every machine

The quota is per account (`subscriptionType: "team"`), not per machine. Several
machines therefore report *identical* numbers — there is nothing to aggregate.
Each machine still writes its own history file, purely so that two laptops
syncing at nearly the same instant cannot conflict over one file. The wallboard
merges them again and takes the newest reading for its headline figures.

A pleasant side effect: whichever machine happens to be awake extends the
timeline, so the history has fewer gaps than any single laptop would produce.

## The status line payload

Claude Code documents its own status line stdin schema inside the binary. The
fields ccmon's status line reads:

```
model.display_name
context_window.used_percentage      // null until the first API response
rate_limits.five_hour.used_percentage   // subscribers only, after first response
rate_limits.seven_day.used_percentage
rate_limits.spend_limit.used_percentage // only behind a gateway with a spend limit
```

`rate_limits` exposes only `five_hour`, `seven_day` and `spend_limit` — the
per-model `weekly_scoped` limit that `/usage` shows is **not** in the status
line payload. ccmon's own snapshot does carry it, because it comes straight
from the API.

## Local files

| Path | What |
|---|---|
| `~/.claude/ccmon/usage-poll.sh` | the poller (installed by `./ccmon`) |
| `~/.claude/ccmon/creds.sh` | where the credentials live, shared with `./ccmon` |
| `~/.claude/ccmon/statusline.sh` | the status line script |
| `~/.claude/usage-snapshot.json` | the current reading, and what the widget displays |
| `~/.claude/ccmon/{poll,sync}.log` | macOS only: what the agents printed, empty when well |
| `~/.claude/ccmon/CcmonWidget.app` | macOS only: the widget, built in place |
| `~/Library/LaunchAgents/com.ccmon.*` | macOS only: the poller, the sync job, the widget |

The snapshot is also readable from Windows at
`\\wsl.localhost\<distro>\home\<user>\.claude\usage-snapshot.json`, which is how
the widget gets at it without any credentials of its own.

Claude Code additionally caches usage in `~/.claude.json` under
`cachedUsageUtilization`, but only refreshes it while a session is active — which
is precisely why ccmon polls on a timer instead of reading that file.

## macOS keeps the credentials in the Keychain

There is no `~/.claude/.credentials.json` on macOS. Claude Code stores the same
JSON as the secret of a login-Keychain generic password:

| | |
|---|---|
| service | `Claude Code-credentials` |
| account | the OS user |
| read it | `security find-generic-password -s "Claude Code-credentials" -a "$USER" -w` |

Four things about that, each of which the port depends on:

- **Attributes are free, the secret is not.** The same command *without* `-w`
  returns the item's full attributes and never prompts, which is how
  `creds_source` can check whether an item exists without putting a dialog on
  screen. Exit code **44** is the Keychain's "no such item".
- **"Always Allow" survives token refresh.** The ACL is a property of the item,
  so recreating the item would reset it. Claude Code does not recreate it: on
  this machine the item's creation date is four months older than its
  modification date, which means `SecItemUpdate` in place. One grant holds.
- **The ACL is keyed on the executable, not the caller.** Granting it adds
  `/usr/bin/security` — Apple-signed, stable — to the item's trusted list, so a
  read from your shell and a read from launchd → bash → security are the same
  decision. That is what makes a check during `./ccmon` a valid gate for what
  the scheduled agent will be able to do later. It also means the grant is not
  narrow: anything running as you can then read the token without a prompt.
- **`gui/<uid>`, never `user/<uid>`.** Only the GUI domain has an Aqua session
  and therefore an unlocked login keychain. An agent bootstrapped from an ssh
  session with nobody at the screen cannot read the credentials at all.

The item is keyed on the OS user rather than on `CLAUDE_CONFIG_DIR`, so one
login per user is the rule on macOS — pointing `CLAUDE_CONFIG_DIR` at an empty
directory does not sandbox the credentials, it just falls through to the real
ones. Claude Code behaves the same way, so this is the behaviour to match.

**A trap with no error message:** a launchd agent carries no TCC consent of its
own. If `CLAUDE_CONFIG_DIR` ever points inside `~/Documents`, `~/Desktop`,
`~/Downloads` or `/Volumes`, the poller reads fine when you run it from Terminal
and is denied when the agent runs it — silently, with a clean exit code. Stage 2
refuses up front rather than leaving that to be discovered.

## systemd and launchd, side by side

| | systemd | launchd |
|---|---|---|
| unit of work | `.service` + `.timer` | one `.plist` |
| identity | filename | the `Label` inside the file |
| reload after an edit | `daemon-reload` | none — `bootout` then `bootstrap` |
| every 5 minutes | `OnUnitActiveSec=5min` | `StartInterval 300` |
| catch up after downtime | `Persistent=true` | inherent to `StartInterval` |
| survives logout | `loginctl enable-linger` | no counterpart, by design |
| next run | `systemctl list-timers` | **nothing** — only `runs` and `last exit code` |

Three that cost time to learn:

- **launchd expands nothing in a plist.** Not `~`, not `$HOME`, not even in
  `StandardOutPath`. Rendering a per-user copy would cost the byte comparison
  that makes `./ccmon` idempotent, so the path is handed to `bash -c` instead.
- **`load -w` is a trap.** It writes to a per-user *disabled* list as a side
  effect, and a label in that list will accept a `bootstrap` and then never run.
  Use `bootstrap`/`bootout`, and never `disable` on the way out.
- **`ProcessType Background` would be wrong here.** It subjects the job to Low
  Power Mode deferral, and the resulting gap in the samples would look exactly
  like a machine that was switched off — which is the one thing this project
  exists to tell apart.

There is no next-run time to report, so `./ccmon` reports how the last run ended
instead, and proves the arrangement by kicking the job once and reading the
snapshot it writes. On a platform where the scheduler's copy of the poller has a
different credential story from yours, that proof is worth more than a next-run
time would have been.

## The access token is visible in `ps`

`usage-poll.sh` passes the token to curl as `-H "Authorization: Bearer $token"`,
which puts it in the process arguments, where anything running as you can read
it — on every platform, and long before any of the Keychain work above.
`curl --config -` with the header on stdin would fix it. Recorded here rather
than quietly noticed twice.

## Publishing: GitHub Pages

ccmon uses **deploy-from-branch on the orphan `data` branch**: no workflow file,
no Actions minutes, and Pages rebuilds on the pushes `history-sync.sh` already
makes — including the force-push that compaction performs.

Two things that will bite if forgotten:

- **`.nojekyll` is required.** Without it Pages runs Jekyll, which hides files
  under `data/` and the wallboard 404s on its own manifest.
- **Site visibility follows repo visibility.** A public repo gets a public site
  at `<org>.github.io/<repo>`. A private repo on Enterprise Cloud gets a
  randomised `*.pages.github.io` hostname *and* requires a signed-in GitHub
  session to open — fine at a desk, wrong for an unattended screen, which is why
  `ccmon serve` exists.

Pages' CDN caches for roughly 10 minutes, so the wallboard cache-busts its
fetches with a timestamp and the sync runs every 15 minutes. Going faster than
that buys nothing.

### Why the manifest exists

The append-only rows store only `t`, the percentages and `ok` — deliberately
small. The wallboard also wants reset countdowns, so each machine writes
`data/<id>.latest.json` (its own file, so no write conflicts) and the sync
regenerates `data/index.json` from all of them. That regeneration is
deterministic given the same inputs, so two machines rebuilding it converge
instead of fighting.

## Why the Windows widget is a compiled executable

Windows identifies a tray icon by **(executable path + uID)**, and records it
under `HKCU\Control Panel\NotifyIconSettings` — that registry key is what
Settings > Taskbar > "Other system tray icons" lists, and `IsPromoted=1` is what
its toggle writes.

A WinForms `NotifyIcon` hosted by `powershell.exe` therefore has no identity of
its own. On this machine the widget's icon hashed onto an existing entry for
`powershell.exe` with `uID=1` — left over from a Citrix installer — so it could
never appear as its own row, and "always show this icon" was unreachable.

Building the widget as `ccmon-widget.exe` gives it a distinct `ExecutablePath`,
its own registry entry, and therefore a working toggle. `csc.exe` ships with the
.NET Framework on every Windows box, so `./ccmon` can build it with nothing
installed.

Two related gotchas:

- Windows only creates the registry entry **after the icon has run once**, so
  pinning is a second-pass operation.
- Windows PowerShell 5.1 decodes `.ps1` as ANSI unless the file has a BOM. A
  single em-dash in the old script turned into a cascading parse error. Keeping
  Windows-side sources ASCII-only avoids the whole class of problem.

The macOS widget is compiled for a plainer reason - AppKit is not scriptable
from the shell - but it arrives at the same shape: `swiftc` ships with the
Command Line Tools, so `./ccmon` builds it in place and the repository never
distributes a binary. Three things there are worth knowing:

- **The bundle is for stability, not for function.** A bare executable can
  create a status item, but `LSUIElement` in an `Info.plist` makes the process
  accessory before any of our code runs, so there is no Dock-icon flicker, and
  `codesign` signs bundles rather than loose executables.
- **Re-signing after every build is mandatory on Apple silicon.** Gatekeeper
  never sees this app — it triggers on the quarantine xattr, which a file
  `swiftc` writes does not carry — but replacing the executable inside a signed
  bundle leaves `CodeResources` describing a file that is gone, and the app is
  then killed at launch with a message that blames nothing.
- **`KeepAlive` must be `{SuccessfulExit: false}`, not `true`.** With `true`,
  choosing Quit relaunches the widget within a second and the menu item looks
  broken. The dictionary form lets a clean exit stay dead until the next login
  while still restarting a crash, which is what the Windows Startup shortcut
  amounts to. It is also why a rebuild stops the widget with `launchctl
  bootout` and not `pkill`: a signalled exit is an unsuccessful one, so `pkill`
  would hand the job straight back to launchd in the middle of the build.

There is no macOS level that is both under the desktop icons and clickable, and
the window list says why:

```
Wallpaper                 -2147483625
Dock wallpaper            -2147483624
kCGDesktopWindowLevel     -2147483623   <- the widget, by default
Finder's desktop window   -2147483603   full-screen, draws the icons, takes the clicks
kCGDesktopIconWindowLevel -2147483603   same level; ordering breaks the tie
```

Finder's desktop window covers the whole screen, so anything below it never
sees a click — dragging a panel down there does nothing at all, silently. At
`kCGDesktopIconWindowLevel` the widget ties with that window and an
`orderFrontRegardless()` puts it in front, which buys direct dragging and costs
painting over the icons.

ccmon defaults to the quieter half of that trade and gets the movement back
through the menu: "Move widget" lifts the panel to the floating level, and the
end of the next drag drops it straight back. `--level icons` takes the other
half. This is the one thing in the port that could not be settled by reading,
and it did not survive contact with a real desktop — the first arrangement
overlaid the icons, which is not what a widget that calls itself part of the
desktop should do.

## Reading the wallpaper

`NSWorkspace.desktopImageURL(for:)` and `desktopImageOptions(for:)` need **no TCC
permission** - which is what makes an adaptive widget possible at all, since a
launchd agent has no consent of its own. Two things cost time:

**The layout has to be replicated, not approximated.** The options carry
`.imageScaling`, `.allowClipping` and `.fillColor`, and macOS letterboxes an
image whose aspect does not match the screen. On the machine this was written on,
a 4032x1908 photo on a 1920x1080 screen with clipping off is drawn at y=85.7,
height 908.6, with fill colour above and below - so **20% of the widget's area at
its home position is over fill colour rather than over the image**. A naive
proportional sample reads the wrong pixels and is confidently wrong.

**The wallpaper is resolved once into a small proxy**, screen-shaped, at one
pixel per 4 screen points. The fill colour goes down first and the image is drawn
into its computed rect, so the letterbox case needs no special handling anywhere
downstream, and sampling on every drag is a rect read rather than an image
decode. `CGImageSource` rather than `NSImage`: it decodes at reduced scale
instead of paying ~30MB for a phone photo, and a frame count of zero is a clean
way to recognise a video wallpaper it cannot open at all.

What cannot be done: a time-of-day `.heic` carries up to 16 frames and
WindowServer picks between them from the sun's position, which is not observable.
The widget picks by system appearance and charges a confidence penalty - a
guessed frame buys a little extra scrim. There is also no wallpaper-changed
notification, so the URL and its mtime are polled, every fourth tick.

### Contrast, and why the footer sets the price

Every element on the panel is measured against the same surface, so
`achieved/nominal` is identical for all of them - the element's own luminance
cancels. One number therefore describes what the wallpaper costs the whole
palette, and each requirement is a floor on it.

Two of them, not one. The slider's ratio is about the headline, but the muted
footer binds first: on a real wallpaper, targeting only the big number gives a
legible `70%` above an illegible `updated 45s ago`. The footer's requirement
tracks the slider rather than sitting at a fixed 3:1 - pinned, it binds below
about 7:1 and the lower half of the slider does nothing at all, which the
measurements showed before anyone had to notice it by eye.

Compositing is done on **gamma-encoded channels**, not on luminances. `lin()` is
convex, so a linear-light model is always optimistic for a light scrim over a
dark backdrop - the one case where being wrong means unreadable text.

Measured on one ordinary photo (mean luminance 0.41, sd 0.21):

| | dark palette | light palette |
|---|---|---|
| alpha at a 4.5:1 target | 0.75 | **0.26** |

The light palette costs a third of the ink, which is why polarity is chosen by
**which palette reaches the target with less alpha** rather than by a luminance
threshold. There is no constant to tune, and least-ink is the definition of low
profile.

One defect this surfaced, inherited rather than introduced: the light set's
`--good` `#1baf7a` is **2.74:1** on `#fcfcfb`, unreachable at any opacity. It is
used at headline size on the wallboard, where 3:1 for large text applies; the
widget draws the verdict at 10pt, where it does not. A halo - zero offset, 2.5pt
blur, opposite polarity - is what carries it, applied to any tone the palette
cannot hold on its own.

**Windows stays dark-only on purpose.** `desktopImageURL` has no Win32
counterpart worth the code, so the widgets agree per palette by Windows only ever
using the dark one.

## Pace, not level

The project's question is not "how much have I used" but "am I on track to use
almost all of it". For a window of length `D` that resets at `R`, with
utilisation `u`:

```
e          = (D - (R - now)) / D        how far through the window we are
paceNow    = 95 * e                     where usage would be if spent evenly
headroom   = 95 - u
rateNow    = u / e                      average burn so far
rateNeeded = headroom / (1 - e)         burn required over what remains
factor     = rateNeeded / rateNow       multiply your current rate by this
```

95 rather than 100 leaves a 5% margin.

`factor` explodes at both ends of a window - divide by a tiny `e` just after a
reset, or a tiny `1 - e` just before one - so it is never shown raw. Below 5%
elapsed it reads "just reset"; above 3x it reads "burn freely"; between those it
is shown to one decimal. The concrete figure (`%/h` for the 5-hour window,
`%/day` for the weekly one) is more actionable than the multiplier and does not
blow up, so both are displayed.

The maths lives in `pace()` in `wallboard/chart-lib.js` and is mirrored in
`class Pace` in `widget/CcmonWidget.cs` and `struct Pace` in
`widget/CcmonWidget.swift`. Three implementations is a real cost; sharing
JavaScript with two compiled widgets is a bigger one, and `bin/chart.sh` already
inlines the same library for the same reason.

Moving the verdict into the poller would delete two of the three and should
still be resisted: pace is a function of the clock as much as of usage, and each
widget recomputes it every few seconds precisely so the countdown and the pace
tick keep moving *between* polls. A verdict carried in the snapshot would be
five minutes stale at worst, and would make "resets in 3h 43m" a lie.

## No absolute figures exist

Worth stating plainly, because it looks like an omission: the usage endpoint
returns **percentages only**. `limit_dollars`, `used_dollars` and
`remaining_dollars` are null on a Team plan, and there is no token count
anywhere in the response. Bars and percentages are the most absolute view
available.

## Private Pages cannot be made public by request

Asking the API to publish a private repo's site:

```
PUT /repos/{owner}/{repo}/pages   public=true
→ 422 Public visibility is not supported for enterprise managed repository pages.
```

An enterprise can refuse this outright, so the randomised `*.pages.github.io`
hostname cannot always be traded for the tidy `<org>.github.io/<repo>` form —
that is only issued to public sites. If you need a clean, sign-in-free URL, the
repo itself has to be public. The randomised hostname is stable, but disabling
and re-enabling Pages mints a new one, so leave it alone.

## Why machines are identified by an opaque id

Each machine writes its own `data/<id>.jsonl`, and the id is random rather than
the hostname. The per-machine split is load-bearing — it is what lets several
machines sync to the same branch without conflicting over a shared file.

The *identity* is not. Every machine reports the same account-wide numbers,
whichever one is awake extends the same timeline, and "is this dashboard live?"
is already answerable from the manifest's `generated` and each sample's `t`. So
the only question a real hostname answered — which machine is still polling —
was not worth publishing, and the wallboard shows a freshness line instead of a
per-machine strip.

Note this is not anonymisation. Commit authorship still identifies whoever runs
it; the opaque id only keeps machine-naming conventions out of a public repo.
