# n8n Setup — Socrates Alert Receiver v1

Step-by-step to get `n8n-workflows/socrates-alert-receiver.v1.json` running on `lpinvestments.app.n8n.cloud`. Time estimate: ~15 min the first time.

## What this workflow does

Receives Pine Script alert webhooks from TradingView, validates them, dedupes by `alert_id`, writes every event to `socrates.alerts` in Supabase, checks the news-release blackout window, and posts A+/A/B grades to the Socrates Signals Telegram channel. C-grade events are DB-only (backtest corpus).

See `docs/architecture/n8n-workflow.md` for the full node graph and design rationale.

## Prerequisites

- n8n cloud instance: `lpinvestments.app.n8n.cloud` (you have access)
- Supabase project: `LPI Website Storage` (ref `rotfkasubwpgzlqmlclt`), `socrates` schema already migrated
- Telegram bot token (post-revoke fresh token) for `LPI Socrates alerts bot`
- Telegram channel chat_id: `-1003961335144` (Socrates Signals)
- A random ~32-char string to use as the webhook shared secret

---

## 1. Generate a webhook secret

Any high-entropy string. Easy options:

**PowerShell:**
```powershell
-join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object {[char]$_})
```

**Or just type one:** anything random ≥ 24 chars works. Save it — you'll paste it in two places (n8n + TradingView).

---

## 2. Import the workflow

