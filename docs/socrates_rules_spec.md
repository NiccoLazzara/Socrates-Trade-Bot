# Socrates Rules Specification v1.0
*Source-of-truth for the LPI Confluence Alert Engine*

Prepared: May 2026
For: Nicco Lazzara, LPI
Status: v1.0 — derived from transcripts 01–05 and the Socrates Investments Playbook
Purpose: Mechanical specification for the TradingView → n8n → Supabase → Telegram alert pipeline. Every rule here is traceable to a source file. Defaults proposed for the build are marked `[BUILD DEFAULT — TUNE LATER]`.

---

## 0. How to Read This Document

This spec converts Socrates' discretionary framework into mechanical alert conditions. Where his teaching is concrete (indicator names, session windows, asset focus), the rule is stated directly. Where his teaching is qualitative ("I need volume", "near a key level"), the spec proposes a starting threshold marked `[BUILD DEFAULT]` so we have something to code against — those values get tuned during the 30-day live signal validation phase, not invented at launch.

Source citations use the format `[file_name.txt]` inline.

Three things this spec deliberately does NOT do:
- Generate orders or position size — alerts only, no execution in v1
- Claim the 80% win rate from his marketing — that's unverified and irrelevant to building the system
- Encode his discretionary "magic sauce" pattern recognition — we encode the mechanical pieces and accept that some setups he takes will not fire as alerts. That's acceptable: we're building a high-precision filter, not a clone.

---

## 1. Complete Indicator Stack

All six indicators are free on TradingView. Minimum subscription: TradingView Pro+ (required for webhook alerts on multiple symbols and timeframes). `[02_indicator_breakdown.txt]`

| # | Indicator | Creator | TradingView Search | Role |
|---|-----------|---------|--------------------|------|
| 1 | Key Levels | Trading Wolf | `key levels` → first result | Auto-marks daily open, daily low, AVWAP, moving averages |
| 2 | Key Levels | Spaceman | `key levels` → second result | Alternative key levels (different visual style) — runs alongside #1 |
| 3 | Bull vs Bear | Arena (DGT) | `bull verse bear` → first result | Volume strength indicator — bull % vs bear % with flip detection |
| 4 | ICT Kill Zones | LuxAlgo | `ICT kill zones` → first result | Highlights Asian / London / NY session windows |
| 5 | Supply and Demand (Visible Range) | LuxAlgo | `supply and demand` → first result | Auto-plots supply/demand zones in the visible range |
| 6 | Order DOM | TradingView native | Built-in DOM panel | Live volume at each price level |

**Loadout order for clean charts:**
1. Both Key Levels indicators (background)
2. Supply and Demand Visible Range (boxes)
3. ICT Kill Zones (session shading)
4. Bull vs Bear (separate pane, bottom)
5. Order DOM (side panel)

His own confirmation: "Each one of these indicators are free. There's no reason to go sit there and pay money for indicators." `[02_indicator_breakdown.txt]`

**Note for the Pine Script build:** the alert engine does NOT replicate any of these indicators internally for the visual layer — those are for the trader's eyes. The engine computes confluence from a separate set of mechanical inputs (covered in §3 and §10). Indicators 1–6 are the trader's view of the same underlying logic.

---

## 2. Timeframe Hierarchy

Socrates uses a strict top-down hierarchy. The build must respect this — alerts trigger on entry timeframes, but only when higher-timeframe bias agrees.

| Layer | Timeframes | Purpose | Source |
|-------|-----------|---------|--------|
| Bias | Weekly, Daily | Macro trend direction; weekly / monthly levels | `[01]` |
| Setup | 4H, 1H | Identify zones, pivots, supply/demand on intraday | `[01, 02]` |
| Entry | 5min (primary), 1H (secondary) | Trigger candle / confirmation | `[02]` |
| Scalp | 1min, 5min | VIX/NQ divergence (Setup D only) | `[05]` |

Direct quote: "My entries on the smaller time frames are the 5 minute and 1 hour for my entries, and 4-hour, weekly, and daily for my charting." `[02_indicator_breakdown.txt]`

**Bias rule for the alert engine:**
- Daily up + 4H up → only long alerts fire
- Daily up + 4H down → only A+ countertrend alerts fire
- Daily down + 4H up → only A+ countertrend alerts fire
- Daily down + 4H down → only short alerts fire
- Daily ranging → both directions allowed, minimum grade A required

"Trend up/down" is mechanically defined as: close above/below the 20-period EMA on that timeframe AND higher-highs / lower-lows structure in the last 10 bars. `[BUILD DEFAULT — TUNE LATER]`

