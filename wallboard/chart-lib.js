/* ccmon chart library.
 *
 * One source of truth for how a usage line is drawn. bin/chart.sh inlines this
 * file so its output stays self-contained (and pasteable into a Confluence HTML
 * macro); wallboard/index.html loads it normally.
 *
 * The caller supplies colours via CSS custom properties, so the palette lives in
 * each page's stylesheet - it is validated for CVD separation and contrast in
 * both light and dark, so change it only with the validator to hand.
 */
const CCMON = (function () {
  // A laptop that was asleep leaves a hole. Drawing through it would invent
  // data, so any gap longer than 30 minutes breaks the line into a new segment.
  const GAP = 1800;

  const fmtDay = t => new Date(t * 1000)
    .toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  const fmtFull = t => new Date(t * 1000)
    .toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });

  function segments(pts) {
    const out = []; let cur = [];
    for (const p of pts) {
      if (p.v == null) { if (cur.length) { out.push(cur); cur = []; } continue; }
      if (cur.length && p.t - cur[cur.length - 1].t > GAP) { out.push(cur); cur = []; }
      cur.push(p);
    }
    if (cur.length) out.push(cur);
    return out;
  }

  // A complete phrase for when a window rolls over. Sub-minute counts down in
  // seconds rather than collapsing to a useless "now", and once the reset time
  // has passed - which it can, between the rollover and the next poll - it
  // states the time it happened instead of pretending something is imminent.
  function resetPhrase(resetsAtSec, nowSec) {
    const now = nowSec || Math.floor(Date.now() / 1000);
    const d = resetsAtSec - now;
    if (d <= 0) {
      return 'reset at ' + new Date(resetsAtSec * 1000)
        .toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', hour12: false });
    }
    if (d >= 86400) return `resets in ${Math.floor(d / 86400)}d ${Math.floor(d % 86400 / 3600)}h`;
    if (d >= 3600)  return `resets in ${Math.floor(d / 3600)}h ${Math.floor(d % 3600 / 60)}m`;
    if (d >= 60)    return `resets in ${Math.floor(d / 60)}m`;
    return `resets in ${d}s`;
  }

  // The absolute reset time, with a weekday once it is not today. The widget
  // stays with the duration alone; a wallboard has room for both, and "Sat
  // 07:00" answers a different question than "in 3d 15h".
  function resetAt(sec) {
    const d = new Date(sec * 1000);
    const t = d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', hour12: false });
    if (d.toDateString() === new Date().toDateString()) return t;
    const within = sec - Math.floor(Date.now() / 1000) < 7 * 86400;
    const day = d.toLocaleDateString(undefined,
      within ? { weekday: 'short' } : { day: 'numeric', month: 'short' });
    return `${day} ${t}`;
  }

  function draw(host, tipEl, series, rows, opts) {
    const o = Object.assign({ W: 920, H: 210, ml: 34, mr: 96, mt: 10, mb: 24, label: true }, opts || {});
    const { W, H, ml, mr, mt, mb } = o;
    const iw = W - ml - mr, ih = H - mt - mb;

    const ts = rows.map(d => d.t);
    const t0 = Math.min(...ts), t1 = Math.max(...ts);
    const x = t => ml + (t1 === t0 ? iw / 2 : (t - t0) / (t1 - t0) * iw);
    const y = v => mt + ih - (Math.max(0, Math.min(100, v)) / 100) * ih;

    let s = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Usage over time">`;
    for (const g of [0, 25, 50, 75, 100]) {
      s += `<line class="gl" x1="${ml}" x2="${W - mr}" y1="${y(g)}" y2="${y(g)}"/>`;
      s += `<text class="ax" x="${ml - 6}" y="${y(g) + 3.5}" text-anchor="end">${g}</text>`;
    }
    const step = (t1 - t0) / 4;
    for (let i = 0; i <= 4; i++) {
      const t = t0 + step * i;
      s += `<text class="ax" x="${x(t)}" y="${H - 6}" text-anchor="${i === 0 ? 'start' : i === 4 ? 'end' : 'middle'}">${fmtDay(t)}</text>`;
    }

    const placed = [];
    for (const se of series) {
      for (const seg of segments(se.pts)) {
        if (seg.length === 1) {
          s += `<circle cx="${x(seg[0].t)}" cy="${y(seg[0].v)}" r="2.5" fill="${se.color}"/>`;
        } else {
          s += `<path class="ln" stroke="${se.color}" d="${seg.map((p, i) => (i ? 'L' : 'M') + x(p.t).toFixed(1) + ' ' + y(p.v).toFixed(1)).join(' ')}"/>`;
        }
      }
      // Direct label on the last point - identity never rests on colour alone.
      const last = se.pts.filter(p => p.v != null).pop();
      if (last && o.label) {
        let ly = y(last.v) + 3.5;
        // Nudge apart when two series finish at nearly the same value.
        while (placed.some(v => Math.abs(v - ly) < 13)) ly += 13;
        placed.push(ly);
        s += `<text class="ax" x="${W - mr + 8}" y="${ly}" fill="${se.color}">${se.label} ${Math.round(last.v)}%</text>`;
      }
    }

    if (tipEl) {
      s += `<line class="cross" x1="0" x2="0" y1="${mt}" y2="${mt + ih}" style="opacity:0"/>`;
      s += `<rect x="${ml}" y="${mt}" width="${iw}" height="${ih}" fill="transparent" class="hit"/>`;
    }
    s += '</svg>';
    host.innerHTML = s;
    if (!tipEl) return;

    const svg = host.querySelector('svg');
    const cx = host.querySelector('.cross');
    host.querySelector('.hit').addEventListener('pointermove', e => {
      const r = svg.getBoundingClientRect();
      const t = t0 + ((e.clientX - r.left) / r.width * W - ml) / iw * (t1 - t0);
      let best = null;
      for (const d of rows) if (!best || Math.abs(d.t - t) < Math.abs(best.t - t)) best = d;
      if (!best) return;
      cx.setAttribute('x1', x(best.t)); cx.setAttribute('x2', x(best.t));
      cx.style.opacity = 1;
      tipEl.innerHTML = `<b>${fmtFull(best.t)}</b><br>` + series.map(se => {
        const p = se.pts.find(p => p.t === best.t);
        return p && p.v != null
          ? `<i class="sw" style="display:inline-block;background:${se.color}"></i> ${se.label} ${Math.round(p.v)}%`
          : '';
      }).filter(Boolean).join('<br>');
      tipEl.style.opacity = 1;
      tipEl.style.left = Math.min(e.offsetX + 14, host.clientWidth - 150) + 'px';
      tipEl.style.top = (e.offsetY - 10) + 'px';
    });
    host.addEventListener('pointerleave', () => { cx.style.opacity = 0; tipEl.style.opacity = 0; });
  }

  // Pace: the point of the whole project. Not "how much have I used" but
  // "should I speed up or slow down to finish the window at TARGET".
  //
  //   e          how far through the window we are, 0..1
  //   paceNow    where usage would be if spent evenly to TARGET
  //   rateNow    average burn so far, in % of the window's quota per window
  //   rateNeeded burn required over what remains, same units
  //   factor     rateNeeded / rateNow - multiply your current rate by this
  //
  // The factor explodes near both ends of a window (divide by a tiny elapsed or
  // a tiny remaining), so callers get a `verdict` that is capped and readable
  // rather than a number like "26x".
  const TARGET = 95;

  function pace(utilisation, resetsAtSec, windowSec, nowSec) {
    const now = nowSec || Math.floor(Date.now() / 1000);
    const remaining = Math.max(0, resetsAtSec - now);
    const e = Math.min(1, Math.max(0, (windowSec - remaining) / windowSec));
    const u = utilisation == null ? null : Number(utilisation);

    const out = {
      remaining, elapsedFraction: e,
      paceNow: TARGET * e,
      headroom: u == null ? null : TARGET - u,
      rateNow: null, rateNeeded: null, factor: null,
      verdict: 'no data', tone: 'muted',
      // What you may still spend per hour (5h window) or per day (7d window).
      perHour: null, perDay: null
    };
    if (u == null) return out;

    out.perHour = remaining > 0 ? out.headroom / (remaining / 3600) : null;
    out.perDay  = remaining > 0 ? out.headroom / (remaining / 86400) : null;

    if (u >= TARGET)        { out.verdict = 'over budget'; out.tone = 'crit'; return out; }
    if (remaining <= 0)     { out.verdict = 'window closed'; return out; }
    if (e < 0.05)           { out.verdict = 'just reset'; return out; }

    out.rateNow = u / e;
    out.rateNeeded = out.headroom / Math.max(1e-6, 1 - e);
    out.factor = out.rateNow > 0 ? out.rateNeeded / out.rateNow : Infinity;

    const f = out.factor;
    if (!isFinite(f) || f >= 3) { out.verdict = 'burn freely';                 out.tone = 'good'; }
    else if (f > 1.15)          { out.verdict = 'faster ' + f.toFixed(1) + 'x'; out.tone = 'good'; }
    else if (f >= 0.85)         { out.verdict = 'on pace';                      out.tone = 'good'; }
    else if (f >= 0.5)          { out.verdict = 'ease off ' + f.toFixed(1) + 'x'; out.tone = 'warn'; }
    else                        { out.verdict = 'slow down ' + f.toFixed(1) + 'x'; out.tone = 'crit'; }
    return out;
  }

  const WINDOW_5H = 5 * 3600;
  const WINDOW_7D = 7 * 86400;

  // Which per-model weekly limit is present, if any (e.g. "Fable").
  function scopeKey(rows) {
    const withScope = rows.find(d => d.scoped && Object.keys(d.scoped).length);
    return withScope ? Object.keys(withScope.scoped)[0] : null;
  }

  return { GAP, TARGET, WINDOW_5H, WINDOW_7D,
           segments, fmtDay, fmtFull, resetPhrase, resetAt, draw, scopeKey, pace };
})();