1. Open `https://lpinvestments.app.n8n.cloud`
2. Top right → **Workflows** → **+ Add Workflow** (or use the workflow list page's import option)
3. In the workflow editor, click the **⋮** menu (top right) → **Import from File**
4. Select `C:\Users\nlazz\Projects\socrates-confluence-engine\n8n-workflows\socrates-alert-receiver.v1.json`
5. The canvas should now show 11 nodes wired together. **Don't activate yet** — credentials and env vars come next.

You'll see warnings on nodes that reference missing credentials. That's expected.

---

## 3. Set n8n environment variables

n8n cloud → **Settings** → **Variables** (or **Environment variables** depending on plan). Add:

| Variable | Value |
|---|---|
| `SOCRATES_WEBHOOK_TOKEN` | the secret you generated in step 1 |
| `SOCRATES_TELEGRAM_CHAT_ID` | `-1003961335144` |

If your n8n plan doesn't have a Variables panel, you can hardcode them in the **Validate & Auth** and **Format Telegram message** code nodes instead — search for `$env.SOCRATES_WEBHOOK_TOKEN` and `$env.SOCRATES_TELEGRAM_CHAT_ID` and replace with string literals. Env vars are cleaner if available.

---

## 4. Create the Postgres credential (Supabase)

In Supabase dashboard → `LPI Website Storage` → top of page click **Connect** → **Direct** tab → scroll to the **SHARED POOLER** (Session pooler, IPv4-compatible) section:

```
Host:      aws-1-us-east-1.pooler.supabase.com   ← shard number varies, use what your Connect modal shows
Port:      5432
Database:  postgres
User:      postgres.rotfkasubwpgzlqmlclt
Password:  <your Supabase DB password — see "Finding the password" below>
SSL:       Require
```

> **Pooler hostname varies.** Supabase assigns each project to a pooler shard (`aws-0-...`, `aws-1-...`, etc.). Use the exact host string from your Connect modal — don't copy from this doc verbatim.

### Finding the password

The Connect modal shows `[YOUR-PASSWORD]` as a literal placeholder, not the actual password. To get it:

1. **Check first** (avoids breaking anything): your password manager / saved notes / `.env` file in the LPI Website Storage app codebase
2. **Reset as last resort**: Supabase dashboard → Project Settings → (in newer UI: somewhere under Database / Connect) → Reset database password. ⚠️ This breaks any other service currently connected to LPI Website Storage with the old password until you update those too.

In n8n:

1. Open the **Upsert into socrates.alerts** node
2. Under **Credential for Postgres account**, click **Create New**
3. Name it: `Supabase — LPI Website Storage`
4. Fill in the connection details above
5. Click **Save** — n8n tests the connection. Should say "Connection successful."
6. Open the **Check release window**, **Mark delivered_to_telegram**, and **Mark release_window_check (suppressed)** nodes — assign the same credential (the dropdown should now list it).

> The credential ID in the workflow JSON is the placeholder `REPLACE_WITH_POSTGRES_CRED_ID`. When you assign your real credential, n8n updates the reference automatically.

---

## 5. Create the Telegram credential

1. Open the **Telegram sendMessage** node
2. Under **Credential for Telegram API**, click **Create New**
3. Name it: `Socrates Telegram Bot`
4. **Access Token**: paste your post-revoke fresh bot token
5. Click **Save** — n8n calls `getMe` to verify. Should show the bot's username.

---

## 6. Activate and copy the webhook URL

1. Top right of the workflow editor: toggle **Active** to ON
2. Open the **Webhook (TradingView)** node — copy the **Production URL** (looks like `https://lpinvestments.app.n8n.cloud/webhook/socrates/alert`)
3. The full TradingView webhook URL is:
   ```
   https://lpinvestments.app.n8n.cloud/webhook/socrates/alert?token=<your-secret>
   ```

---

## 7. Wire up TradingView

In your TradingView chart with the Socrates Confluence Alert Engine v1.0.1 loaded:

1. Right-click chart → **Add alert** (or the bell icon top right)
2. **Condition**: `SCAE_v1.0.1` → **Any alert() function call**
3. **Message** field: leave blank (Pine emits the JSON via `alert()`, this field is ignored)
4. **Notifications tab** → enable **Webhook URL**, paste:
   ```
   https://lpinvestments.app.n8n.cloud/webhook/socrates/alert?token=<your-secret>
   ```
5. **Expiration**: open-ended (or set per your TradingView plan)
6. Click **Create**

---

## 8. Smoke test

### Option A — fire a real test alert from Pine

In TV's Pine Editor, temporarily add at the very bottom of the script:

```pinescript
if barstate.islast
    alert('{"schema_version":"1.0","alert_id":"evt_smoke_test","timestamp_utc":"2026-05-24T13:34:00Z","timestamp_et":"2026-05-24T09:34:00-04:00","symbol":"NQ1!","timeframe":"5","setup_type":"E","setup_name":"Daily H/L Retest","grade":"A+","grade_points":7.5,"direction":"short","price":18500.25,"stop_price":18510,"stop_distance_points":9.75,"stop_distance_dollars_per_contract":195,"target_1":18475,"target_2":18450,"target_1_dollars_per_contract":505,"level":{"type":"prior_day_high","price":18495,"freshness_bars":47},"volume":{"bull_pct":32,"bear_pct":68,"bar_volume_vs_20avg":1.84,"flip_detected":true},"confluences":["prior_day_high","4h_supply_zone","ny_open"],"correlation_check":{},"session":{"window":"primary","ict_zone":"ny_open"},"playbook_checklist":{},"notes":"smoke test"}', alert.freq_once_per_bar_close)
```

Save the script. The next bar close should fire the test alert through the full pipeline. **Remove the test block after.**

### Option B — fire a raw curl (faster, no Pine edits)

In PowerShell (replace `<your-secret>`):

```powershell
$body = Get-Content -Raw -Encoding UTF8 -Path "C:\Users\nlazz\Projects\socrates-confluence-engine\n8n-workflows\test-payload.json"
Invoke-RestMethod -Method Post `
  -Uri "https://lpinvestments.app.n8n.cloud/webhook/socrates/alert?token=<your-secret>" `
  -ContentType "application/json; charset=utf-8" `
  -Body $body
```

> **Windows PowerShell 5.1 encoding gotcha.** Without `-Encoding UTF8`, `Get-Content` reads files using the system codepage (usually Windows-1252), which mangles any non-ASCII chars. Always pass `-Encoding UTF8` when reading JSON/YAML/UTF-8 files for HTTP bodies.

(Create `n8n-workflows/test-payload.json` from the JSON shown in Option A — same payload, just save it as a file.)

### Expected behavior

| Check | How to verify |
|---|---|
| Row in `socrates.alerts` | Supabase Table Editor → `socrates.alerts` schema → one row with `alert_id = evt_smoke_test`, `is_new = true` (well, the row exists), `delivered_to_telegram = true` |
| Message in Telegram | Socrates Signals channel shows the formatted A+ alert |
| Idempotency | Re-run the curl → no duplicate row, no second Telegram message |
| C-grade is DB-only | Change `"grade":"A+"` to `"grade":"C"` in the payload, change `alert_id` to a new value → row appears in Supabase, NO Telegram message |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| n8n execution: "SOCRATES_WEBHOOK_TOKEN env var is not set" | Variables not configured in step 3 | Add env var or hardcode in Code node |
| 401: invalid token | Webhook URL is missing or wrong `?token=` | Re-check the URL TradingView calls |
| 400: missing required field | Pine payload is malformed | Inspect the execution's "Webhook" node input in n8n |
| Postgres: relation "socrates.alerts" does not exist | Migration didn't apply, or wrong credential | Re-check Supabase project + that migration `20260524035154_socrates_initial_schema` shows in `list_migrations` |
| Telegram: chat not found | `SOCRATES_TELEGRAM_CHAT_ID` wrong, or bot kicked from channel | Re-verify `-1003961335144` and that the bot is still admin |
| Telegram: 401 Unauthorized | Bot token wrong/revoked | Update the credential with the current token |
| Workflow doesn't trigger | Workflow not Active, or TradingView using **Test URL** instead of **Production URL** | Toggle Active on; use Production URL from the webhook node |

## Operational notes

- **Test vs Production URLs.** n8n's webhook node exposes two URLs. Test URL only works while you're editing the workflow with the Listen for test event button pressed. Production URL works whenever the workflow is Active. TradingView must use the Production URL.
- **Execution logs.** Every webhook hit creates an n8n execution row. Useful for debugging. Workflow settings have `saveDataErrorExecution: 'all'` so failures are kept indefinitely.
- **Schema changes.** If the Pine payload schema bumps to 2.0, update the `Validate & Auth` node's version check first, then add migration `0002_*.sql` for any new columns, then update the Upsert node's SQL.
- **Credential rotation.** Webhook secret rotates by updating the n8n env var AND the TradingView alert URL in lockstep. Telegram token rotates via BotFather → update credential. Postgres password rotates via Supabase dashboard → update credential.

## Reference

- Workflow source: `n8n-workflows/socrates-alert-receiver.v1.json`
- Architecture: `docs/architecture/n8n-workflow.md`
- Decisions: `docs/decisions/0001-chat-3-decisions.md`
- Supabase schema: `supabase/migrations/0001_socrates_initial.sql`
- Pine: `pine-scripts/socrates_confluence_alert_engine_v1.pine` (v1.0.1)