---

## 3. The Five Setup Types

Each setup is an independent alert template. The engine evaluates all five on every bar close of the relevant timeframe; multiple setups firing simultaneously increases the confluence grade (§9).

### Setup A — Key Level + Volume *(most common)*

**Trigger:** Price approaches and reacts at a Daily / Weekly / Monthly High, Low, or Open with volume confirmation from Bull vs Bear.

**Source:** `[00_INDEX.txt, 01_strategy_walkthrough_gold_nq.txt]`

Direct quote: "My favorite entry points: daily open, daily high, daily low" and "If the volume's there, it's going to move. If the volume's not there, it's not going to move." `[01]`

**Mechanical conditions (all must be true):**
- Current bar's high (for short) or low (for long) within X ticks of a marked level
  - `[BUILD DEFAULT: X = 5 ticks NQ, 3 ticks ES, 2 ticks GC]`
- Bar closes with a rejection wick of at least 40% of the bar's range pointing away from the level `[BUILD DEFAULT]`
- Bull vs Bear shows the corresponding side strengthening by ≥ 10 percentage points vs the prior 3-bar average `[BUILD DEFAULT]`
- Daily / 4H bias agrees with the trade direction OR confluence grade meets A+ threshold
- Time is within the primary trading window (§7)

**Levels considered "key" for this setup:**
- Prior Day High (PDH), Prior Day Low (PDL)
- Today's RTH Open
- Overnight High (ONH), Overnight Low (ONL)
- Weekly High, Weekly Low, Weekly Open
- Monthly High, Monthly Low, Monthly Open

**Entry timeframe:** 5min (primary), 1H (secondary for swing-leaning entries)

---

### Setup B — Supply / Demand Zone Bounce

**Trigger:** Price taps a fresh LuxAlgo Supply and Demand Visible Range zone, confirms rejection, fires alert on next bar close.

**Source:** `[01, 02]`

**Mechanical conditions:**
- Price wicks into a supply zone (for shorts) or demand zone (for longs) — bar high/low penetrates the zone boundary
- Bar closes back outside the zone
- Zone is "fresh" — not tagged in the prior N bars on the same timeframe `[BUILD DEFAULT: N = 30]`
- Volume confirmation per Bull vs Bear (same threshold as Setup A)
- Zone visible on 4H or higher (zones on lower TFs are noisier)
- Bias agreement or A+ confluence

