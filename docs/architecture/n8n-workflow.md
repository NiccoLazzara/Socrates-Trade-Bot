# n8n Workflow Architecture — Socrates Alert Receiver

*Status: design — implementation lives in `n8n-workflows/socrates-alert-receiver.v1.json` (TBD).*
*Companion to `docs/socrates_rules_spec.md` v1.0.*

## Purpose

Receive Pine Script webhooks from TradingView, validate and dedup them, persist every event to Supabase, and route high-grade alerts to a private Telegram channel. n8n is the enrichment + routing layer between the deterministic Pine alert generator and the durable Supabase log / human-readable Telegram feed.

## End-to-end pipeline

```
TradingView Pine Script
  │  (HTTP POST, JSON payload — schema_version "1.0", spec Appendix A)
  ▼
n8n webhook   (this workflow)
  │
  ├─► Supabase  ── alerts table (every event, all grades)
  │
  └─► Telegram  ── channel posts (A+ / A / B only; C is DB-only)
```

## Node graph

```
┌────────────────────────────────────────────────────────────────────────┐
│ 1. Webhook trigger  POST /webhook/socrates/alert                       │
│    Auth: ?token=<shared-secret>  ──  reject if mismatched              │
└────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 2. Function: validateSchema                                            │
│    - assert schema_version === "1.0"                                   │
│    - assert required keys (alert_id, symbol, grade, direction, price,  │
│      stop_price, setup_type)                                           │
│    - shape errors → respond 400, log to Supabase `alerts_rejected`     │
└────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 3. Supabase: upsert into `alerts` (ON CONFLICT alert_id DO NOTHING)    │
│    - Idempotency handled here. TradingView occasionally double-fires;  │
│      same alert_id → silently dropped.                                 │
│    - Writes ALL grades incl. C. Telegram split comes after.            │
│    - Returns whether the row is new or duplicate.                      │
└────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 4. IF: rowIsNew && !inReleaseWindow                                    │
│    - inReleaseWindow: look up `release_calendar` for ±15 min of ts_et  │
│      (spec §7d). If hit, mark release_window_check=true on the row     │
│      and stop.                                                         │
└────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 5. Switch by `grade`                                                   │
│    ├─ "A+" → Telegram (priority, audible, header @mention/badge)       │
│    ├─ "A"  → Telegram (standard)                                       │
│    ├─ "B"  → Telegram (silent: disable_notification=true)              │
│    └─ "C"  → end. DB-only — backtest corpus per spec §9.               │
└────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 6. Function: formatTelegramMessage                                     │
│    - Markdown V2 body using payload fields                             │
│    - Inline keyboard: "[ Open chart ]" link to TV; "[ ACK ]" callback  │
│      (acks write back to Supabase via a follow-up callback workflow)   │
└────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 7. Telegram: sendMessage → channel chat_id                             │
└────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 8. Supabase: UPDATE alerts SET delivered_to_telegram=true,             │
│              telegram_message_id=<returned id> WHERE alert_id=…        │
└────────────────────────────────────────────────────────────────────────┘
```

## Supabase schema (v1)

Two tables, indexed for the actual access patterns: lookup by `alert_id` (idempotency), recency (`ts_utc`), and backtest filters (`symbol`, `grade`).

```sql
create table alerts (
  alert_id                            text primary key,
  schema_version                      text        not null,
  ts_utc                              timestamptz not null,
  ts_et                               timestamptz not null,
  symbol                              text        not null,
  timeframe                           text        not null,
  setup_type                          text        not null,   -- A | B | C | D | E
  setup_name                          text,
  grade                               text        not null check (grade in ('A+','A','B','C')),
  grade_points                        numeric,
  direction                           text        check (direction in ('long','short')),
  price                               numeric,
  stop_price                          numeric,
  stop_distance_points                numeric,
  stop_distance_dollars_per_contract  numeric,
  target_1                            numeric,
  target_2                            numeric,
  target_1_dollars_per_contract       numeric,
  level                               jsonb,                  -- {type, price, freshness_bars}
  volume                              jsonb,                  -- {bull_pct, bear_pct, bar_volume_vs_20avg, flip_detected}
  confluences                         text[],
  correlation_check                   jsonb,
  session                             jsonb,
  playbook_checklist                  jsonb,
  notes                               text,
  -- enrichment fields written by n8n
  release_window_check                boolean     default false,
  delivered_to_telegram               boolean     default false,
  telegram_message_id                 bigint,
  received_at                         timestamptz default now()
);
create index alerts_ts_idx            on alerts (ts_utc desc);
create index alerts_symbol_grade_idx  on alerts (symbol, grade);

create table release_calendar (
  release_date    date not null,
  release_time_et time not null,
  event_name      text not null,
  importance      text,                                       -- 'high' | 'medium' | 'low'
  primary key (release_date, release_time_et, event_name)
);
```

## Design decisions

See `docs/decisions/0001-chat-3-decisions.md` for the ADR records. Summary:

1. **Supabase first, Telegram second.** DB write is source of truth; Telegram is downstream notification. If Telegram is down we still have the alert; if Supabase is down, n8n retries.
2. **Idempotency via `alert_id` PK + `ON CONFLICT DO NOTHING`.** Pine emits a unique `alert_id` per setup-per-bar-close (`ts_utc + symbol + timeframe + setup_type`).
3. **News-window check lives in n8n.** Pine can't reach external data reliably; n8n owns the `release_calendar` table and the ±15-min suppression check.
4. **All grades written to DB; only A+/A/B sent to Telegram.** C-grade is the backtest corpus per spec §9 — requires patching Pine to emit C (currently suppressed at line 1165 of the v1 Pine script).
5. **Single private Telegram channel.** A+/A/B distinguished by formatting (priority badge, sound, silent flag).
6. **Webhook auth = shared-secret query param.** TradingView can't sign requests; n8n validates `?token=` against a value stored in n8n credentials. Workflow JSON is safe to commit credential-stripped.
7. **Setup D supported in workflow even though Pine v1 defers it.** The branch already routes any `setup_type` value, so no n8n change needed when Pine v1.1 ships.

## Failure modes & retries

| Stage | Failure | Behavior |
|---|---|---|
| Webhook auth | Bad/missing `?token` | 401, no DB write, no Telegram |
| Schema validation | Missing required field | 400, log to `alerts_rejected`, no Telegram |
| Supabase insert | DB down / network | n8n retry queue (default 3 attempts, exponential backoff); Telegram delayed |
| Telegram send | Bot kicked / token revoked / API down | Row stays in Supabase with `delivered_to_telegram=false`; manual replay workflow re-attempts |
| Release-window hit | Alert during ±15-min news window | Row marked `release_window_check=true`, no Telegram |

## Open items

- **Replay workflow** for failed Telegram sends (`delivered_to_telegram=false AND received_at > now() - interval '1 day'`). Build after the main flow is stable.
- **Daily P&L state** (spec §"playbook_checklist.daily_loss_limit_ok"). Currently `null` from Pine. n8n could track per-day delivered alert P&L, but this is post-validation work.
- **TradingView IP allowlist** in addition to token auth, when n8n webhook gets HTTPS termination from a proxy that supports it.
- **Backfill / historical alert import** if the Pine script generates a backtest CSV — currently out of scope.

## References

- Source-of-truth spec: `docs/socrates_rules_spec.md`
- Pine implementation: `pine-scripts/socrates_confluence_alert_engine_v1.pine`
- Decision log: `docs/decisions/0001-chat-3-decisions.md`
- n8n instance: `lpinvestments.app.n8n.cloud`
