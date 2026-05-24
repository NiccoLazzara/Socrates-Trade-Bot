# ADR 0001 — Chat #3 architecture decisions

*Date: 2026-05-21*
*Phase: n8n workflow design (Chat #3)*

A short record of the decisions made while designing the n8n alert receiver and the Supabase schema. Each decision lists the alternatives considered and the consequences accepted.

---

## D1 — C-grade alerts: write to Supabase, suppress from Telegram

**Context.** Spec §9 says C-grade (< 3 confluence points) alerts should be **logged to Supabase for backtest analysis, NOT sent to Telegram**. The current Pine Script v1.0 (line 1165: `shouldFire = anyFired and not suppressed and grade != "C"`) suppresses C entirely at the Pine layer, so n8n never sees them.

**Decision.** Patch the Pine Script to emit C-grade alerts. Route them in n8n: write to Supabase, do NOT send to Telegram.

**Alternatives considered.**
- Keep Pine as-is, accept no C-grade corpus. Rejected: loses the negative-class data needed to tune grading thresholds during the 30-day validation phase.
- n8n synthesizes C-grade rows from missing data. Rejected: not possible — Pine is the only place that knows what setups *almost* fired.

**Consequences.** Pine bumps to v1.0.1 with the one-line change on line 1165. n8n's grade switch routes `"C"` to a no-op branch after the Supabase upsert.

---

## D2 — Single private Telegram channel for all grades

**Context.** Chat #3 needs a place to push human-readable alerts. Options: one channel with formatting differences, or 2-3 channels segmented by grade.

**Decision.** One private channel (`Socrates Signals`, chat_id `-1003961335144`). Grades distinguished by message formatting: A+ uses priority emoji + audible notification, A is standard, B uses `disable_notification=true`.

**Alternatives considered.**
- Two channels (A+/A vs B). Rejected: signal volume is low; segmentation overhead outweighs benefit.
- Three channels (one per grade). Rejected: same reason, more so.

**Consequences.** A single chat_id config in n8n. Telegram per-channel notification settings (sound on/off, mute schedule) apply uniformly — finer control comes from message-level `disable_notification`.

---

## D3 — Manual news calendar paste (v1)

**Context.** Spec §7d requires suppressing alerts ±15 min around scheduled economic releases. Source options range from manual entry to paid APIs.

**Decision.** Daily manual paste of high-impact events into a Google Sheet; n8n cron syncs the sheet to Supabase `release_calendar` each morning.

**Alternatives considered.**
- Scrape ForexFactory. Rejected for v1: fragile, breaks on HTML changes.
- Paid API (Trading Economics, FMP, Finnhub). Rejected for v1: $10–50/mo before we've proven the project sticks. Revisit post-validation.

**Consequences.** ~2 min/day manual work during the validation phase. n8n flow assumes `release_calendar` is current; stale data → false negatives on the suppression check. Acceptable for v1.

---

## D4 — Supabase write before Telegram send

**Context.** Two side effects per alert: persist to DB, notify human. Order matters under partial failure.

**Decision.** Supabase upsert runs first. Telegram send runs only after a successful DB write.

**Alternatives considered.**
- Telegram first, then DB. Rejected: if DB fails, we have a notification with no audit trail — bad for backtest integrity.
- Both in parallel. Rejected: harder to reason about, and the order matters anyway for the `delivered_to_telegram` update step.

**Consequences.** If Telegram is down, the row sits in Supabase with `delivered_to_telegram=false`; a replay workflow can re-attempt. If Supabase is down, n8n retries (default 3, exponential backoff); Telegram is delayed but not lost.

---

## D5 — Idempotency via `alert_id` primary key

**Context.** TradingView occasionally double-fires alerts on chart reload or webhook timeout retries. Without idempotency, the DB grows duplicate rows and Telegram spams the user.

**Decision.** `alerts.alert_id` is the primary key. Inserts use `ON CONFLICT (alert_id) DO NOTHING`. Duplicates are silently dropped at the DB layer.

**Alternatives considered.**
- Time-window dedup in n8n (drop if same payload seen in last 30s). Rejected: harder to reason about than a DB constraint, and the DB constraint catches duplicates across n8n restarts too.

**Consequences.** Pine must guarantee `alert_id` uniqueness per legitimate event. Current Pine builds it from `ts_utc + symbol + timeframe + setup_type` — unique per setup-per-bar-close. Good enough.

---

## D6 — Webhook auth: shared-secret query parameter

**Context.** n8n webhook is public on the internet. TradingView cannot sign requests or attach custom headers reliably.

**Decision.** Webhook URL includes `?token=<secret>`. n8n's first function node validates the token; mismatches return 401 with no DB write or Telegram send.

**Alternatives considered.**
- IP allowlist for TradingView. Rejected for v1: TV publishes a broad range; some webhook providers don't surface client IP cleanly. Can layer this on top later.
- HMAC signature in payload. Rejected: TV's alert message body is fixed by the Pine `alert()` call; can't compute a signature inside Pine in a way that's both correct and cacheable.

**Consequences.** Secret is rotated by changing the value in n8n credentials and updating the TradingView alert webhook URL. Workflow JSON is safe to commit credential-stripped — the secret never enters git.

---

## D7 — Schema versioning: hard-fail on unknown `schema_version`

**Context.** Payload schema is `"1.0"`. Future Pine versions may extend the shape.

**Decision.** validateSchema rejects any payload where `schema_version != "1.0"` with a 400 response, until a v2 workflow exists.

**Alternatives considered.**
- Best-effort parse. Rejected: silent breakage is worse than loud breakage.

**Consequences.** A Pine schema bump requires either updating the n8n workflow to accept the new version, or shipping a parallel v2 workflow on a different webhook path.