**Zone definition for engine-side replication (since indicator output isn't reliably readable):**
Any consolidation range of ≥ 3 bars preceding an impulsive move of ≥ 2× ATR(14) creates a zone box from the consolidation's high to low. Zone remains active until tagged or invalidated (price closes through opposite side).

---

### Setup C — Pivot-to-Pivot

**Trigger:** Price approaches a structural pivot (previous price-action turning point on a higher timeframe) and reacts with volume.

**Source:** `[04_pivot_trading_part2.txt]`

**Critical definition:** Socrates uses "pivot" to mean *structural reversal points*, NOT floor-trader pivot calculations. Direct quote: "A pivot is previous areas on higher time frames where price either broke above or broke below or changed direction. Could be for a second, could be for a minute, but that's all I need." `[04]`

**Mechanical pivot detection:**
- Pivot High = bar whose high exceeds the N bars before AND N bars after on the source timeframe
- Pivot Low = bar whose low is less than the N bars before AND N bars after
- `[BUILD DEFAULT: N = 5 for 1H pivots, N = 3 for 4H pivots]`
- Only 4H and 1H pivots are considered

**Alert conditions:**
- Price returns to within X ticks of a marked pivot from the 4H or 1H
- Volume confirmation per Setup A threshold
- Direction = away from the pivot (pivot high → expect rejection down; pivot low → expect bounce up)
- Bias agreement or A+ grade required

**Exit/target rule for this setup specifically:** Target is the next pivot in the direction of the trade. `[04: "I would look to take my exits based on these pivots."]`

---

### Setup D — VIX / NQ Divergence *(scalp, NQ-only)*

**Trigger:** NQ and VIX moving in opposite directions on the 5-minute, both at their respective opposing levels.

**Source:** `[05_vix_nq_scalping.txt]`

His framing: "I see that they're moving in complete opposite ways — and that's where I like to make trades." `[05]`

**Mechanical conditions:**
- NQ at a key level (Setup A definition) OR at a pivot (Setup C definition)
- VIX at its own opposing key level — for an NQ short, VIX must be at support / demand; for an NQ long, VIX must be at resistance / supply
- 5-bar Pearson correlation between NQ close and VIX close on the 5min is ≤ -0.7 `[BUILD DEFAULT]`
- Volume confirmation on the NQ side (Bull vs Bear, same threshold as Setup A)

**This setup overrides daily bias** — it's a scalp pattern. Fires on the divergence signal regardless of trend, but uses tighter stops and smaller targets.

**Position sizing tag:** alerts for Setup D include `setup_type: "D_scalp"` so the Telegram payload can flag "scalp size only" — his stated 2-lot NQ example.

**Targets (his exact numbers):** $200 first profit, $320 max. With 2 lots NQ that's 5 points then 8 points. Payload includes `target_1_points: 5` and `target_2_points: 8`.

---

### Setup E — Daily High / Low Retest *(his stated go-to)*

**Trigger:** Price retests the prior day's high or low after a break, with volume confirming distribution / accumulation.

**Source:** `[01: "My main go-to strategy would be waiting for a daily high or daily open — we would retest that and then distribute after that."]`

**Mechanical conditions:**
- Price broke through PDH or PDL in the current session ("broken" = closed beyond by at least 1× ATR(14) of the 5min)
- Price returns to within X ticks of the broken level
- Bar closes on the side of the original break (above PDH for continuation long, below PDL for continuation short) — the "distribution" confirmation
- Volume confirmation per Bull vs Bear
- Within primary trading window

**This is the highest-priority alert template.** Engine flags Setup E alerts with `priority: high` regardless of computed grade.

---

## 4. Entry Triggers (what fires the alert)

Each setup's alert fires on the **CLOSE** of the entry-timeframe bar that satisfies all conditions. No tick-by-tick firing. This matches his discretionary approach: he doesn't enter on the level — he enters on the candle close that confirms the level held.

Direct quote: "We reach a key level, we wait for a change of direction... we enter." `[05]`

**Pine Script firing logic (pseudo):**
```pinescript
// Per setup, on bar close:
if (all_setup_conditions_met) {
    grade = compute_confluence_grade()
    if (grade != "C") {  // C = filtered, no alert
        alert(payload_json, alert.freq_once_per_bar_close)
    }
}
```

**Cooldown:** after any alert fires on a `symbol + setup` combo, suppress further alerts on the same combo for the next N bars. `[BUILD DEFAULT: N = 10 bars on 5min = 50 minutes]`. Prevents alert spam during chop.

---

## 5. Stop Placement Rules

Stops are mechanical and non-negotiable. Doctrine: "If we have a plan we can never lose. But if it goes against me, we close the trade and move on." `[03_livestream_qa_tail.txt]`

| Setup | Stop Placement |
|-------|----------------|
| A — Key Level + Volume | Beyond the level by 1× ATR(14) of entry TF, OR fixed 15 NQ / 8 ES / 20 GC ticks, whichever is greater |
| B — Supply/Demand Zone | Beyond the outer edge of the zone by 0.25× zone height |
| C — Pivot-to-Pivot | Beyond the pivot by 1× ATR(14) of the source TF (4H pivot → 4H ATR) |
| D — VIX/NQ Divergence | Tight — 1× ATR(14) of 5min, capped at 10 NQ points. Scalp discipline. |
| E — Daily H/L Retest | Beyond the broken level by 1× ATR(14) of 5min |

All stops are computed at alert generation time and included in the payload as `stop_price`. The trader sets the stop manually — the engine does not place orders.

Per-trade risk per the playbook: 1–2% of account. The Telegram message includes the stop distance in dollars per contract so the trader can size on the fly.

---

## 6. Target / Exit Logic

| Setup | Target 1 | Target 2 | Runner |
|-------|----------|----------|--------|
| A | Next key level in direction | Following key level | Trail with 5min swing-low/high |
| B | Midpoint of next opposing zone | Far edge of next opposing zone | Trail to next zone |
| C | Next pivot in direction | Following pivot | Trail with pivot structure |
| D | 5 NQ pts/lot ($100/lot) | 8 NQ pts/lot ($160/lot) | No runner — scalp exits at T2 |
| E | Prior daily extreme in trade direction | 1.5× distance from retest to PDH/PDL | Trail with 5min structure |

**"No next pivot" handling:** Direct quote: "Right now I don't have any upper pivots close by in the 5 minute, so I will just take profits for $320." `[05]`

Translates to: if no next-level target exists within 3× the stop distance, payload sets `target_2: null` and the alert message instructs taking profit at T1.

**Scale-out doctrine** (from playbook): 50% off at T1, 25% off at T2, 25% runner with trailing stop. Move stop to breakeven after T1 fills.

---

## 7. Session Timing Filters

Five time-based filters apply.

### 7a. Primary trading window — 9:30 AM – 11:00 AM ET (extendable to 12:00 PM)
`[02: "I trade 4 to 5 days out of the week from 9:30 to around 11:00 to 12:00."]`

Engine behavior:
- 9:30–11:00 ET → alerts fire at full priority
- 11:00–12:00 ET → priority reduced one grade
- 12:00–13:30 ET → alerts suppressed entirely (midday "danger zone" from playbook)

### 7b. Predictive window — 9:15 AM – 9:40 AM ET *(gold-specific)*
Direct quote: "Every time between 9:15 and 9:40, the market session will follow the trend within the entirety of the New York session." `[01]`

Implementation: on GC alerts only, capture the direction of price movement between 9:15 and 9:40 ET into a field `session_predictive_bias`. Alerts after 9:40 that agree with this bias get +1 confluence point. Alerts that disagree get downgraded one grade.

### 7c. Friday filter
Direct quote: "On Friday you really won't get the best price actions... it kind of generates some sort of fear for me." `[04]`

Implementation: on Fridays after 11:00 AM ET, all alerts downgrade one grade. Friday alerts of grade C are suppressed entirely.

### 7d. Economic release filter
Suppress all alerts during a window around scheduled releases: 5 min before through 15 min after these times: 8:30, 10:00, 2:00 PM ET. Fed days flagged separately and require manual override to fire.

Source: pulled into n8n from Forex.com / ForexFactory and stored in a Supabase `release_calendar` table that the alert engine queries via `request.security("CALENDAR_FEED", ...)` proxy or, more practically, via a daily n8n sync that writes today's blackouts into the TradingView chart's "no-fly zones" via the Pine Script `time()` function.

### 7e. Secondary window — 1:30 PM – 3:45 PM ET
Lower-priority alerts only. A+ grade required to fire.

---

## 8. Correlation Requirements

Every alert payload includes a correlation check object. The engine fetches correlated symbols' current state at alert generation time via `request.security()`.

### Gold (GC / MGC)
- **DXY** (Dollar Index) — inverse. Long GC alert: DXY should be falling or at resistance. Short GC: DXY rising or at support.
- **Other precious metals** (SI silver, PL platinum) — should move in the same direction as gold for a confluence point.

Source: `[01]`

### NQ (E-mini Nasdaq)
- **SPY** (S&P 500 ETF) — positive correlation
- **VIX** — inverse
- **NVDA** — heaviest single-name driver
- **QQQ** — positive
- **Magnificent 7 basket**: AAPL, MSFT, GOOGL, AMZN, META, TSLA, NVDA

Source: `[01, 02]`

### ES (E-mini S&P)
Same as NQ — VIX, SPY, Mag7. (Socrates rarely trades ES per the playbook but the engine supports it.)

### Mechanical correlation check
For each correlated symbol, the engine computes the 20-bar Pearson correlation on the same timeframe as the alert. An alert is "correlation-aligned" if:
- **Positive correlation pair:** `corr > 0.6` AND current direction matches
- **Negative correlation pair** (VIX↔NQ, DXY↔GC): `corr < -0.6` AND current direction opposes

Payload includes:
```json
"correlation_check": {
  "dxy": {"aligned": true, "corr": -0.74},
  "vix": {"aligned": true, "corr": -0.71},
  ...
}
```

Each aligned correlation adds +0.5 confluence points (§9).

---

## 9. Confluence Scoring (A+ / A / B / C)

Each alert is graded by counting confluence points at the trigger price.

### Point system

| Confluence factor | Points |
|---|---|
| Setup A conditions met (key level + volume + rejection) | 2 |
| Setup B conditions met (fresh S/D zone + volume) | 2 |
| Setup C conditions met (structural pivot + volume) | 2 |
| Setup D conditions met (VIX/NQ divergence) | 2 |
| Setup E conditions met (PDH/PDL retest distribution) | 3 *(priority setup)* |
| Additional level within 5 ticks of trigger price (e.g. zone AND pivot at same price) | +1 per overlap |
| Daily bias agreement | +1 |
| 4H bias agreement | +1 |
| Correlation alignment (per aligned correlated symbol) | +0.5 each |
| Inside primary trading window (9:30–11:00) | +1 |
| Predictive bias agreement (gold only, after 9:40) | +1 |
| Bull vs Bear strength delta ≥ 20 pp (vs default 10 pp) | +1 |
| Fresh zone (not tagged in prior 50 bars) | +1 |

### Grade thresholds

| Grade | Points | Telegram behavior |
|-------|--------|-------------------|
| **A+** | ≥ 6 | High-priority message with @mention, Supabase `priority: 1` |
| **A** | 4 – 5.5 | Standard message, `priority: 2` |
| **B** | 3 – 3.5 | Quiet message (no sound), `priority: 3` |
| **C** | < 3 | Filtered — logged to Supabase for analysis, NOT sent to Telegram |

### Downgrades that override the point total
- Friday after 11:00 → downgrade one grade
- Inside economic release window → suppress entirely
- Outside primary or secondary window → downgrade one grade
- Daily bias strongly opposed (price > 2× ATR away from Daily 20-EMA) → downgrade one grade

### Playbook A+ checklist (encoded in payload)
The playbook lists 9 conditions for an A+ setup. The engine validates these and the payload includes a `playbook_checklist` object showing which conditions passed. Useful for the Telegram message body and for backtesting.

```
confluence_2plus_tools     — at least 2 confluences at this price
zone_fresh                 — zone has not been tested since formation
htf_bias_agrees            — daily/4H trend aligns with direction
confirmation_present       — rejection wick / reversal candle
stop_at_structural         — stop is at a logical structural point
rr_min_1p5                 — reward:risk ≥ 1.5:1 to T1
no_release_within_15min    — no scheduled news in next 15 min
not_first_5_min            — not the opening drive
daily_loss_limit_ok        — daily loss limit not approached (manual)
```

---

## 10. Volume Confirmation Rules (Bull vs Bear)

The Bull vs Bear indicator (Arena / DGT) displays bull-side strength % and bear-side strength %, summing to ~100% per bar. It tracks rolling momentum and shows "flips" when the dominant side changes. `[02]`

His framing: "All I need is strong volume" and "I like to see the flips and the volume and the switches and the velocity and how it's moving." `[02]`

### Mechanical extraction
Pine Script cannot read another indicator's plotted values without that indicator exposing them. Two paths:

**Path A (preferred) — Replicate the calculation:**
- Bull strength = `(close − low) / (high − low) × volume`, summed and smoothed over period
- Bear strength = `(high − close) / (high − low) × volume`, summed and smoothed over period
- Both normalized to 0–100% scale
- `[BUILD DEFAULT: lookback = 14 bars, smoothing = EMA(3)]`

**Path B (fallback) — Proxy via VWAP-deviation + volume-z-score.** Less accurate, simpler.

### Volume confirmation thresholds

| Condition | Threshold |
|-----------|-----------|
| Minimum bar volume (any setup) | Bar volume ≥ 1.5× the 20-bar average on entry TF |
| Bull-side dominance (long setups) | Bull strength ≥ 60% AND rising for 2+ bars |
| Bear-side dominance (short setups) | Bear strength ≥ 60% AND rising for 2+ bars |
| Flip detection (reversal setups B, E) | Bull/Bear strength crossed in the last 2 bars |
| Velocity bonus (+1 confluence point) | Bull/Bear strength changed by ≥ 15 pp in the last 3 bars |

`[All values BUILD DEFAULT — TUNE LATER. The 30-day validation phase logs every alert's outcome against these thresholds so we can find what actually discriminates winners from losers.]`

### Volume veto
If bar volume < 0.7× the 20-bar average AND Bull vs Bear shows neither side ≥ 55%, the alert is **suppressed entirely** regardless of confluence points. This encodes his "if the volume's not there, it's not going to move" rule directly.

---

## Appendix A — Alert Payload Schema (JSON)

This is the exact JSON shape TradingView webhooks send to n8n. Keep this stable; the n8n workflow, Supabase schema, and Telegram formatter all read from it.

```json
{
  "schema_version": "1.0",
  "alert_id": "evt_2026-05-20T13:34:00Z_NQ_5_A",
  "timestamp_utc": "2026-05-20T13:34:00Z",
  "timestamp_et": "2026-05-20T09:34:00-04:00",
  "symbol": "NQ1!",
  "timeframe": "5",
  "setup_type": "A",
  "setup_name": "Key Level + Volume",
  "grade": "A+",
  "grade_points": 7.5,
  "direction": "short",
  "price": 18500.25,
  "stop_price": 18510.00,
  "stop_distance_points": 9.75,
  "stop_distance_dollars_per_contract": 195.00,
  "target_1": 18475.00,
  "target_2": 18450.00,
  "target_1_dollars_per_contract": 505.00,
  "level": {
    "type": "prior_day_high",
    "price": 18495.00,
    "freshness_bars": 47
  },
  "volume": {
    "bull_pct": 32,
    "bear_pct": 68,
    "bar_volume_vs_20avg": 1.84,
    "flip_detected": true
  },
  "confluences": [
    "prior_day_high",
    "4h_supply_zone",
    "ict_ny_open_window",
    "4h_bear_trend",
    "daily_bear_trend"
  ],
  "correlation_check": {
    "spy": {"aligned": true, "corr": 0.78},
    "vix": {"aligned": true, "corr": -0.71},
    "nvda": {"aligned": false, "corr": 0.61}
  },
  "session": {
    "window": "primary",
    "ict_zone": "ny_open",
    "is_friday_pm": false,
    "in_release_window": false
  },
  "playbook_checklist": {
    "confluence_2plus_tools": true,
    "zone_fresh": true,
    "htf_bias_agrees": true,
    "confirmation_present": true,
    "stop_at_structural": true,
    "rr_min_1p5": true,
    "no_release_within_15min": true,
    "not_first_5_min": true,
    "daily_loss_limit_ok": null
  },
  "notes": ""
}
```

---

## Appendix B — Source Transcript Map

| File | Primary contribution to spec |
|------|------------------------------|
| `Socrates_Investments_Playbook.docx` | Risk management framework, A+ checklist, session windows, scale-out rules |
| `00_INDEX.txt` | Setup type catalog (A–E), correlation pairs |
| `01_strategy_walkthrough_gold_nq.txt` | Timeframe hierarchy, asset focus, predictive 9:15–9:40 window, daily P&L targets |
| `02_indicator_breakdown.txt` | All 6 indicator names + search terms, entry/charting timeframes, primary trading window |
| `03_livestream_qa_tail.txt` | Stop doctrine ("close the trade and move on"), pattern recognition philosophy |
| `04_pivot_trading_part2.txt` | Pivot definition (structural, not floor-trader), Friday filter, structure reading |
| `05_vix_nq_scalping.txt` | Setup D mechanics, scalp position sizing, $200/$320 targets |

---

## Appendix C — Known Limitations & Open Questions

Things this spec deliberately leaves open for the build chat:

1. **Pivot detection `N` parameter** — defaults are 5 on 1H, 3 on 4H. May need symbol-specific tuning. Backtest in stage 2.

2. **Bull vs Bear formula** — replicating the Arena/DGT indicator requires reverse-engineering. If Path A is unreliable, fall back to Path B (VWAP-deviation proxy).

3. **Zone freshness vs zone strength** — spec treats "untagged in last N bars" as binary. Some traders weight by how impulsive the move was that created the zone. Defer to v1.1.

4. **Bias on a ranging daily** — currently allowed in both directions with grade A minimum. May be too permissive; review after 30 days of live data.

5. **Multi-symbol simultaneous alerts** — if NQ and ES both fire Setup A at the same instant, do they aggregate into one "index-wide" alert or stay separate? v1 keeps them separate.

6. **The "magic sauce" gap** — Socrates explicitly says his level marking is partly intuitive ("you just have to kind of have an image in your head"). The engine will systematically under-fire vs his actual trades. Accept this in v1; close the gap later by comparing alert log to his Discord signal log.

7. **Discord signal benchmark** — for the first 2 weeks of validation, log his Discord buy/sell signals manually alongside our alert log so we can measure overlap. Helps tune confluence weights.

---

## Build sequence (for the next chat)

Order of Pine Script work:

1. **Helper functions** — ATR, EMA, volume Z-score, Pearson correlation against `request.security()` symbols
2. **Level computation** — PDH, PDL, ONH, ONL, weekly / monthly H/L/Open
3. **Bull vs Bear replication** (Path A)
4. **Supply / Demand zone detector**
5. **Structural pivot detector**
6. **Setup A logic + alert emission**
7. **Setups B, C, E**
8. **Setup D** (cross-symbol — needs VIX feed)
9. **Confluence scoring engine**
10. **Payload formatter** + `alert.freq_once_per_bar_close` calls

n8n workflow comes after Pine Script is firing valid alerts to a test webhook. Supabase schema is documented separately in the build chat.

---

*End of `socrates_rules_spec.md` v1.0*
