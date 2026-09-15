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
Each machine still pushes its own series, labelled by `host`, purely so that two
laptops pushing at nearly the same instant cannot produce out-of-order or
duplicate samples for one series. Charts collapse them again with `max()`.

A pleasant side effect: whichever machine happens to be awake extends the
timeline, so the history has fewer gaps than any single laptop would produce.

## Why OTLP/JSON rather than Prometheus remote_write

Prometheus `remote_write` requires snappy-compressed protobuf, which a shell
script cannot produce. Grafana Cloud's OTLP gateway accepts OTLP/HTTP with
**JSON** encoding, documented as suitable for low-traffic cases — one sample
every 5 minutes qualifies comfortably. So the poller POSTs JSON with `curl` and
needs no agent, collector or extra daemon.

Endpoint: `https://otlp-gateway-prod-eu-west-2.grafana.net/otlp/v1/metrics`,
HTTP Basic with the instance ID as username and a Cloud Access Policy token
(scope `metrics:write`) as password.

### Put labels on data points, not on the resource

Mimir promotes only a handful of resource attributes to labels and files the
rest under `target_info`, where they are useless for querying these series. So
`account` and `host` are set as **data point** attributes; only `service.name`
is a resource attribute.

Metric names carry no `unit` field. The OTel→Prometheus translation appends a
unit suffix, and omitting the unit keeps the names exactly as written.

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
| `~/.claude/ccmon/statusline.sh` | the status line script |
| `~/.claude/ccmon/grafana-cloud.env` | the token, `0600`, **outside the repo by design** |
| `~/.claude/ccmon/last-push.txt` | timestamp, HTTP status and body of the last push |
| `~/.claude/usage-snapshot.json` | the current reading, and what the widget displays |

The snapshot is also readable from Windows at
`\\wsl.localhost\<distro>\home\<user>\.claude\usage-snapshot.json`, which is how
the widget gets at it without any credentials of its own.

Claude Code additionally caches usage in `~/.claude.json` under
`cachedUsageUtilization`, but only refreshes it while a session is active — which
is precisely why ccmon polls on a timer instead of reading that file.

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

## Why the widget is a compiled executable

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
`class Pace` in `widget/CcmonWidget.cs`. Two implementations is a cost; sharing
JavaScript with a compiled Windows widget is a bigger one.

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
the hostname. The per-machine split is load-bearing — it is what stops concurrent
pushes conflicting, and what stops Mimir rejecting out-of-order samples when two
machines push the same series at once.

The *identity* is not. Every machine reports the same account-wide numbers,
whichever one is awake extends the same timeline, and "is this dashboard live?"
is already answerable from the manifest's `generated` and each sample's `t`. So
the only question a real hostname answered — which machine is still polling —
was not worth publishing, and the wallboard shows a freshness line instead of a
per-machine strip.

Note this is not anonymisation. Commit authorship still identifies whoever runs
it; the opaque id only keeps machine-naming conventions out of a public repo.
