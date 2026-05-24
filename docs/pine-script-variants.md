# Pine Script Variants — Full vs Lite

Two Pine scripts ship side-by-side in `pine-scripts/`. They are functionally identical except for which correlated symbols they reference, which controls which **TradingView real-time market data subscriptions** you must hold.

## Side-by-side

| | **Full** (`socrates_confluence_alert_engine_v1.pine`) | **Lite** (`socrates_confluence_alert_engine_v1_lite.pine`) |
|---|---|---|
| Indicator title in TV | `Socrates Confluence Alert Engine v1.0.2` | `Socrates Confluence Alert Engine v1.0.2 (Lite)` |
| `shorttitle` | `SCAE_v1` | `SCAE_v1_lite` |
| Required TV data subs | CME Group ($7/mo) + NASDAQ ($3/mo) + NYSE Arca ($3/mo) | **CME Group only ($7/mo)** |
| NQ/ES correlated symbols | VIX, SPY, NVDA, QQQ | **VIX only** (SPY/NVDA/QQQ stubbed to `na`) |
| GC correlated symbols | DXY, SI | DXY, SI (unchanged) |
| Max confluence score for NQ/ES | unchanged from spec | up to **−1.5 points** vs Full |
| Estimated effect on alert flow | baseline | ~5–10% of NQ/ES alerts grade one band lower; ~2–5% of borderline B alerts drop to C and skip Telegram |
| GC trades | baseline | **unaffected** — gold doesn't use equity correlations |

## Why both exist

NASDAQ and NYSE Arca real-time data are paid add-ons on TradingView (~$3/mo each). The Full version's `request.security()` calls for SPY (NYSE Arca), NVDA (NASDAQ), and QQQ (NASDAQ) cause TradingView to **block alert creation** if you don't hold those subscriptions:

> *"You're unable to save this alert as your script inputs contain symbols for which you don't have a data subscription."*

The Lite version stubs those three symbols to `na` so the alert saves and runs without those subscriptions. The Pine still computes a confluence score — just without the equity correlations. The grading is **strictly more conservative** than Full (it can never overstate confidence; only understate).

## How to switch

### Lite → Full (you've added NASDAQ + NYSE Arca data subs)

1. **In TradingView**: Pine Editor → open `socrates_confluence_alert_engine_v1.pine` (the Full file from your local repo clone, paste in)
2. **Save** (Ctrl+S in Pine Editor)
3. **Add to chart** — this loads a NEW indicator instance titled `Socrates Confluence Alert Engine v1.0.2` (no "Lite")
4. *Optional*: remove the Lite indicator from the chart so you don't have both running. Click the indicator label on the chart → **Remove**.
5. **Update your TradingView Alert**: it's pointed at `SCAE_v1_lite` ("Any alert() function call"). You need to either:
   - Edit the existing alert → change Condition to `SCAE_v1` → save
   - Or delete and recreate the alert pointing at `SCAE_v1`
6. **No n8n changes needed**: the JSON payload schema is identical between variants. Only difference downstream is the `correlation_check` object will now include `spy`, `nvda`, `qqq` keys for NQ/ES alerts.

### Full → Lite (you cancelled NASDAQ / NYSE Arca subs)

Mirror image: load the Lite Pine, save, add to chart, swap the TradingView alert's condition to `SCAE_v1_lite`. Optional: remove the Full indicator from the chart.

## When to use which

**Lite** — choose this if:
- You're on the CME Group ($7/mo) bundle only and don't want to add equity data
- You're in evaluation/testing and not ready to commit to extra monthly fees
- You only trade GC (gold) — Lite is functionally identical to Full for GC trades
- You want minimum monthly cost while still getting the full setup/grading logic

**Full** — choose this if:
- You actively trade NQ or ES and want the strongest available confluence signal
- The +$6/mo for NASDAQ + NYSE Arca is justified by the ~5–10% precision improvement
- You're past the validation phase and the bot is producing real value

You can switch back and forth at any time. No data is lost on either side. Supabase doesn't care — the schema accepts either payload shape (correlation_check is JSONB; extra keys are fine, missing keys are fine).

## What's identical between Full and Lite

Everything except the three input declarations, three `request.security()` calls, three correlation calcs, three direction-flag computations, and the three payload entries for SPY/NVDA/QQQ. The diff is ~20 lines out of ~1280. All other logic (Setups A/B/C/E, bias detection, volume veto, session windows, grading thresholds, cooldown, Friday filter, predictive window, etc.) is byte-identical.

To verify, run from the project root:

```bash
diff pine-scripts/socrates_confluence_alert_engine_v1.pine \
     pine-scripts/socrates_confluence_alert_engine_v1_lite.pine
```

You'll see ~7 hunks, all in the equity-correlation area.

## Maintenance note

When patching the Pine going forward (e.g., adding Setup D in v1.1, tweaking confluence thresholds, bug fixes), **apply the change to BOTH files** unless it's specifically about the equity-correlation logic. Future patches should preserve the variant boundary. If we ship enough patches that the maintenance burden becomes painful, consider collapsing into a single file with a `i_enableEquityCorrelations` boolean input — but for now, two files is simpler operationally and easier to reason about in TV.
