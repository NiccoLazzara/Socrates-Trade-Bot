# Socrates Confluence Alert Engine

LPI's mechanical alert pipeline for the Socrates discretionary framework. Converts a six-indicator confluence read into graded JSON alerts, enriches them, persists every event, and pushes high-grade signals to Telegram.

> **Alerts only — no order execution in v1.** The engine flags setups; the trader sizes and executes manually.

## Architecture

```
+-------------------+      +---------------+      +---------------+
| TradingView /     |      |               |      |  Supabase     |
| Pine Script       | ---> |    n8n Cloud  | ---> |  (alerts log, |
| (5m + 1h charts)  | webhook (1) | webhook | enrich |  release_cal) |
+-------------------+      |   workflow    |      +---------------+
                           |               |              |
                           |               | (2) split by grade
                           |               |              |
                           |               | ---> +---------------+
                           |               |      |  Telegram bot |
                           +---------------+      |  (A+ / A / B) |
                                                  +---------------+
```

1. **TradingView → n8n.** Pine Script emits a JSON payload (Appendix A of the spec) via `alert(..., alert.freq_once_per_bar_close)` when a setup fires above the C threshold. The payload hits the n8n webhook.
2. **n8n enriches and routes.**
   - Validates schema, dedupes by `alert_id`.
   - Pulls fresh correlated-symbol state (optional safety check).
   - Writes every event to Supabase `alerts` table (including filtered/low-grade rows for backtest analysis).
   - Branches by `grade`: A+ → high-priority Telegram with @mention; A → standard; B → silent; C → DB only.
3. **Supabase** is the source of truth for the alert log and the lookup store for the daily economic release calendar (`release_calendar`).
4. **Telegram bot** formats the payload into the trader-facing message and posts to a private channel.

## Repo layout

```
socrates-confluence-engine/
├── docs/
│   ├── Socrates_Investments_Playbook.docx   # original playbook
│   ├── socrates_rules_spec.md               # mechanical spec v1.0 — source of truth
│   └── transcripts/                         # source transcripts (00, 01, 02, 04, 05)
├── pine-scripts/
│   └── socrates_confluence_alert_engine_v1.pine
├── n8n-workflows/                           # exported workflow JSON (credential-stripped)
├── supabase/                                # SQL migrations + table definitions
└── telegram-bot/                            # bot source (chat formatter)
```

## Build status

| Component | Status | Notes |
|-----------|--------|-------|
| Rules spec | v1.0 — complete | `docs/socrates_rules_spec.md` |
| Pine Script | v1.0.1 — complete | Setups A, B, C, E. C-grade alerts emitted for Supabase backtest corpus. Setup D (VIX/NQ scalp) deferred to v1.1. |
| n8n workflow | in progress (Chat #3) | Webhook receiver → Supabase log → Telegram split-by-grade |
| Supabase schema | not started | `alerts` and `release_calendar` tables |
| Telegram bot | not started | Bot account not yet created |

## Key references

- Mechanical spec: [`docs/socrates_rules_spec.md`](docs/socrates_rules_spec.md)
- Payload schema (JSON): spec §"Appendix A"
- Confluence grading: spec §9
- Volume veto: spec §10
- Pine source: [`pine-scripts/socrates_confluence_alert_engine_v1.pine`](pine-scripts/socrates_confluence_alert_engine_v1.pine)
- n8n workflow architecture: [`docs/architecture/n8n-workflow.md`](docs/architecture/n8n-workflow.md)
- Design decisions (ADRs): [`docs/decisions/`](docs/decisions/)

## Conventions

- **Source of truth for rule logic** is `docs/socrates_rules_spec.md`. Pine and n8n implementations cite spec sections inline (e.g. `// Spec §3 Setup A`).
- **Payload schema** (`schema_version: "1.0"`) is fixed across Pine → n8n → Supabase → Telegram. Schema bumps require a version increment and a migration plan.
- **`[BUILD DEFAULT]` values** in the spec are starting thresholds, not finalized constants. The 30-day validation phase tunes them.
- **Secrets** never enter the repo — see `.gitignore`. Workflow exports must be credential-stripped before commit.

## Infra

- **n8n:** `lpinvestments.app.n8n.cloud`
- **Supabase:** managed via Supabase MCP
- **Telegram:** bot account TBD (Chat #3)
