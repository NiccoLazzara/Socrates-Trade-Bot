-- ============================================================================
--  Migration 0001 — Socrates Trade Bot initial schema
--  Target project: LPI Website Storage (rotfkasubwpgzlqmlclt)
--  Schema:         socrates (separate namespace, no collision with public.*)
-- ============================================================================
--  Tables:
--    socrates.alerts            — durable log of every Pine alert (all grades)
--    socrates.release_calendar  — economic-release blackout windows for §7d
--
--  Companion docs:
--    docs/architecture/n8n-workflow.md  (schema rationale + access patterns)
--    docs/socrates_rules_spec.md         (Appendix A — payload schema)
-- ============================================================================

create schema if not exists socrates;

comment on schema socrates is
  'Socrates Confluence Alert Engine — trading alert pipeline. See https://github.com/NiccoLazzara/Socrates-Trade-Bot';


-- ============================================================================
--  Table: socrates.alerts
--  One row per Pine Script alert event. Idempotent on alert_id (Pine builds
--  this as ts_utc + symbol + timeframe + setup_type — unique per setup-per-
--  bar-close). Writes happen from n8n on every webhook.
-- ============================================================================

create table socrates.alerts (
  -- Identity / provenance
  alert_id                            text        primary key,
  schema_version                      text        not null,
  ts_utc                              timestamptz not null,
  ts_et                               timestamptz not null,

  -- Instrument + setup
  symbol                              text        not null,
  timeframe                           text        not null,
  setup_type                          text        not null,           -- A | B | C | D | E
  setup_name                          text,

  -- Grading
  grade                               text        not null
                                                  check (grade in ('A+','A','B','C')),
  grade_points                        numeric,

  -- Direction + prices
  direction                           text        check (direction in ('long','short')),
  price                               numeric,
  stop_price                          numeric,
  stop_distance_points                numeric,
  stop_distance_dollars_per_contract  numeric,
  target_1                            numeric,
  target_2                            numeric,
  target_1_dollars_per_contract       numeric,

  -- Structured payload sub-objects (preserved as JSON for query flexibility)
  level                               jsonb,                          -- {type, price, freshness_bars}
  volume                              jsonb,                          -- {bull_pct, bear_pct, bar_volume_vs_20avg, flip_detected}
  confluences                         text[],
  correlation_check                   jsonb,
  session                             jsonb,
  playbook_checklist                  jsonb,
  notes                               text,

  -- n8n-enrichment fields (written after the upsert)
  release_window_check                boolean     default false,
  delivered_to_telegram               boolean     default false,
  telegram_message_id                 bigint,
  received_at                         timestamptz default now()
);

comment on table socrates.alerts is
  'Durable log of every Pine alert (all grades). PK is alert_id for idempotency.';

create index alerts_ts_idx
  on socrates.alerts (ts_utc desc);

create index alerts_symbol_grade_idx
  on socrates.alerts (symbol, grade);


-- ============================================================================
--  Table: socrates.release_calendar
--  Economic release blackout windows. n8n queries on each alert; if the alert
--  ts_et falls within ±15 min of an entry here, the alert is suppressed from
--  Telegram (still written to alerts log). See spec §7d.
-- ============================================================================

create table socrates.release_calendar (
  release_date     date not null,
  release_time_et  time not null,
  event_name       text not null,
  importance       text,                                              -- 'high' | 'medium' | 'low'
  primary key (release_date, release_time_et, event_name)
);

comment on table socrates.release_calendar is
  'Economic release blackout windows for the §7d suppression rule.';

create index release_calendar_dt_idx
  on socrates.release_calendar (release_date);


-- ============================================================================
--  Row-level security
--  Both tables enable RLS with no policies. service_role (which n8n uses)
--  bypasses RLS automatically. anon and authenticated keys have no access.
--  This silences the Supabase RLS advisor while still being secure-by-default.
-- ============================================================================

alter table socrates.alerts            enable row level security;
alter table socrates.release_calendar  enable row level security;


-- ============================================================================
--  Grants
--  Explicit grants for service_role (used by n8n). Future tables in this
--  schema inherit the same grants via default privileges.
-- ============================================================================

grant usage on schema socrates to service_role;

grant all on all tables    in schema socrates to service_role;
grant all on all sequences in schema socrates to service_role;

alter default privileges in schema socrates
  grant all on tables    to service_role;

alter default privileges in schema socrates
  grant all on sequences to service_role;
