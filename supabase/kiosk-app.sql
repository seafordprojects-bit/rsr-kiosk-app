-- ============================================================================================
--  kiosk-app.sql - RSR Kiosk APP (the Android app that replaces Fully Kiosk Browser)
--
--  Adds, for the tablets running the RSR Kiosk app:
--    * kiosk_app_devices : one row per tablet (battery, charging, screen, app build, last seen)
--    * kiosk_app_events  : short log (restarted, updated, office commands)
--    * RPCs for the app  : kiosk_app_beat (every 60 s), kiosk_app_ack
--    * RPCs for the office page (tablets.html), both need the 6-digit ADMIN passcode (checked
--      on the server with the existing admin_verify_passcode):
--        kiosk_app_list, kiosk_app_command
--    * kiosk_app_tick every 5 min: Telegram to the existing "RSR Kiosk Alerts" chat for
--        - NOT CHARGING after 5 min, with battery %; reminder every 30 min (2 h at night) until plugged in
--        - battery dropping while not charging: 50%, 30%, 20% (LOW), 10% (CRITICAL)
--        - charging again, with battery %
--        - OFFLINE: no report for 10 min (6 AM - 10 PM, while the screen schedule has it awake),
--          with the likely reason; reminder every hour; "back online" with what the tablet reported
--        - HOT: battery 45 C or more
--        - GENERATOR (Carmen): with generator hours set, NOT CHARGING is only judged while the generator
--          should run (from 20 min after its start); during breaks, night and optional overtime ("+24:00")
--          only "may run out before the generator is back" and 10% CRITICAL
--  UPGRADE: this whole file is safe to run again over an older version (adds columns, replaces functions).
--        - tablet restarted / app updated / maintenance opened / update failed
--      It reuses kiosk_alert_send (kiosk-alerts.sql). The older "tablet silent" alert (30 min, from the
--      kiosk page, kiosk-alerts.sql) is left untouched on purpose (owner informed 2026-11-03): a long
--      outage gives the app's OFFLINE at 10 min and that older message at 30 min.
--
--  ADDITIVE + IDEMPOTENT. Touches no existing table, function or cron job. Free-tier friendly.
--  Rollback: kiosk-app-rollback.sql. ASCII only (safe to paste from Windows).
-- ============================================================================================

-- STEP 0 - CENSUS (read-only). Run first. Make sure this is the kiosk/payroll project.
select current_database();
select count(*) from public.attendance_records;                        -- canary: errors in the wrong project
select extname from pg_extension where extname in ('pg_cron','pg_net'); -- expect both
select to_regprocedure('public.kiosk_alert_send(text)')       as alert_send,      -- expect not null
       to_regprocedure('public.admin_verify_passcode(text)')  as admin_verify,    -- expect not null
       to_regclass('public.kiosk_app_devices')                as devices_before;  -- expect null on first run
-- build-6: triggers on the tablet table (an audit trigger would copy a Set Wi-Fi password into its log). Expect 0 rows.
select tgname from pg_trigger where tgrelid = to_regclass('public.kiosk_app_devices') and not tgisinternal;

-- STEP 1 - tables (REST-locked: only the functions below touch them)
create table if not exists public.kiosk_app_devices (
  device_id         text primary key,          -- "app-" + Android ID
  name              text,                      -- e.g. "Carmen kiosk"
  kiosk_device_id   text,                      -- the kiosk PAGE id (kiosk_health.device_id) on the same tablet
  model             text,
  app_version       integer,
  battery           integer,
  charging          boolean,
  screen_on         boolean,
  device_owner      boolean,
  maintenance       boolean,
  page_url          text,
  page_ok           boolean,
  sched_on          text,
  sched_off         text,
  first_seen        timestamptz not null default now(),
  last_seen         timestamptz not null default now(),
  unplugged_since   timestamptz,
  low_batt_alerted  boolean not null default false,
  unplugged_alerted boolean not null default false,
  cmd_id            bigint,
  cmd               text,
  cmd_arg           text,
  cmd_at            timestamptz,
  cmd_done_id       bigint,
  cmd_result        text,
  cmd_done_at       timestamptz
);
revoke all on public.kiosk_app_devices from anon, authenticated;
-- not-charging reminders + battery-drop steps (2026-10-28)
alter table public.kiosk_app_devices add column if not exists unplugged_alerted_at timestamptz;
alter table public.kiosk_app_devices add column if not exists batt_step integer not null default 100;
-- Wi-Fi / offline / heat (2026-11-03)
alter table public.kiosk_app_devices add column if not exists wifi               boolean;
alter table public.kiosk_app_devices add column if not exists internet           boolean;
alter table public.kiosk_app_devices add column if not exists wifi_signal        integer;
alter table public.kiosk_app_devices add column if not exists battery_temp       numeric(4,1);
alter table public.kiosk_app_devices add column if not exists last_outage        jsonb;
alter table public.kiosk_app_devices add column if not exists offline_alerted_at timestamptz;
alter table public.kiosk_app_devices add column if not exists offline_first_at   timestamptz;
alter table public.kiosk_app_devices add column if not exists hot_alerted        boolean not null default false;
-- Generator hours (Carmen runs on a generator; 2026-11-03). Null = normal grid power, always on.
-- Format "08:00-11:30,13:00-16:30,18:00-21:00" (Manila time). Set on the Tablets page.
alter table public.kiosk_app_devices add column if not exists power_windows      text;
alter table public.kiosk_app_devices add column if not exists risk_alerted_for   timestamptz;
-- Measured battery drain (%/hour) with the screen on and off, learned from this tablet's own reports,
-- so "may run out" uses real numbers instead of an estimate. Anchor = start of the current measurement.
alter table public.kiosk_app_devices add column if not exists drain_on           numeric(5,2);
alter table public.kiosk_app_devices add column if not exists drain_off          numeric(5,2);
alter table public.kiosk_app_devices add column if not exists drain_on_n         integer not null default 0;
alter table public.kiosk_app_devices add column if not exists drain_off_n        integer not null default 0;
alter table public.kiosk_app_devices add column if not exists drain_anchor_at    timestamptz;
alter table public.kiosk_app_devices add column if not exists drain_anchor_batt  integer;
alter table public.kiosk_app_devices add column if not exists drain_anchor_screen boolean;
-- Security + weak charger (2026-11-03 review)
alter table public.kiosk_app_devices add column if not exists token             text;   -- secret given to the tablet on its first report
alter table public.kiosk_app_devices add column if not exists token_confirmed   boolean not null default false;   -- the tablet sent it back once
alter table public.kiosk_app_devices add column if not exists charge_state      text;   -- charging / full / discharging / not_charging
alter table public.kiosk_app_devices add column if not exists weak_since        timestamptz;
alter table public.kiosk_app_devices add column if not exists weak_alerted      boolean not null default false;
-- what the kiosk page shows (2026-11-04): its version stamp, its last error, and when the last screenshot came
alter table public.kiosk_app_devices add column if not exists page_version      text;
alter table public.kiosk_app_devices add column if not exists page_error        text;
alter table public.kiosk_app_devices add column if not exists page_error_at     timestamptz;
alter table public.kiosk_app_devices add column if not exists shot_at           timestamptz;
-- Roll-call PHONE (2026-11-12): remembered, so a phone briefly showing another page (or no page yet,
-- page_url empty) is never mistaken for a tablet. Set by kiosk_app_tick from the page address.
alter table public.kiosk_app_devices add column if not exists phone_mode        boolean not null default false;

-- latest screenshot of each tablet's kiosk screen (one row per tablet, overwritten; JPEG as base64 text).
-- REST-locked: only kiosk_app_shot_put (tablet, with its secret) and kiosk_app_shot_get (admin passcode).
create table if not exists public.kiosk_app_shots (
  device_id  text primary key,
  taken_at   timestamptz not null default now(),
  jpeg       text not null
);
revoke all on public.kiosk_app_shots from anon, authenticated;

create table if not exists public.kiosk_app_events (
  id         bigserial primary key,
  device_id  text not null,
  event      text not null,
  at         timestamptz not null default now(),
  notified   boolean not null default false
);
create index if not exists kiosk_app_events_dev_at on public.kiosk_app_events (device_id, at desc);
revoke all on public.kiosk_app_events from anon, authenticated;

-- BUILD-6 (2026-11-16): connection type + Wi-Fi downtime, SIM + mobile data, telco texts, load records.
alter table public.kiosk_app_devices add column if not exists net_type          text;          -- wifi / mobile / none
alter table public.kiosk_app_devices add column if not exists net_since         timestamptz;   -- when the current net_type started
alter table public.kiosk_app_devices add column if not exists mobile_alerted    boolean not null default false;
alter table public.kiosk_app_devices add column if not exists mobile_signal     integer;       -- 0-4
alter table public.kiosk_app_devices add column if not exists mobile_ok         boolean;       -- mobile data works (null = no SIM data network)
alter table public.kiosk_app_devices add column if not exists mobile_bad_since  timestamptz;
alter table public.kiosk_app_devices add column if not exists mobile_bad_alerted boolean not null default false;
alter table public.kiosk_app_devices add column if not exists sim_operator      text;          -- what the SIM says (e.g. DITO, GOMO)
alter table public.kiosk_app_devices add column if not exists sim_state         text;          -- ready / absent / locked / unknown
alter table public.kiosk_app_devices add column if not exists sms_ok            boolean;       -- the app may read incoming texts
alter table public.kiosk_app_devices add column if not exists sim_provider      text;          -- set by the owner: DITO / GOMO / ...
alter table public.kiosk_app_devices add column if not exists sim_close_days    integer;       -- number closes after this many days without a load
alter table public.kiosk_app_devices add column if not exists sim_alerts        jsonb not null default '{}'::jsonb;  -- reminders already sent
alter table public.kiosk_app_devices add column if not exists load_wait_from    timestamptz;   -- owner pressed "I just loaded"
alter table public.kiosk_app_devices add column if not exists battery_unrestricted boolean;     -- Samsung battery "Unrestricted" (night check-ins need it)

-- Wi-Fi downtime: one row per period the tablet was NOT on Wi-Fi (on mobile data, or offline).
create table if not exists public.kiosk_app_conn (
  id          bigserial primary key,
  device_id   text not null,
  kind        text not null check (kind in ('mobile','none','offline')),
  started_at  timestamptz not null,
  ended_at    timestamptz,
  reason      text
);
create index if not exists kiosk_app_conn_dev on public.kiosk_app_conn (device_id, started_at desc);
revoke all on public.kiosk_app_conn from public, anon, authenticated;
alter table public.kiosk_app_conn enable row level security;   -- default closed (data exposure rule 2026-11-16)

-- mobile data used per day (bytes, Android's own counter), for "used since the last load"
create table if not exists public.kiosk_app_data_days (
  device_id  text not null,
  day        date not null,
  bytes      bigint not null default 0,
  primary key (device_id, day)
);
revoke all on public.kiosk_app_data_days from public, anon, authenticated;
alter table public.kiosk_app_data_days enable row level security;   -- default closed (data exposure rule 2026-11-16)

-- texts from the telco to the tablet's SIM (personal numbers are never sent by the app)
create table if not exists public.kiosk_app_sms (
  id           bigserial primary key,
  device_id    text not null,
  sender       text not null,
  body         text not null,
  received_at  timestamptz not null default now(),
  kind         text not null default 'other',   -- load / expiring / expired / low / other
  notified     boolean not null default false,
  load_id      bigint
);
create index if not exists kiosk_app_sms_dev on public.kiosk_app_sms (device_id, received_at desc);
alter table public.kiosk_app_sms add column if not exists created_at timestamptz not null default now();   -- server receive time
revoke all on public.kiosk_app_sms from public, anon, authenticated;
alter table public.kiosk_app_sms enable row level security;   -- default closed (data exposure rule 2026-11-16)

-- SIM loads (history, never overwritten): from a telco text, a screenshot, or typed by the owner
create table if not exists public.kiosk_app_loads (
  id          bigserial primary key,
  device_id   text not null,
  provider    text,
  promo       text,
  gb          numeric(7,2),
  load_date   date not null,
  expires_on  date,
  source      text not null check (source in ('text','screenshot','typed')),
  sms_id      bigint,
  created_at  timestamptz not null default now()
);
create index if not exists kiosk_app_loads_dev on public.kiosk_app_loads (device_id, load_date desc, id desc);
revoke all on public.kiosk_app_loads from public, anon, authenticated;
alter table public.kiosk_app_loads enable row level security;   -- default closed (data exposure rule 2026-11-16)

-- screenshot proof of the latest load per tablet (JPEG base64; older ones are removed)
create table if not exists public.kiosk_app_load_shots (
  load_id    bigint primary key,
  device_id  text not null,
  jpeg       text not null
);
revoke all on public.kiosk_app_load_shots from public, anon, authenticated;
alter table public.kiosk_app_load_shots enable row level security;   -- default closed (data exposure rule 2026-11-16)

create sequence if not exists public.kiosk_app_cmd_seq;
revoke all on sequence public.kiosk_app_cmd_seq from anon, authenticated;

-- text -> timestamptz, or null when it is not a real UTC time (a bad value must never break the heartbeat)
create or replace function public.kiosk_app_ts(p text)
returns timestamptz language plpgsql immutable as $$
begin
  if p !~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' then return null; end if;
  return p::timestamptz;
exception when others then
  return null;
end $$;
revoke all on function public.kiosk_app_ts(text) from public, anon, authenticated;

-- BUILD-6: what a telco text is about. Wording differs per telco and changes, so this only sorts the text
-- (load / expiring / expired / low / other) and picks out GB, days and a valid-until date when it can.
-- The owner sees the full text on the Tablets page and can correct a load by hand.
create or replace function public.kiosk_app_sms_kind(p_body text)
returns text language sql immutable as $$
  select case
    -- a one-time code (OTP) for the telco app: shown on the Tablets page for 15 minutes only, never on Telegram,
    -- never kept (owner 2026-11-16: the SIM sits in the kiosk, the code is needed to sign in to the DITO / GOMO app)
    -- the number must sit right next to the code words ("OTP is 482913", "482913 is your code"); a load or expiry text
    -- that only ends with "never share your OTP" is NOT a code (review 2026-11-16)
    when (p_body ~* '(otp|one-?time (pin|password|code)|verification code|security code|\mcode|\mpin)[^0-9]{0,25}\m[0-9]{4,8}\M'
          or p_body ~* '\m[0-9]{4,8}\M[^0-9]{0,6}(is|as) your[^0-9.]{0,20}(otp|code|pin)')
         and p_body !~* '(successfully|registered|subscribed|purchased|reloaded|valid until|valid till|expire|expiring|\mgb\M|\mmb\M)' then 'otp'
    -- ads and freebies are never a load or an alert (review 2026-11-16): "Get 50GB! valid until...", "You received 1GB FREE",
    -- pasaload / share-a-load from a person, gifts. They stay on the Tablets page only.
    when p_body ~* '(\mfree\M|freebie|\mbonus\M|\mgift|pasaload|share-?a-?load|from (\+?63|0)9[0-9]|\mdial\M|\*[0-9]{2,4}#|register now|avail now|\mget [0-9]+\s*gb|\mbuy now|\moffer\M|limited time|until supplies)' then 'other'
    when p_body ~* '\myour\M[^.]{0,80}(has expired|have expired|is expired|already expired|expired na|nag-?expire na)' then 'expired'
    when p_body ~* '(you have (successfully )?(registered|subscribed|purchased|bought|loaded|reloaded)|successfully (registered|subscribed|purchased|loaded|reloaded)|registration .*successful|you are now (registered|subscribed)|thank you for (loading|reloading|purchasing|subscribing|registering))'
         and p_body ~* '([0-9]+(\.[0-9]+)?\s*(gb|mb)|data|valid|day|expir|promo)' then 'load'
    when p_body ~* '\myour\M[^.]{0,80}(will expire|expiring|expires (on|in|today|tomorrow)|valid until|valid till)' then 'expiring'
    when p_body ~* '\myour\M[^.]{0,80}(running low|is low|low data|only [0-9.]+\s*(gb|mb).* left|remaining (data|balance).* [0-9.]+\s*(gb|mb)|used up|consumed)' then 'low'
    else 'other' end
$$;
revoke all on function public.kiosk_app_sms_kind(text) from public, anon, authenticated;

-- first date in text: "Dec 16, 2026" / "16 Dec 2026" / "12/16/2026" (PH month first) / "2026-12-16"; null if none
create or replace function public.kiosk_app_text_date(p text)
returns date language plpgsql immutable as $$
declare m text[]; mon int;
begin
  if p is null then return null; end if;
  m := regexp_match(p, '(20[0-9]{2})-([0-9]{1,2})-([0-9]{1,2})');
  if m is not null then return make_date(m[1]::int, m[2]::int, m[3]::int); end if;
  m := regexp_match(lower(p), '(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+([0-9]{1,2})(st|nd|rd|th)?,?\s+(20[0-9]{2})');
  if m is not null then
    mon := array_position(array['jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec'], m[1]);
    return make_date(m[4]::int, mon, m[2]::int);
  end if;
  m := regexp_match(lower(p), '([0-9]{1,2})(st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?\s+(20[0-9]{2})');
  if m is not null then
    mon := array_position(array['jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec'], m[3]);
    return make_date(m[4]::int, mon, m[1]::int);
  end if;
  m := regexp_match(p, '([0-9]{1,2})/([0-9]{1,2})/(20[0-9]{2})');
  if m is not null then return make_date(m[3]::int, m[1]::int, m[2]::int); end if;
  return null;
exception when others then
  return null;   -- 02/30/2026 and the like: no date rather than an error
end $$;
revoke all on function public.kiosk_app_text_date(text) from public, anon, authenticated;

-- GB, days and valid-until out of a load text. p_on = the day the text came (Manila).
create or replace function public.kiosk_app_parse_load(p_body text, p_on date)
returns jsonb language plpgsql immutable as $$
declare v_gb numeric; v_days int; v_until date; m text[]; v_after text;
begin
  select max(x[1]::numeric) into v_gb from regexp_matches(coalesce(p_body,''), '([0-9]+(\.[0-9]+)?)\s*GB', 'gi') x;
  if v_gb is null then
    select max(x[1]::numeric) / 1024.0 into v_gb from regexp_matches(coalesce(p_body,''), '([0-9]+(\.[0-9]+)?)\s*MB', 'gi') x;
  end if;
  m := regexp_match(coalesce(p_body,''), '([0-9]{1,3})\s*(-\s*)?days?', 'i');
  if m is not null then v_days := m[1]::int; end if;
  v_after := (regexp_match(coalesce(p_body,''), '(valid until|valid till|valid thru|valid through|until|till|expires on|expiring on|expiry|expire on|exp\.?)(.*)$', 'i'))[2];
  v_until := public.kiosk_app_text_date(v_after);
  if v_until is not null and (v_until < p_on or v_until > p_on + 800) then v_until := null; end if;
  if v_until is null and v_days between 1 and 800 then v_until := p_on + v_days; end if;
  return jsonb_build_object('gb', case when v_gb between 0.01 and 99999 then round(v_gb, 2) end,
                            'days', v_days, 'expires_on', v_until);
end $$;
revoke all on function public.kiosk_app_parse_load(text, date) from public, anon, authenticated;

-- STEP 2 - heartbeat from the app (anon). Returns the pending office command, if any.
create or replace function public.kiosk_app_beat(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_id   text := btrim(coalesce(p->>'device_id',''));
  v_chg  boolean := (p->>'charging')::boolean;
  v_ev   text := left(btrim(coalesce(p->>'event','')), 120);
  v_out  jsonb := case when jsonb_typeof(p->'outage') = 'object' then p->'outage' end;
  v_otxt text;
  v_prev timestamptz;
  v_tok  text;
  v_new  text;
  v_name text := regexp_replace(left(btrim(coalesce(p->>'name','')), 40), '[^[:alnum:] ._-]', '', 'g');
  v_conf boolean;
  v_cs   text := case when p->>'charge_state' in ('charging','full','discharging','not_charging') then p->>'charge_state' end;
  d      public.kiosk_app_devices%rowtype;
  v_nt   text := case when p->>'net_type' in ('wifi','mobile','none') then p->>'net_type' end;
  v_old_nt text;
  v_mok  boolean := case when jsonb_typeof(p->'mobile_ok') = 'boolean' then (p->>'mobile_ok')::boolean end;
  v_day  text;
  v_today date := (now() at time zone 'Asia/Manila')::date;
begin
  if v_id !~ '^app-[A-Za-z0-9]{1,64}$' then return '{}'::jsonb; end if;
  -- Only exact app messages go into the log (they end up in Telegram); anything else is dropped.
  if v_ev !~ '^(started|setup done|tablet restarted|maintenance opened|maintenance ended \(auto\)|page crashed, rebuilt|page froze, reloaded|reload \(settings\)|full reload \(settings\)|updated to build [0-9]{1,6}|installing build [0-9]{1,6}|update install failed: -?[0-9]{1,3}|screen on failed|screen on needed a second try|screen woken by phone call)$' then
    v_ev := '';
  end if;
  -- TOKEN: the first report of a tablet gets a secret. Until the tablet has sent it back once
  -- (confirmed), a report WITHOUT a secret is still accepted and the secret is sent again - so a lost
  -- first reply can never lock the tablet out. After that, every report must carry it: someone who only
  -- knows the public key and a tablet id cannot pretend to be that tablet.
  select k.token, k.token_confirmed into v_tok, v_conf from public.kiosk_app_devices k where k.device_id = v_id;
  if v_tok is not null then
    if (p->>'token') = v_tok then
      if not v_conf then update public.kiosk_app_devices k set token_confirmed = true where k.device_id = v_id; end if;
    elsif not v_conf and coalesce(p->>'token', '') = '' then
      v_new := v_tok;                       -- not confirmed yet: send the same secret again
    else
      return jsonb_build_object('error', 'token');
    end if;
  end if;
  -- spam guard: at most 20 tablets ever register
  if not exists (select 1 from public.kiosk_app_devices x where x.device_id = v_id)
     and (select count(*) from public.kiosk_app_devices) >= 20 then
    return '{}'::jsonb;
  end if;

  if v_tok is null then
    v_new := gen_random_uuid()::text;
    insert into public.kiosk_app_devices as k (device_id, token) values (v_id, v_new)
    on conflict (device_id) do update set token = excluded.token where k.token is null;
  end if;
  select k.last_seen, k.net_type into v_prev, v_old_nt from public.kiosk_app_devices k where k.device_id = v_id;

  update public.kiosk_app_devices k set
    name            = coalesce(nullif(v_name, ''), k.name),
    kiosk_device_id = left(coalesce(nullif(btrim(p->>'kiosk_device_id'),''), k.kiosk_device_id), 80),
    model           = left(p->>'model', 120),
    app_version     = nullif(p->>'app_version','')::integer,
    battery         = nullif(p->>'battery','')::integer,
    charging        = v_chg,
    charge_state    = v_cs,
    -- plugged in but losing charge (weak charger / bad cable); 'not_charging' at 80%+ is Protect battery
    weak_since      = case when v_chg is true and (v_cs = 'discharging' or (v_cs = 'not_charging' and nullif(p->>'battery','')::integer < 80))
                           then coalesce(k.weak_since, now()) else null end,
    screen_on       = (p->>'screen_on')::boolean,
    device_owner    = (p->>'device_owner')::boolean,
    maintenance     = (p->>'maintenance')::boolean,
    page_url        = left(p->>'page_url', 300),
    page_ok         = (p->>'page_ok')::boolean,
    sched_on        = case when p->>'sched_on'  ~ '^[0-2][0-9]:[0-5][0-9]$' then p->>'sched_on'  end,
    sched_off       = case when p->>'sched_off' ~ '^[0-2][0-9]:[0-5][0-9]$' then p->>'sched_off' end,
    wifi            = (p->>'wifi')::boolean,
    internet        = (p->>'internet')::boolean,
    wifi_signal     = case when p->>'wifi_signal' ~ '^[0-4]$' then (p->>'wifi_signal')::integer end,
    battery_temp    = case when p->>'battery_temp' ~ '^-?[0-9]{1,2}(\.[0-9])?$' then (p->>'battery_temp')::numeric end,
    -- the kiosk page's own version stamp (e.g. v2026-10-16d); anything else keeps the last good one
    page_version    = case when p->>'page_version' ~ '^v[0-9]{4}-[0-9]{2}-[0-9]{2}[a-z]?$' then p->>'page_version' else k.page_version end,
    -- the page's LAST error (kept until a newer one comes); no HTML, at most 300 characters
    page_error      = case when btrim(coalesce(p->>'page_error','')) <> ''
                           then left(regexp_replace(p->>'page_error', '[<>]', '', 'g'), 300) else k.page_error end,
    page_error_at   = case when btrim(coalesce(p->>'page_error','')) <> ''
                           then coalesce(least(public.kiosk_app_ts(p->>'page_error_at'), now()), now())
                           else k.page_error_at end,
    net_type        = coalesce(v_nt, k.net_type),
    net_since       = case when v_nt is not null and v_nt is distinct from k.net_type then now() else k.net_since end,
    mobile_signal   = case when p->>'mobile_signal' ~ '^[0-4]$' then (p->>'mobile_signal')::integer end,
    mobile_ok       = case when p ? 'mobile_ok' then v_mok else k.mobile_ok end,
    mobile_bad_since = case when not (p ? 'mobile_ok') then k.mobile_bad_since
                            when v_mok is false then coalesce(k.mobile_bad_since, now()) else null end,
    sim_operator    = case when p ? 'sim_operator' then nullif(left(regexp_replace(coalesce(p->>'sim_operator',''), '[^[:alnum:] ._-]', '', 'g'), 40), '') else k.sim_operator end,
    sim_state       = case when p->>'sim_state' in ('ready','absent','locked','unknown') then p->>'sim_state' else k.sim_state end,
    sms_ok          = case when jsonb_typeof(p->'sms_ok') = 'boolean' then (p->>'sms_ok')::boolean else k.sms_ok end,
    battery_unrestricted = case when jsonb_typeof(p->'battery_unrestricted') = 'boolean' then (p->>'battery_unrestricted')::boolean else k.battery_unrestricted end,
    last_seen       = now(),
    unplugged_since = case when v_chg is false then coalesce(k.unplugged_since, now()) else null end
  where k.device_id = v_id
  returning * into d;

  -- event log, flood-guarded: same event within 60 s is dropped; max 20 events per tablet per hour
  if v_ev <> '' and v_ev <> 'started'
     and not exists (select 1 from public.kiosk_app_events x
                      where x.device_id = v_id and x.event = v_ev
                        and x.at > now() - case when v_ev = 'screen woken by phone call' then interval '15 seconds'   -- every call
                                                else interval '60 seconds' end)
     and (select count(*) from public.kiosk_app_events x
           where x.device_id = v_id and x.at > now() - interval '1 hour') < 20 then
    insert into public.kiosk_app_events (device_id, event) values (v_id, v_ev);
  end if;

  -- DRAIN LEARNING. A measurement runs while the tablet is on battery with the screen in one state.
  -- It ends when the screen state changes, charging starts, or the battery has dropped 5 points; if it
  -- lasted at least 20 min and dropped at least 2 points, it updates the average (70% old / 30% new).
  if d.charging is false and d.battery is not null then
    if d.drain_anchor_at is null then
      update public.kiosk_app_devices k set drain_anchor_at = now(), drain_anchor_batt = d.battery,
             drain_anchor_screen = d.screen_on where k.device_id = v_id;
    elsif d.screen_on is distinct from d.drain_anchor_screen or d.drain_anchor_batt - d.battery >= 5
          or (d.drain_anchor_screen and v_prev < now() - interval '15 minutes') then
      -- a gap in reports while the screen was ON (tablet slept / no Wi-Fi) makes the screen-on figure
      -- unreliable: that measurement is dropped. A gap with the screen OFF is the normal night sleep.
      if now() - d.drain_anchor_at >= interval '20 minutes' and d.drain_anchor_batt - d.battery >= 2
         and not (d.drain_anchor_screen and v_prev < now() - interval '15 minutes') then
        if d.drain_anchor_screen then
          update public.kiosk_app_devices k set
            drain_on = round(case when k.drain_on is null then x.r else k.drain_on * 0.7 + x.r * 0.3 end, 2),
            drain_on_n = k.drain_on_n + 1
          from (select least(60, (d.drain_anchor_batt - d.battery) / (extract(epoch from now() - d.drain_anchor_at) / 3600.0)) as r) x
          where k.device_id = v_id;
        else
          update public.kiosk_app_devices k set
            drain_off = round(case when k.drain_off is null then x.r else k.drain_off * 0.7 + x.r * 0.3 end, 2),
            drain_off_n = k.drain_off_n + 1
          from (select least(60, (d.drain_anchor_batt - d.battery) / (extract(epoch from now() - d.drain_anchor_at) / 3600.0)) as r) x
          where k.device_id = v_id;
        end if;
      end if;
      update public.kiosk_app_devices k set drain_anchor_at = now(), drain_anchor_batt = d.battery,
             drain_anchor_screen = d.screen_on where k.device_id = v_id;
    end if;
  elsif d.drain_anchor_at is not null then
    update public.kiosk_app_devices k set drain_anchor_at = null, drain_anchor_batt = null, drain_anchor_screen = null
     where k.device_id = v_id;
  end if;

  -- The tablet just came back and tells us how long it was cut off, and why (no Wi-Fi, no internet,
  -- server not reachable). Kept for the "back online" message and the Tablets page.
  if v_out is not null and v_out->>'reason' in ('Wi-Fi off / not connected', 'Wi-Fi connected but no internet',
                                               'internet OK but server not reachable')
     and v_out->>'minutes' ~ '^[0-9]{1,5}$' then
    v_otxt := 'was offline ' || (v_out->>'minutes') || ' min: ' || (v_out->>'reason');
    update public.kiosk_app_devices k set last_outage = jsonb_build_object(
             'minutes', (v_out->>'minutes')::integer, 'reason', v_out->>'reason', 'reported_at', now())
     where k.device_id = v_id;
    if not exists (select 1 from public.kiosk_app_events x
                    where x.device_id = v_id and x.event = v_otxt and x.at > now() - interval '10 minutes') then
      insert into public.kiosk_app_events (device_id, event, notified) values (v_id, v_otxt, true);
    end if;
  end if;

  -- BUILD-6 Wi-Fi downtime: a period starts when the tablet leaves Wi-Fi and ends when it is back on Wi-Fi.
  if v_nt is not null and v_nt is distinct from v_old_nt then
    update public.kiosk_app_conn c set ended_at = now()
     where c.device_id = v_id and c.ended_at is null and c.kind in ('mobile','none');
    if v_nt in ('mobile','none') then
      insert into public.kiosk_app_conn (device_id, kind, started_at) values (v_id, v_nt, now());
    end if;
  end if;
  -- an outage the tablet reports when it is back (no report reached us): a closed 'offline' period
  if v_out is not null and v_out->>'minutes' ~ '^[0-9]{1,5}$' and (v_out->>'minutes')::int >= 2
     and v_out->>'reason' in ('Wi-Fi off / not connected', 'Wi-Fi connected but no internet', 'internet OK but server not reachable')
     and not exists (select 1 from public.kiosk_app_conn c where c.device_id = v_id and c.kind = 'offline'
                       and c.ended_at > now() - interval '5 minutes') then
    insert into public.kiosk_app_conn (device_id, kind, started_at, ended_at, reason)
    values (v_id, 'offline', now() - make_interval(mins => least((v_out->>'minutes')::int, 20000)), now(), v_out->>'reason');
  end if;
  -- mobile data used per day (Android's counter for that day; only today and the 2 days before)
  if jsonb_typeof(p->'mobile_days') = 'object' then
    for v_day in select jsonb_object_keys(p->'mobile_days') loop
      continue when v_day !~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}$' or (p->'mobile_days'->>v_day) !~ '^[0-9]{1,13}$';
      continue when public.kiosk_app_text_date(v_day) is null or public.kiosk_app_text_date(v_day) not between v_today - 2 and v_today;
      insert into public.kiosk_app_data_days as x (device_id, day, bytes) values (v_id, public.kiosk_app_text_date(v_day), (p->'mobile_days'->>v_day)::bigint)
      on conflict (device_id, day) do update set bytes = greatest(x.bytes, excluded.bytes);
    end loop;
  end if;

  if d.cmd_id is not null and d.cmd_id > coalesce(d.cmd_done_id, 0)
     and d.cmd_at > now() - interval '30 minutes'   -- an old, never-picked-up command expires
     and (d.cmd <> 'set_wifi' or d.token_confirmed) then   -- a Wi-Fi password only to a tablet that proved its secret
    return jsonb_build_object('cmd_id', d.cmd_id, 'cmd', d.cmd, 'arg', coalesce(d.cmd_arg,''))
           || case when v_new is not null then jsonb_build_object('token', v_new) else '{}'::jsonb end;
  end if;
  return case when v_new is not null then jsonb_build_object('token', v_new) else '{}'::jsonb end;
end $$;
revoke all on function public.kiosk_app_beat(jsonb) from public;
grant execute on function public.kiosk_app_beat(jsonb) to anon, authenticated;

-- STEP 3 - the app confirms a command (with its secret)
drop function if exists public.kiosk_app_ack(text, bigint, text);
create or replace function public.kiosk_app_ack(p_device text, p_token text, p_cmd_id bigint, p_result text)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  update public.kiosk_app_devices k
     set cmd_done_id = greatest(coalesce(k.cmd_done_id,0), p_cmd_id),
         cmd_result  = left(regexp_replace(coalesce(p_result,''), '[<>]', '', 'g'), 200),
         cmd_done_at = now(),
         -- a Wi-Fi password never stays on the server once the tablet has it
         cmd_arg     = case when k.cmd = 'set_wifi' then null else k.cmd_arg end
   where k.device_id = p_device and k.token = p_token and k.cmd_id = p_cmd_id;
end $$;
revoke all on function public.kiosk_app_ack(text, text, bigint, text) from public;
grant execute on function public.kiosk_app_ack(text, text, bigint, text) to anon, authenticated;

-- STEP 3b - office page: forget a tablet (admin passcode), e.g. after a factory reset or reinstall, so it
-- can register again with a new secret. Its settings (generator hours) must then be set again.
create or replace function public.kiosk_app_forget(p_passcode text, p_device text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.admin_verify_passcode(p_passcode) then
    return jsonb_build_object('error', 'wrong passcode');
  end if;
  delete from public.kiosk_app_devices k where k.device_id = p_device;
  if not found then return jsonb_build_object('error', 'tablet not found'); end if;
  delete from public.kiosk_app_shots s where s.device_id = p_device;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.kiosk_app_forget(text, text) from public;
grant execute on function public.kiosk_app_forget(text, text) to anon, authenticated;

-- BUILD-6 minutes NOT on Wi-Fi (mobile data or offline) since p_from, open period counted up to now
create or replace function public.kiosk_app_down_min(p_device text, p_from timestamptz)
returns integer language sql stable as $$
  -- periods may overlap (on mobile data, then an outage reported for the same time): counted once (range union).
  -- An open period stops counting 2 min after the tablet's last report (a silent tablet is not "on mobile").
  select coalesce(round(sum(extract(epoch from (upper(r) - lower(r)))) / 60.0)::int, 0)
    from (select unnest(range_agg(tstzrange(greatest(c.started_at, p_from), e.t))) r
            from public.kiosk_app_conn c
            cross join lateral (select least(coalesce(c.ended_at,
                     (select d.last_seen + interval '2 minutes' from public.kiosk_app_devices d where d.device_id = c.device_id), now()), now()) t) e
           where c.device_id = p_device and e.t > greatest(c.started_at, p_from)) x
$$;
revoke all on function public.kiosk_app_down_min(text, timestamptz) from public, anon, authenticated;

-- BUILD-6 SIM card of a tablet: provider, latest load, data used since it, expiry, closing date, last texts
create or replace function public.kiosk_app_sim_info(p_device text)
returns jsonb language plpgsql stable as $$
declare d public.kiosk_app_devices%rowtype; l public.kiosk_app_loads%rowtype; v_used bigint; v_today date := (now() at time zone 'Asia/Manila')::date;
begin
  select * into d from public.kiosk_app_devices k where k.device_id = p_device;
  select * into l from public.kiosk_app_loads x where x.device_id = p_device order by x.load_date desc, x.id desc limit 1;
  select coalesce(sum(x.bytes), 0) into v_used from public.kiosk_app_data_days x
   where x.device_id = p_device and x.day >= coalesce(l.load_date, v_today);
  return jsonb_build_object(
    'provider', d.sim_provider, 'close_days', d.sim_close_days, 'operator', d.sim_operator, 'state', d.sim_state,
    'sms_ok', d.sms_ok, 'load_wait_from', d.load_wait_from,
    'data_today_mb', (select round(x.bytes / 1048576.0) from public.kiosk_app_data_days x where x.device_id = p_device and x.day = v_today),
    'load', case when l.id is null then null else jsonb_build_object(
              'id', l.id, 'provider', l.provider, 'promo', l.promo, 'gb', l.gb, 'load_date', l.load_date,
              'expires_on', l.expires_on, 'source', l.source, 'days_left', l.expires_on - v_today,
              'used_mb', round(v_used / 1048576.0),
              'has_shot', exists (select 1 from public.kiosk_app_load_shots s where s.load_id = l.id)) end,
    'closes_on', case when d.sim_close_days is not null and l.id is not null then l.load_date + d.sim_close_days end,
    'loads', (select coalesce(jsonb_agg(jsonb_build_object('load_date', x.load_date, 'expires_on', x.expires_on, 'gb', x.gb,
                                                           'promo', x.promo, 'source', x.source) order by x.load_date desc, x.id desc), '[]'::jsonb)
                from (select * from public.kiosk_app_loads y where y.device_id = p_device order by y.load_date desc, y.id desc limit 5) x),
    'texts', (select coalesce(jsonb_agg(jsonb_build_object('from', x.sender, 'body', x.body, 'at', x.received_at, 'kind', x.kind)
                                        order by x.received_at desc), '[]'::jsonb)
                from (select * from public.kiosk_app_sms y where y.device_id = p_device and y.kind <> 'otp'
                       order by y.received_at desc limit 5) x),
    'otp', (select jsonb_build_object('from', x.sender, 'body', x.body, 'at', x.created_at,
                                      'code', coalesce((regexp_match(x.body, '(otp|one-?time (pin|password|code)|verification code|security code|\mcode|\mpin)[^0-9]{0,25}\m([0-9]{4,8})\M', 'i'))[3],
                                                       (regexp_match(x.body, '\m([0-9]{4,8})\M[^0-9]{0,6}(is|as) your', 'i'))[1]))
              from public.kiosk_app_sms x where x.device_id = p_device and x.kind = 'otp'
               and x.created_at > now() - interval '15 minutes' order by x.created_at desc limit 1));
end $$;
revoke all on function public.kiosk_app_sim_info(text) from public, anon, authenticated;

-- STEP 4 - office page: list tablets (admin passcode)
create or replace function public.kiosk_app_list(p_passcode text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v jsonb;
begin
  -- Return (never raise) on a wrong passcode: raising would roll back the wrong-try counter
  -- inside admin_verify_passcode and remove its brute-force lockout.
  if not public.admin_verify_passcode(p_passcode) then
    return jsonb_build_object('error', 'wrong passcode');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'device_id', k.device_id, 'name', k.name, 'model', k.model, 'app_version', k.app_version,
           'battery', k.battery, 'charging', k.charging, 'screen_on', k.screen_on,
           'device_owner', k.device_owner, 'maintenance', k.maintenance,
           'page_ok', k.page_ok, 'page_url', k.page_url, 'sched_on', k.sched_on, 'sched_off', k.sched_off,
           'last_seen', k.last_seen, 'online', k.last_seen > now() - interval '3 minutes',
           'wifi', k.wifi, 'internet', k.internet, 'wifi_signal', k.wifi_signal,
           'battery_temp', k.battery_temp, 'last_outage', k.last_outage, 'power_windows', k.power_windows,
           'page_version', k.page_version, 'page_error', k.page_error, 'page_error_at', k.page_error_at, 'shot_at', k.shot_at,
           'drain_on', case when k.drain_on_n >= 3 then k.drain_on end, 'drain_off', case when k.drain_off_n >= 3 then k.drain_off end,
           'asleep', not public.kiosk_app_awake_now(k.sched_on, k.sched_off),
           'phone', k.phone_mode or public.kiosk_app_is_phone(k.page_url),
           'cmd', k.cmd, 'cmd_at', k.cmd_at, 'cmd_result', k.cmd_result, 'cmd_done_at', k.cmd_done_at,
           'pending', (k.cmd_id is not null and k.cmd_id > coalesce(k.cmd_done_id,0) and k.cmd_at > now() - interval '30 minutes'),
           'events', (select coalesce(jsonb_agg(jsonb_build_object('event', e.event, 'at', e.at) order by e.at desc), '[]'::jsonb)
                        from (select * from public.kiosk_app_events e2 where e2.device_id = k.device_id
                               order by e2.at desc limit 5) e)
         ) || jsonb_build_object(
           -- BUILD-6: connection + Wi-Fi downtime
           'battery_unrestricted', k.battery_unrestricted,
           'net', jsonb_build_object('type', k.net_type, 'since', k.net_since, 'mobile_signal', k.mobile_signal, 'mobile_ok', k.mobile_ok,
                    'down_today_min', public.kiosk_app_down_min(k.device_id, (date_trunc('day', now() at time zone 'Asia/Manila')) at time zone 'Asia/Manila'),
                    'down_7d_min', public.kiosk_app_down_min(k.device_id, now() - interval '7 days'),
                    'periods', (select coalesce(jsonb_agg(jsonb_build_object('kind', c.kind, 'from', c.started_at, 'to', c.ended_at, 'reason', c.reason)
                                                          order by c.started_at desc), '[]'::jsonb)
                                  from (select * from public.kiosk_app_conn c2 where c2.device_id = k.device_id
                                         order by c2.started_at desc limit 15) c)),
           -- BUILD-6: punches waiting / stuck on this tablet (the kiosk page's own report, kiosk_health)
           'punches', (select jsonb_build_object('queue', h.j->'queue_length', 'offline_queue', h.j->'offline_queue_length',
                                'stuck', h.j->'stuck_count', 'stuck_details', h.j->'stuck_details',
                                'oldest_unsynced_at', h.j->'oldest_unsynced_at', 'reported_at', h.j->'last_seen')
                         from (select to_jsonb(kh) as j from public.kiosk_health kh where kh.device_id = k.kiosk_device_id) h),
           -- BUILD-6: SIM, mobile data, loads, telco texts
           'sim', public.kiosk_app_sim_info(k.device_id)
         ) order by k.name), '[]'::jsonb)
    into v from public.kiosk_app_devices k;
  return v;
end $$;
revoke all on function public.kiosk_app_list(text) from public;
grant execute on function public.kiosk_app_list(text) to anon, authenticated;

-- STEP 5 - office page: send a command (admin passcode)
create or replace function public.kiosk_app_command(p_passcode text, p_device text, p_cmd text, p_arg text default '')
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_arg text := btrim(coalesce(p_arg,'')); v_wifi jsonb; v_log text;
begin
  -- Return (never raise) on a wrong passcode: raising would roll back the wrong-try counter
  -- inside admin_verify_passcode and remove its brute-force lockout.
  if not public.admin_verify_passcode(p_passcode) then
    return jsonb_build_object('error', 'wrong passcode');
  end if;
  if p_cmd not in ('reload','hard_reload','restart','update','screen_on','screen_off','open_settings','schedule','screenshot',
                   'retry_punches','set_wifi') then
    return jsonb_build_object('error', 'unknown command');
  end if;
  -- BUILD-6 Set Wi-Fi: arg = {"ssid":"RSR Mandaue","pass":"12345678","switch":true}. The password is removed
  -- from the server as soon as the tablet confirms (kiosk_app_ack) or after 30 min (kiosk_app_tick).
  if p_cmd = 'set_wifi' then
    begin
      v_wifi := v_arg::jsonb;
    exception when others then
      return jsonb_build_object('error', 'Wi-Fi details not readable');
    end;
    if jsonb_typeof(v_wifi) <> 'object' or length(coalesce(v_wifi->>'ssid','')) not between 1 and 32
       or v_wifi->>'ssid' ~ '[[:cntrl:]"\\]' then
      return jsonb_build_object('error', 'Wi-Fi name must be 1 to 32 characters (no quotes)');
    end if;
    if coalesce(v_wifi->>'pass','') <> '' and (length(v_wifi->>'pass') not between 8 and 63 or v_wifi->>'pass' ~ '[[:cntrl:]"\\]') then
      return jsonb_build_object('error', 'Wi-Fi password must be 8 to 63 characters (no quotes), or empty for an open network');
    end if;
    v_arg := jsonb_build_object('ssid', v_wifi->>'ssid', 'pass', coalesce(v_wifi->>'pass',''),
                                'switch', coalesce(v_wifi->>'switch', 'true') <> 'false')::text;
    v_log := 'set_wifi ' || regexp_replace(v_wifi->>'ssid', '[^[:alnum:] ._-]', '', 'g');   -- never the password
  end if;
  if p_cmd = 'schedule' and v_arg <> 'off'
     and v_arg !~ '^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$' then
    return jsonb_build_object('error', 'schedule must look like 05:30-22:30 or off');
  end if;
  update public.kiosk_app_devices k
     set cmd_id = nextval('public.kiosk_app_cmd_seq'), cmd = p_cmd, cmd_arg = v_arg, cmd_at = now(),
         cmd_result = null, cmd_done_at = null
   where k.device_id = p_device;
  if not found then return jsonb_build_object('error', 'tablet not found'); end if;
  insert into public.kiosk_app_events (device_id, event, notified)
  values (p_device, 'office: ' || coalesce(v_log, p_cmd || case when v_arg <> '' then ' ' || v_arg else '' end), true);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.kiosk_app_command(text, text, text, text) from public;
grant execute on function public.kiosk_app_command(text, text, text, text) to anon, authenticated;

-- STEP 5c - screenshot of the kiosk screen (2026-11-04). The tablet uploads it with its secret; only the
-- latest one per tablet is kept. The office reads it with the admin passcode. Never in kiosk_app_list (size).
create or replace function public.kiosk_app_shot_put(p_device text, p_token text, p_jpeg text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  if not exists (select 1 from public.kiosk_app_devices k
                  where k.device_id = p_device and k.token is not null and k.token = p_token) then
    return jsonb_build_object('error', 'token');
  end if;
  if length(coalesce(p_jpeg, '')) > 700000 then return jsonb_build_object('error', 'too big'); end if;
  -- base64 of a JPEG always starts with /9j/ and has only base64 characters
  if coalesce(p_jpeg, '') !~ '^/9j/[A-Za-z0-9+/]+=*$' then return jsonb_build_object('error', 'not a jpeg'); end if;
  insert into public.kiosk_app_shots as s (device_id, taken_at, jpeg) values (p_device, now(), p_jpeg)
  on conflict (device_id) do update set taken_at = excluded.taken_at, jpeg = excluded.jpeg;
  update public.kiosk_app_devices k set shot_at = now() where k.device_id = p_device;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.kiosk_app_shot_put(text, text, text) from public;
grant execute on function public.kiosk_app_shot_put(text, text, text) to anon, authenticated;

create or replace function public.kiosk_app_shot_get(p_passcode text, p_device text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v jsonb;
begin
  -- Return (never raise) on a wrong passcode: raising would roll back the wrong-try counter.
  if not public.admin_verify_passcode(p_passcode) then
    return jsonb_build_object('error', 'wrong passcode');
  end if;
  select jsonb_build_object('taken_at', s.taken_at, 'jpeg', s.jpeg) into v
    from public.kiosk_app_shots s where s.device_id = p_device;
  return coalesce(v, jsonb_build_object('error', 'no screenshot yet'));
end $$;
revoke all on function public.kiosk_app_shot_get(text, text) from public;
grant execute on function public.kiosk_app_shot_get(text, text) to anon, authenticated;

-- STEP 5d - BUILD-6 telco texts. The app sends ONLY texts from telco names / short codes (never from a
-- personal mobile number). A load text is recorded as a load by itself; the rest are kept for the
-- Tablets page, and expiring / expired / low ones go to Telegram (kiosk_app_tick).
create or replace function public.kiosk_app_sms_put(p_device text, p_token text, p_sender text, p_body text, p_at text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_from text := left(regexp_replace(btrim(coalesce(p_sender,'')), '[^[:alnum:] ._+-]', '', 'g'), 20);
  -- a person's number inside a telco text (missed call, pasaload) is masked before it is stored
  v_body text := left(regexp_replace(regexp_replace(btrim(coalesce(p_body,'')), '[<>]', '', 'g'),
                      '(\+?63|0)?9[0-9]{2}[ -]?[0-9]{3}[ -]?[0-9]{4}', '09*********', 'g'), 1000);
  v_at   timestamptz := coalesce(public.kiosk_app_ts(p_at), now());
  v_kind text;
  v_id   bigint;
  v_load bigint;
  v_p    jsonb;
  d      public.kiosk_app_devices%rowtype;
begin
  select * into d from public.kiosk_app_devices k where k.device_id = p_device and k.token is not null and k.token = p_token;
  if not found then return jsonb_build_object('error', 'token'); end if;
  if v_from = '' or v_body = '' then return jsonb_build_object('error', 'empty'); end if;
  -- only the telco: its name (DITO, GOMO, Globe, TM, Smart, TNT, Sun) or a 3-5 digit short code. Anything else
  -- (a person, a bank / GCash code, an email-to-text) is never stored, even if an app build sent it.
  if not (v_from ~* '(dito|gomo|globe|\mtm\M|smart|\mtnt\M|\msun\M)' or v_from ~ '^[0-9]{3,5}$') then
    return jsonb_build_object('ok', true, 'ignored', true);
  end if;
  if v_at > now() or v_at < now() - interval '11 days' then v_at := now(); end if;
  -- the app re-sends after a lost reply: same text within 10 min = the same text
  if exists (select 1 from public.kiosk_app_sms x where x.device_id = p_device and x.sender = v_from and x.body = v_body
               and x.received_at between v_at - interval '10 minutes' and v_at + interval '10 minutes') then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  if (select count(*) from public.kiosk_app_sms x where x.device_id = p_device and x.received_at > now() - interval '1 day') >= 40 then
    return jsonb_build_object('error', 'too many texts today');
  end if;
  v_kind := public.kiosk_app_sms_kind(v_body);
  insert into public.kiosk_app_sms (device_id, sender, body, received_at, kind) values (p_device, v_from, v_body, v_at, v_kind)
  returning id into v_id;
  if v_kind = 'load' then
    v_p := public.kiosk_app_parse_load(v_body, (v_at at time zone 'Asia/Manila')::date);
    insert into public.kiosk_app_loads (device_id, provider, promo, gb, load_date, expires_on, source, sms_id)
    values (p_device, coalesce(d.sim_provider, d.sim_operator), null, (v_p->>'gb')::numeric,
            (v_at at time zone 'Asia/Manila')::date, (v_p->>'expires_on')::date, 'text', v_id)
    returning id into v_load;
    update public.kiosk_app_sms x set load_id = v_load where x.id = v_id;
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.kiosk_app_sms_put(text, text, text, text, text) from public;
grant execute on function public.kiosk_app_sms_put(text, text, text, text, text) to anon, authenticated;

-- STEP 5e - BUILD-6 office records a load (screenshot read on the Tablets page, or typed). Admin passcode.
-- p_load: {"provider":"DITO","promo":"...","gb":25,"load_date":"2026-11-16","expires_on":"2027-11-16",
--          "source":"screenshot"|"typed","shot":"<base64 JPEG, optional>"}
create or replace function public.kiosk_app_load_add(p_passcode text, p_device text, p_load jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_ld date; v_exp date; v_gb numeric; v_id bigint; v_shot text := coalesce(p_load->>'shot', '');
  v_src text := case when p_load->>'source' = 'screenshot' then 'screenshot' else 'typed' end;
begin
  if not public.admin_verify_passcode(p_passcode) then
    return jsonb_build_object('error', 'wrong passcode');
  end if;
  if not exists (select 1 from public.kiosk_app_devices k where k.device_id = p_device) then
    return jsonb_build_object('error', 'tablet not found');
  end if;
  v_ld := public.kiosk_app_text_date(p_load->>'load_date');
  if v_ld is null or p_load->>'load_date' !~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}$' or v_ld > v_today + 1 or v_ld < v_today - 400 then
    return jsonb_build_object('error', 'load date must be a real date (YYYY-MM-DD), not in the future');
  end if;
  if coalesce(p_load->>'expires_on', '') <> '' then
    v_exp := public.kiosk_app_text_date(p_load->>'expires_on');
    if v_exp is null or p_load->>'expires_on' !~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}$' or v_exp < v_ld or v_exp > v_ld + 800 then
      return jsonb_build_object('error', 'expiry date must be a real date on or after the load date');
    end if;
  end if;
  if coalesce(p_load->>'gb', '') <> '' then
    if p_load->>'gb' !~ '^[0-9]{1,5}(\.[0-9]{1,2})?$' then return jsonb_build_object('error', 'GB must be a number like 25 or 1.5'); end if;
    v_gb := (p_load->>'gb')::numeric;
  end if;
  if v_shot <> '' and (length(v_shot) > 900000 or v_shot !~ '^/9j/[A-Za-z0-9+/]+=*$') then
    return jsonb_build_object('error', 'screenshot must be a JPEG under about 650 KB');
  end if;
  insert into public.kiosk_app_loads (device_id, provider, promo, gb, load_date, expires_on, source)
  values (p_device,
          nullif(left(regexp_replace(btrim(coalesce(p_load->>'provider','')), '[^[:alnum:] ._-]', '', 'g'), 20), ''),
          nullif(left(regexp_replace(btrim(coalesce(p_load->>'promo','')), '[<>]', '', 'g'), 60), ''),
          v_gb, v_ld, v_exp, v_src)
  returning id into v_id;
  if v_shot <> '' then
    delete from public.kiosk_app_load_shots s where s.device_id = p_device;
    insert into public.kiosk_app_load_shots (load_id, device_id, jpeg) values (v_id, p_device, v_shot);
  end if;
  update public.kiosk_app_devices k set load_wait_from = null where k.device_id = p_device;
  insert into public.kiosk_app_events (device_id, event, notified)
  values (p_device, 'office: load recorded (' || v_src || ') ' || to_char(v_ld, 'YYYY-MM-DD')
                    || coalesce(' until ' || to_char(v_exp, 'YYYY-MM-DD'), ''), true);
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke all on function public.kiosk_app_load_add(text, text, jsonb) from public;
grant execute on function public.kiosk_app_load_add(text, text, jsonb) to anon, authenticated;

-- optional "I just loaded": if no telco load text reaches the tablet within 30 min, Telegram asks for the screenshot
create or replace function public.kiosk_app_load_wait(p_passcode text, p_device text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.admin_verify_passcode(p_passcode) then
    return jsonb_build_object('error', 'wrong passcode');
  end if;
  update public.kiosk_app_devices k set load_wait_from = now() where k.device_id = p_device;
  if not found then return jsonb_build_object('error', 'tablet not found'); end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.kiosk_app_load_wait(text, text) from public;
grant execute on function public.kiosk_app_load_wait(text, text) to anon, authenticated;

-- SIM provider + "number closes after N days without a load" (owner: GOMO 365). Admin passcode.
create or replace function public.kiosk_app_sim_set(p_passcode text, p_device text, p_provider text, p_close_days integer)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_p text := nullif(upper(left(regexp_replace(btrim(coalesce(p_provider,'')), '[^[:alnum:] ._-]', '', 'g'), 20)), '');
        v_d integer := p_close_days;
begin
  if not public.admin_verify_passcode(p_passcode) then
    return jsonb_build_object('error', 'wrong passcode');
  end if;
  if v_d is null and v_p = 'GOMO' then v_d := 365; end if;
  if v_d is not null and v_d not between 30 and 1000 then
    return jsonb_build_object('error', 'days without load must be 30 to 1000 (or empty)');
  end if;
  update public.kiosk_app_devices k set sim_provider = v_p, sim_close_days = v_d where k.device_id = p_device;
  if not found then return jsonb_build_object('error', 'tablet not found'); end if;
  insert into public.kiosk_app_events (device_id, event, notified)
  values (p_device, 'office: SIM ' || coalesce(v_p, 'none') || coalesce(', closes after ' || v_d || ' days without load', ''), true);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.kiosk_app_sim_set(text, text, text, integer) from public;
grant execute on function public.kiosk_app_sim_set(text, text, text, integer) to anon, authenticated;

create or replace function public.kiosk_app_load_shot_get(p_passcode text, p_device text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.admin_verify_passcode(p_passcode) then
    return jsonb_build_object('error', 'wrong passcode');
  end if;
  select jsonb_build_object('load_id', s.load_id, 'jpeg', s.jpeg) into v from public.kiosk_app_load_shots s where s.device_id = p_device;
  return coalesce(v, jsonb_build_object('error', 'no screenshot yet'));
end $$;
revoke all on function public.kiosk_app_load_shot_get(text, text) from public;
grant execute on function public.kiosk_app_load_shot_get(text, text) to anon, authenticated;

-- STEP 6a - "1 h 25 min" style text for alerts
create or replace function public.kiosk_app_dur(p interval)
returns text language sql immutable as $$
  select case when extract(epoch from p) >= 3600
              then floor(extract(epoch from p)/3600)::int || ' h ' || (floor(extract(epoch from p)/60)::int % 60) || ' min'
              else floor(extract(epoch from p)/60)::int || ' min' end
$$;
revoke all on function public.kiosk_app_dur(interval) from public, anon, authenticated;

-- STEP 6b - "05:30" -> 330 minutes (null if not a time)
create or replace function public.kiosk_app_hhmm(p text)
returns integer language sql immutable as $$
  select case when p ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
              then split_part(p, ':', 1)::int * 60 + split_part(p, ':', 2)::int end
$$;
revoke all on function public.kiosk_app_hhmm(text) from public, anon, authenticated;

-- Is the tablet's screen schedule ON right now (Manila)? No schedule = always.
create or replace function public.kiosk_app_awake_now(p_on text, p_off text)
returns boolean language plpgsql stable as $$
declare m int := extract(hour from (now() at time zone 'Asia/Manila'))*60 + extract(minute from (now() at time zone 'Asia/Manila'));
        a int := public.kiosk_app_hhmm(p_on); b int := public.kiosk_app_hhmm(p_off);
begin
  if a is null or b is null or a = b then return true; end if;
  return case when a < b then m >= a and m < b else m >= a or m < b end;
end $$;
revoke all on function public.kiosk_app_awake_now(text, text) from public, anon, authenticated;

-- STEP 6c - generator-hours helpers (Manila time)
-- Generator state at minute-of-day p_min. Window text: "08:00-11:30,13:00-16:30,18:00-21:00+24:00"
-- ("+24:00" = overtime: the generator MAY run until 24:00). Returns:
--   'on'       generator should be running (15 min after its start, until 5 min before its stop)
--   'grace'    first 15 / last 5 min of a run - starting late or stopping early is normal, judge nothing
--   'overtime' inside the optional overtime part - on battery is normal, only "may run out" applies
--   'off'      generator off (break, night)
-- No windows (grid power) = always 'on'.
create or replace function public.kiosk_app_power_state(p_windows text, p_min int)
returns text language plpgsql immutable as $$
declare w text; a int; b int; x int; main text;
begin
  if coalesce(btrim(p_windows), '') = '' then return 'on'; end if;
  foreach w in array string_to_array(p_windows, ',') loop
    main := split_part(btrim(w), '+', 1);
    a := public.kiosk_app_hhmm(split_part(main, '-', 1));
    b := case when split_part(main, '-', 2) = '24:00' then 1440 else public.kiosk_app_hhmm(split_part(main, '-', 2)) end;
    x := case when split_part(btrim(w), '+', 2) = '24:00' then 1440 else public.kiosk_app_hhmm(nullif(split_part(btrim(w), '+', 2), '')) end;
    continue when a is null or b is null;
    if p_min >= a + 15 and p_min < b - 5 then return 'on'; end if;
    if p_min >= a and p_min < b then return 'grace'; end if;
    if x is not null and p_min >= b and p_min < x then return 'overtime'; end if;
  end loop;
  return 'off';
end $$;

create or replace function public.kiosk_app_power_on(p_windows text, p_min int)
returns boolean language sql immutable as $$
  select public.kiosk_app_power_state(p_windows, p_min) = 'on'
$$;

-- Next generator START after p_now (today or tomorrow). Null when there are no windows.
create or replace function public.kiosk_app_next_power(p_windows text, p_now timestamptz)
returns timestamptz language plpgsql stable as $$
declare w text; a int; d date := (p_now at time zone 'Asia/Manila')::date; best timestamptz; t timestamptz; k int;
begin
  if coalesce(btrim(p_windows), '') = '' then return null; end if;
  for k in 0..1 loop
    foreach w in array string_to_array(p_windows, ',') loop
      a := public.kiosk_app_hhmm(split_part(btrim(w), '-', 1));
      continue when a is null;
      t := ((d + k)::timestamp + make_interval(mins => a)) at time zone 'Asia/Manila';
      if t > p_now and (best is null or t < best) then best := t; end if;
    end loop;
  end loop;
  return best;
end $$;

-- Battery % needed from p_from to p_to, plus 10% margin. Uses this tablet's MEASURED drain (%/hour,
-- screen on / off) once it has 3+ measurements; until then a safe starting estimate: 15%/h with the
-- screen on (camera preview runs all the time; the app turns the backlight down while the page is
-- black) and 3%/h with the screen off by the schedule.
create or replace function public.kiosk_app_need_pct(p_from timestamptz, p_to timestamptz, p_on text, p_off text,
                                                     p_rate_on numeric default null, p_rate_off numeric default null)
returns integer language plpgsql stable as $$
declare t timestamptz := p_from; m int; v_on int := public.kiosk_app_hhmm(p_on); v_off int := public.kiosk_app_hhmm(p_off);
        awake boolean; need numeric := 10; n int := 0;
        r_on numeric := least(40, greatest(3, coalesce(p_rate_on, 15)));
        r_off numeric := least(15, greatest(0.5, coalesce(p_rate_off, 3)));
begin
  if p_to is null then return null; end if;
  while t < p_to and n < 200 loop
    m := extract(hour from (t at time zone 'Asia/Manila'))*60 + extract(minute from (t at time zone 'Asia/Manila'));
    awake := case when v_on is null or v_off is null or v_on = v_off then true
                  when v_on < v_off then m >= v_on and m < v_off
                  else m >= v_on or m < v_off end;
    need := need + case when awake then r_on else r_off end / 4.0;   -- per 15 minutes
    t := t + interval '15 minutes'; n := n + 1;
  end loop;
  return ceil(need)::int;
end $$;
-- the old 4-argument version (replaced by the one above with optional measured rates)
drop function if exists public.kiosk_app_need_pct(timestamptz, timestamptz, text, text);
revoke all on function public.kiosk_app_power_on(text, int) from public, anon, authenticated;
revoke all on function public.kiosk_app_power_state(text, int) from public, anon, authenticated;
revoke all on function public.kiosk_app_next_power(text, timestamptz) from public, anon, authenticated;
revoke all on function public.kiosk_app_need_pct(timestamptz, timestamptz, text, text, numeric, numeric) from public, anon, authenticated;

-- STEP 5b - office page: set a tablet's generator hours (admin passcode). '' = normal grid power.
create or replace function public.kiosk_app_set_power(p_passcode text, p_device text, p_windows text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v text := regexp_replace(coalesce(p_windows,''), '\s', '', 'g'); w text; a int; b int; x int; prev int := -1;
begin
  if not public.admin_verify_passcode(p_passcode) then
    return jsonb_build_object('error', 'wrong passcode');
  end if;
  if v <> '' then
    if v !~ '^[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}(\+[0-9]{2}:[0-9]{2})?(,[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}(\+[0-9]{2}:[0-9]{2})?){0,5}$' then
      return jsonb_build_object('error', 'use the form 08:00-11:30,13:00-16:30,18:00-21:00+24:00 (+24:00 = overtime may run until 24:00)');
    end if;
    foreach w in array string_to_array(v, ',') loop
      a := public.kiosk_app_hhmm(split_part(split_part(w, '+', 1), '-', 1));
      b := case when split_part(split_part(w, '+', 1), '-', 2) = '24:00' then 1440 else public.kiosk_app_hhmm(split_part(split_part(w, '+', 1), '-', 2)) end;
      x := case when split_part(w, '+', 2) = '' then b when split_part(w, '+', 2) = '24:00' then 1440 else public.kiosk_app_hhmm(split_part(w, '+', 2)) end;
      if a is null or b is null or x is null or b - a < 30 or x < b or a < prev then
        return jsonb_build_object('error', 'each period must be start-end (at least 30 min), in order, within one day (end 24:00 allowed): ' || w);
      end if;
      prev := x;
    end loop;
  end if;
  update public.kiosk_app_devices k set power_windows = nullif(v, ''), risk_alerted_for = null where k.device_id = p_device;
  if not found then return jsonb_build_object('error', 'tablet not found'); end if;
  insert into public.kiosk_app_events (device_id, event, notified)
  values (p_device, 'office: generator hours ' || coalesce(nullif(v,''), 'none (grid power)'), true);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.kiosk_app_set_power(text, text, text) from public;
grant execute on function public.kiosk_app_set_power(text, text, text) to anon, authenticated;

-- STEP 6c2 - roll-call PHONE (owner 2026-11-08 / 11-12): the Wi-Fi-only Motorola runs this app locked to a
-- Job Monitoring page. It is carried around on battery and offline in the yard by design, so it gets NO
-- OFFLINE / back ONLINE / NOT CHARGING / charging-again / generator alerts and is left off the dashboard
-- charging banner. Battery: only LOW 20% and CRITICAL 10% (sent when it reports, i.e. on Wi-Fi).
-- HOT and weak-charger alerts stay. "Not synced by 7:30 PM" / "not seen 2 days" come from the roll-call
-- page itself (rsr-engineering monitoring/sql/rollcall-offline-sync.sql). Same rule as the app (Mode.java).
create or replace function public.kiosk_app_is_phone(p_url text)
returns boolean language sql immutable as $$
  select coalesce(lower(split_part(split_part(btrim(p_url), '?', 1), '#', 1))
                  like 'https://seafordprojects-bit.github.io/%/monitoring/%', false)
$$;
revoke all on function public.kiosk_app_is_phone(text) from public, anon, authenticated;

-- STEP 6d - RSR Admin dashboard: battery/charging banner. Read-only, no passcode (same as kiosk_health,
-- which the dashboard already reads with the public key): names, battery %, charging, and whether the
-- generator should be on (Carmen) so a break or the night is not shown as a problem.
create or replace function public.kiosk_app_status()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x.j order by x.nm), '[]'::jsonb) from (
    select k.name as nm, jsonb_build_object(
           'name', coalesce(nullif(k.name,''), 'Tablet'), 'battery', k.battery, 'charging', k.charging,
           'weak_charger', k.weak_since is not null and k.weak_since < now() - interval '15 minutes',
           'last_seen', k.last_seen, 'unplugged_since', k.unplugged_since,
           'generator', k.power_windows is not null,
           'power_state', st.state,
           'power_expected', st.state = 'on' and public.kiosk_app_power_state(k.power_windows,
               greatest(0, (extract(hour from (now() at time zone 'Asia/Manila'))*60 + extract(minute from (now() at time zone 'Asia/Manila')))::int - 5)) = 'on',
           'power_back_at', public.kiosk_app_next_power(k.power_windows, now()),
           'may_run_out', case when k.power_windows is not null and k.charging is false and k.battery is not null
                                    and st.state in ('off', 'overtime')
                               then k.battery < public.kiosk_app_need_pct(now(), public.kiosk_app_next_power(k.power_windows, now()), k.sched_on, k.sched_off,
                                      case when k.drain_on_n >= 3 then k.drain_on end, case when k.drain_off_n >= 3 then k.drain_off end)
                               else false end) as j
      from public.kiosk_app_devices k
      cross join lateral (select public.kiosk_app_power_state(k.power_windows,
            (extract(hour from (now() at time zone 'Asia/Manila'))*60 + extract(minute from (now() at time zone 'Asia/Manila')))::int) as state) st
     where not (k.phone_mode or public.kiosk_app_is_phone(k.page_url))) x
$$;
revoke all on function public.kiosk_app_status() from public;
grant execute on function public.kiosk_app_status() to anon, authenticated;

-- STEP 6 - Telegram watcher (every 5 min). Server-side only; not callable with the anon key.
create or replace function public.kiosk_app_tick()
returns void language plpgsql volatile security definer set search_path = public as $$
declare
  r       record;
  e       record;
  v_sent  int := 0;
  v_min   int := extract(hour from (now() at time zone 'Asia/Manila'))*60
               + extract(minute from (now() at time zone 'Asia/Manila'));
  v_work  boolean;
  v_name  text;
  v_on    int;
  v_off   int;
  v_awake boolean;
  v_why   text;
  v_win   boolean;   -- tablet has generator hours
  v_pwr   boolean;   -- power expected right now
  v_next  timestamptz;
  v_need  int;
  v_state text;
  v_phone boolean;
  l       public.kiosk_app_loads%rowtype;
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_day8  boolean;   -- 8 AM - 8 PM: SIM / load reminders only then
  v_left  int;
  v_long  boolean;
  v_used  bigint;
  v_close date;
  v_prov  text;
  v_alrt  jsonb;
  v_txt   text;
  tx      record;
begin
  v_work := (v_min >= 6*60 and v_min < 22*60);
  v_day8 := (v_min >= 8*60 and v_min < 20*60);

  for r in select * from public.kiosk_app_devices loop
    v_name := coalesce(nullif(r.name,''), r.device_id);
    -- phone / tablet: a Job Monitoring page = phone, a /kiosk/ page = tablet, anything else (another RSR
    -- page, or no page yet) = keep what it was. Remembered in phone_mode.
    v_phone := case when public.kiosk_app_is_phone(r.page_url) then true
                    when lower(coalesce(r.page_url, '')) like 'https://seafordprojects-bit.github.io/%/kiosk/%' then false
                    else r.phone_mode end;
    if v_phone is distinct from r.phone_mode then
      update public.kiosk_app_devices set phone_mode = v_phone where device_id = r.device_id;
    end if;

    -- ROLL-CALL PHONE (see STEP 6c2): offline in the yard and on battery by design.
    if v_phone then
      if r.last_seen > now() - interval '10 minutes' then
        if r.battery_temp is not null and r.battery_temp >= 45 and not r.hot_alerted then
          perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is HOT - battery ' || r.battery_temp
                  || ' C. Move it out of the sun / give it air. Heat damages the battery.');
          update public.kiosk_app_devices set hot_alerted = true where device_id = r.device_id;
        elsif r.hot_alerted and coalesce(r.battery_temp, 0) < 40 then
          update public.kiosk_app_devices set hot_alerted = false where device_id = r.device_id;
        end if;
        if r.weak_since is not null and r.weak_since < now() - interval '15 minutes' and not r.weak_alerted then
          perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is PLUGGED IN but NOT taking charge for '
                  || public.kiosk_app_dur(now() - r.weak_since) || ' (battery ' || coalesce(r.battery::text,'?')
                  || '%). Check the charger and cable.');
          update public.kiosk_app_devices set weak_alerted = true where device_id = r.device_id;
        elsif r.weak_since is null and r.weak_alerted then
          update public.kiosk_app_devices set weak_alerted = false where device_id = r.device_id;
        end if;
        if r.charging is false and r.battery is not null then
          if r.battery <= 10 and r.batt_step > 10 then
            perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' battery CRITICAL ' || r.battery
                    || '% - charge it at the office NOW or roll-call stops.');
            update public.kiosk_app_devices set batt_step = 10, low_batt_alerted = true where device_id = r.device_id;
          elsif r.battery <= 20 and r.batt_step > 20 then
            perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' battery LOW ' || r.battery
                    || '%. Charge it at the office today.');
            update public.kiosk_app_devices set batt_step = 20, low_batt_alerted = true where device_id = r.device_id;
          end if;
        elsif r.charging is true and (r.batt_step < 100 or r.low_batt_alerted) then
          update public.kiosk_app_devices set batt_step = 100, low_batt_alerted = false where device_id = r.device_id;
        end if;
      end if;
      -- a tablet re-pointed to roll-call must not keep an old OFFLINE / NOT CHARGING state
      if r.offline_first_at is not null or r.unplugged_alerted then
        update public.kiosk_app_devices set offline_first_at = null, unplugged_alerted = false, unplugged_alerted_at = null
         where device_id = r.device_id;
      end if;
      continue;
    end if;

    -- BUILD-6 SIM + LOAD watch (dates only, so it runs even while the tablet is silent).
    l := null;
    select * into l from public.kiosk_app_loads x where x.device_id = r.device_id order by x.load_date desc, x.id desc limit 1;
    v_prov := coalesce(r.sim_provider, l.provider, r.sim_operator, 'SIM');
    -- keep only reminders of the current load (+ this month's "no load recorded")
    v_alrt := (select coalesce(jsonb_object_agg(a.key, a.value), '{}'::jsonb) from jsonb_each(r.sim_alerts) a
                where (l.id is not null and a.key like '%:' || l.id) or a.key = 'noload:' || to_char(v_today, 'YYYY-MM'));
    -- optional "I just loaded": no load text within 30 min -> ask for the screenshot
    if r.load_wait_from is not null and r.load_wait_from < now() - interval '30 minutes' then
      if l.id is null or l.created_at < r.load_wait_from then
        perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' - no ' || v_prov || ' text reached the tablet in 30 min after your load.'
                || case when r.last_seen < r.load_wait_from then ' (The tablet has been offline since '
                        || to_char(r.last_seen at time zone 'Asia/Manila', 'Mon DD HH12:MI AM') || ' - it cannot check its texts.)' else '' end
                || ' Please send the screenshot of the load: Tablets page > ' || v_name || ' > SIM > Record load > Upload screenshot.');
      end if;
      update public.kiosk_app_devices set load_wait_from = null where device_id = r.device_id;
    end if;
    if v_day8 and l.id is not null then
      -- load expiry: 30 / 7 / 3 days before (long loads) or 3 days before (short loads), and on the day
      if l.expires_on is not null then
        v_left := l.expires_on - v_today;
        v_long := l.expires_on - l.load_date > 60;
        v_txt := null;
        if v_left <= 0 and not v_alrt ? ('expd:' || l.id) then
          v_txt := ' - ' || v_prov || ' load EXPIRED' || case when v_left < 0 then ' on ' || to_char(l.expires_on, 'Mon DD, YYYY') else ' today' end
                   || '. Please reload. The telco text is recorded by itself; if no text comes you will be asked for the screenshot.';
          v_alrt := v_alrt || jsonb_build_object('expd:' || l.id, true, 'exp3:' || l.id, true, 'exp7:' || l.id, true, 'exp30:' || l.id, true);
        elsif v_left between 1 and 3 and not v_alrt ? ('exp3:' || l.id) then
          v_txt := ' - ' || v_prov || ' load expires in ' || v_left || case when v_left = 1 then ' day' else ' days' end
                   || ' (' || to_char(l.expires_on, 'Mon DD, YYYY') || '). Reload before then.';
          v_alrt := v_alrt || jsonb_build_object('exp3:' || l.id, true, 'exp7:' || l.id, true, 'exp30:' || l.id, true);
        elsif v_long and v_left between 4 and 7 and not v_alrt ? ('exp7:' || l.id) then
          v_txt := ' - ' || v_prov || ' load expires in ' || v_left || ' days (' || to_char(l.expires_on, 'Mon DD, YYYY') || ').';
          v_alrt := v_alrt || jsonb_build_object('exp7:' || l.id, true, 'exp30:' || l.id, true);
        elsif v_long and v_left between 8 and 30 and not v_alrt ? ('exp30:' || l.id) then
          v_txt := ' - ' || v_prov || ' load expires in ' || v_left || ' days (' || to_char(l.expires_on, 'Mon DD, YYYY') || ').';
          v_alrt := v_alrt || jsonb_build_object('exp30:' || l.id, true);
        end if;
        if v_txt is not null then perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || v_txt); end if;
      end if;
      -- 80% of the promo's data used (the tablet's own count since the load day)
      if l.gb is not null and l.gb > 0 and not v_alrt ? ('data80:' || l.id) then
        select coalesce(sum(x.bytes), 0) into v_used from public.kiosk_app_data_days x where x.device_id = r.device_id and x.day >= l.load_date;
        if v_used >= l.gb * 0.8 * 1073741824 then
          perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' has used about ' || round(v_used / 1073741824.0, 1)
                  || ' GB of its ' || trim_scale(l.gb) || ' GB ' || v_prov || ' load (80%+). Reload soon.');
          v_alrt := v_alrt || jsonb_build_object('data80:' || l.id, true);
        end if;
      end if;
      -- number closes after N days without a load (owner: GOMO 365)
      if r.sim_close_days is not null then
        v_close := l.load_date + r.sim_close_days;
        v_left := v_close - v_today;
        v_txt := null;
        if v_left <= 7 and not v_alrt ? ('close7:' || l.id) then
          v_txt := ' - ' || v_prov || ' NUMBER WILL CLOSE ' || case when v_left <= 0 then 'NOW (no load since ' else 'in ' || v_left || ' days (no load since ' end
                   || to_char(l.load_date, 'Mon DD, YYYY') || '). Load it before ' || to_char(v_close, 'Mon DD, YYYY') || '.';
          v_alrt := v_alrt || jsonb_build_object('close7:' || l.id, true, 'close30:' || l.id, true);
        elsif v_left between 8 and 30 and not v_alrt ? ('close30:' || l.id) then
          v_txt := ' - ' || v_prov || ' number closes in ' || v_left || ' days if not loaded (last load ' || to_char(l.load_date, 'Mon DD, YYYY')
                   || '). Load it before ' || to_char(v_close, 'Mon DD, YYYY') || '.';
          v_alrt := v_alrt || jsonb_build_object('close30:' || l.id, true);
        end if;
        if v_txt is not null then perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || v_txt); end if;
      end if;
    elsif v_day8 and l.id is null and r.sim_provider is not null and not v_alrt ? ('noload:' || to_char(v_today, 'YYYY-MM')) then
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' - no load recorded yet for its ' || r.sim_provider
              || ' SIM, so expiry and closing dates cannot be watched. Send the screenshot of the last load: Tablets page > '
              || v_name || ' > SIM > Record load.');
      v_alrt := v_alrt || jsonb_build_object('noload:' || to_char(v_today, 'YYYY-MM'), true);
    end if;
    if v_alrt is distinct from r.sim_alerts then
      update public.kiosk_app_devices set sim_alerts = v_alrt where device_id = r.device_id;
    end if;

    -- OFFLINE: no report for 10 min. Only 6 AM - 10 PM, only while the tablet's own screen schedule
    -- has it awake (plus 15 min after its ON time), and only for a tablet seen in the last 24 h
    -- (a retired tablet is not an alarm). Reminder every 60 min while it stays offline.
    v_on  := public.kiosk_app_hhmm(r.sched_on);
    v_off := public.kiosk_app_hhmm(r.sched_off);
    v_awake := case when v_on is null or v_off is null or v_on = v_off then true
                    when v_on < v_off then v_min >= v_on + 15 and v_min < v_off
                    else v_min >= v_on + 15 or v_min < v_off end;
    if r.last_seen < now() - interval '10 minutes' then
      -- From 9 PM the app turns the screen off when nobody uses it, and the tablet then sleeps:
      -- its last report said screen_on=false, so that silence is on purpose, not an outage.
      if v_work and v_awake and r.last_seen > now() - interval '24 hours'
         and not (r.screen_on is false and v_min >= 21*60)
         and (r.offline_alerted_at is null or r.offline_alerted_at < now() - interval '60 minutes') then
        v_why := case when r.charging is false and coalesce(r.battery,100) <= 15
                        then ' Last report: battery ' || r.battery || '% and NOT charging - the battery probably ran out.'
                      when r.charging is false and r.power_windows is null and (r.wifi is false or r.net_type in ('mobile','none'))
                        then ' Last report: NOT charging (battery ' || coalesce(r.battery::text,'?') || '%) - possible BROWNOUT (router off too).'
                             || ' The tablet keeps punches on battery.'
                      when r.wifi is false then ' Last report: no Wi-Fi.'
                      when coalesce(r.wifi_signal,4) <= 1 then ' Last report: weak Wi-Fi signal (' || r.wifi_signal || '/4).'
                      else ' Possible: Wi-Fi/internet down, power cut, or tablet off.' end;
        perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is OFFLINE - no report for '
                || public.kiosk_app_dur(now() - r.last_seen) || ' (since '
                || to_char(r.last_seen at time zone 'Asia/Manila', 'HH12:MI AM') || ').' || v_why
                || ' Punches are kept on the tablet and sync when it is back.');
        update public.kiosk_app_devices
           set offline_alerted_at = now(), offline_first_at = coalesce(offline_first_at, now())
         where device_id = r.device_id;
      end if;
      continue;   -- nothing else can be judged from a silent tablet
    end if;

    -- BACK ONLINE after an offline alarm: one message, with the reason the tablet reported.
    if r.offline_first_at is not null then
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is back ONLINE.'
              || case when r.last_outage is not null and (r.last_outage->>'reported_at')::timestamptz > now() - interval '30 minutes'
                      then ' It was offline ' || public.kiosk_app_dur(((r.last_outage->>'minutes')::int || ' minutes')::interval)
                           || ' - ' || (r.last_outage->>'reason') || '.'
                      else '' end
              || ' Battery ' || coalesce(r.battery::text,'?') || '%.');
      -- keep offline_alerted_at: a tablet whose Wi-Fi keeps dropping gets at most one OFFLINE per hour
      update public.kiosk_app_devices set offline_first_at = null where device_id = r.device_id;
    end if;

    -- BUILD-6 ON MOBILE DATA 30+ min (yard Wi-Fi down), and back on Wi-Fi. Once each.
    -- only 6 AM - 10 PM, and for a generator tablet only while the generator should run (the yard router may be
    -- off with it: then mobile data is expected, not news)
    if r.net_type = 'mobile' and r.net_since < now() - interval '30 minutes' and not r.mobile_alerted
       and v_work and public.kiosk_app_power_state(r.power_windows, v_min) = 'on' then
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is on MOBILE DATA for ' || public.kiosk_app_dur(now() - r.net_since)
              || ' - the yard Wi-Fi may be down. Punches still sync.'
              || coalesce(' Mobile data used today: ' || (select round(x.bytes / 1048576.0) from public.kiosk_app_data_days x
                                                           where x.device_id = r.device_id and x.day = v_today) || ' MB.', ''));
      update public.kiosk_app_devices set mobile_alerted = true where device_id = r.device_id;
    elsif r.net_type = 'wifi' and r.mobile_alerted then   -- a back-on-Wi-Fi notice only follows an alert
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is back on Wi-Fi.'
              || coalesce(' It was on mobile data ' || (select public.kiosk_app_dur(c.ended_at - c.started_at) from public.kiosk_app_conn c
                                                        where c.device_id = r.device_id and c.kind = 'mobile' and c.ended_at is not null
                                                        order by c.started_at desc limit 1) || '.', ''));
      update public.kiosk_app_devices set mobile_alerted = false where device_id = r.device_id;
    end if;
    -- BUILD-6 MOBILE DATA NOT WORKING (SIM in, data network not validated) for 30 min: load used up / expired?
    if r.mobile_bad_since is not null and r.mobile_bad_since < now() - interval '30 minutes' and not r.mobile_bad_alerted
       and coalesce(r.sim_state, 'ready') = 'ready' then
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' - mobile data is NOT working for '
              || public.kiosk_app_dur(now() - r.mobile_bad_since) || ' (' || coalesce(r.sim_provider, r.sim_operator, 'SIM')
              || '). The load may be used up or expired. If Wi-Fi goes down, punches wait on the tablet.');
      update public.kiosk_app_devices set mobile_bad_alerted = true where device_id = r.device_id;
    elsif r.mobile_bad_since is null and r.mobile_bad_alerted and r.mobile_ok is true then
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' - mobile data works again.'
              || case when exists (select 1 from public.kiosk_app_loads x where x.device_id = r.device_id
                                    and x.created_at > now() - interval '1 day')
                      then ' Load recorded.'
                      else ' Looks like it was loaded, but no telco text came. Please send the screenshot of the load: Tablets page > '
                           || v_name || ' > SIM > Record load.' end);
      update public.kiosk_app_devices set mobile_bad_alerted = false where device_id = r.device_id;
    end if;

    -- WEAK CHARGER: plugged in but the battery is not charging / still dropping for 15 min (bad charger,
    -- loose cable, or the UPS/generator output is too weak). Once; clears when it charges again.
    if r.weak_since is not null and r.weak_since < now() - interval '15 minutes' and not r.weak_alerted then
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is PLUGGED IN but NOT taking charge for '
              || public.kiosk_app_dur(now() - r.weak_since) || ' (battery ' || coalesce(r.battery::text,'?')
              || '%). Check the charger, cable and the power source (UPS / generator).');
      update public.kiosk_app_devices set weak_alerted = true where device_id = r.device_id;
    elsif r.weak_since is null and r.weak_alerted then
      update public.kiosk_app_devices set weak_alerted = false where device_id = r.device_id;
    end if;

    -- HOT: battery 45 C or more (sun, charging in a closed box). Once; clears below 40 C.
    if r.battery_temp is not null and r.battery_temp >= 45 and not r.hot_alerted then
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is HOT - battery ' || r.battery_temp
              || ' C. Move it out of the sun / give it air. Heat damages the battery.');
      update public.kiosk_app_devices set hot_alerted = true where device_id = r.device_id;
    elsif r.hot_alerted and coalesce(r.battery_temp, 0) < 40 then
      update public.kiosk_app_devices set hot_alerted = false where device_id = r.device_id;
    end if;

    v_win := r.power_windows is not null;
    v_state := public.kiosk_app_power_state(r.power_windows, v_min);
    -- judged "on" only after 5 min of 'on' (first NOT CHARGING about 20 min after a generator start)
    v_pwr := v_state = 'on' and public.kiosk_app_power_state(r.power_windows, greatest(v_min - 5, 0)) = 'on';

    -- NOT CHARGING (power expected): first alert after 5 min, then a reminder with the battery %
    -- every 30 min (every 2 h at night for grid-power tablets) until the charger is back.
    -- A generator tablet (Carmen) is only judged while the generator should be running.
    if v_pwr and r.unplugged_since is not null and r.unplugged_since < now() - interval '5 minutes'
       and (r.unplugged_alerted_at is null
            or r.unplugged_alerted_at < now() - case
                 -- BROWNOUT updates (grid tablet, Wi-Fi down too): every hour (owner 2026-11-16 18:18)
                 when not v_win and (r.net_type in ('mobile','none') or r.wifi is false) then interval '60 minutes'
                 when v_work or v_win then interval '30 minutes' else interval '2 hours' end) then
      -- BUILD-6 (owner 2026-11-16, Mandaue on grid): charger AND Wi-Fi lost together = most likely a BROWNOUT
      -- (the yard router lost power too). Say so, and how long the battery should last.
      if not v_win and (r.net_type in ('mobile','none') or r.wifi is false) then
        perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' - POSSIBLE BROWNOUT: not charging for '
                || public.kiosk_app_dur(now() - r.unplugged_since) || ' and the Wi-Fi is down too'
                || case when r.net_type = 'mobile' then ' (reporting on mobile data)' else '' end
                || '. Battery ' || coalesce(r.battery::text,'?') || '%'
                || case when r.drain_on_n >= 3 and r.drain_on > 0 and r.battery is not null
                        then ', about ' || round(r.battery / greatest(r.drain_on, 1))::int || ' h left with the screen on' else '' end
                || '. Punches are kept on the tablet. Updates every hour until power is back.');
      else
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is NOT CHARGING'
              || case when v_win then ' although the generator should be ON (check charger, cable, plug)' else '' end
              || case when v_win then '' else ' for ' || public.kiosk_app_dur(now() - r.unplugged_since) end
              || '. Battery '
              || coalesce(r.battery::text,'?') || '%. Please plug in the charger.');
      end if;
      update public.kiosk_app_devices set unplugged_alerted = true, unplugged_alerted_at = now()
       where device_id = r.device_id;
    elsif r.unplugged_since is null and r.unplugged_alerted then
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is charging again. Battery '
              || coalesce(r.battery::text,'?') || '%. OK.');
      update public.kiosk_app_devices set unplugged_alerted = false, unplugged_alerted_at = null
       where device_id = r.device_id;
    end if;

    -- GENERATOR OFF (break / night) on battery: normal, no alert - UNLESS the battery will not last until
    -- the generator is back. One warning per power-off period.
    if v_win and v_state in ('off', 'overtime') and r.charging is false and r.battery is not null then
      v_next := public.kiosk_app_next_power(r.power_windows, now());
      v_need := public.kiosk_app_need_pct(now(), v_next, r.sched_on, r.sched_off,
                  case when r.drain_on_n >= 3 then r.drain_on end, case when r.drain_off_n >= 3 then r.drain_off end);
      if v_next is not null and r.battery < v_need and r.risk_alerted_for is distinct from v_next then
        perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' on battery (generator off): ' || r.battery
                || '% now. Generator back at ' || to_char(v_next at time zone 'Asia/Manila', 'HH12:MI AM')
                || ' - it may RUN OUT before then (needs about ' || v_need || '%). Plug it into a power bank.');
        update public.kiosk_app_devices set risk_alerted_for = v_next where device_id = r.device_id;
      end if;
    end if;

    -- BATTERY DROPPING while not charging: one message each time it crosses 50%, 30%, 20%, 10%
    -- (sent even inside a reminder gap, so a fast drop is never missed). With the generator off only
    -- the 10% CRITICAL step is sent (the run-out warning above covers the rest).
    if r.charging is false and r.battery is not null then
      if r.battery <= 10 and r.batt_step > 10 then
        perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' battery CRITICAL ' || r.battery
                || '% - it will switch off soon. Plug in NOW.');
        update public.kiosk_app_devices set batt_step = 10, low_batt_alerted = true where device_id = r.device_id;
      elsif not v_pwr then
        -- generator off: keep the step in line with the battery (never 10, so CRITICAL still fires),
        -- so no old step message pops out when the generator comes back
        update public.kiosk_app_devices
           set batt_step = case when r.battery <= 20 then 20 when r.battery <= 30 then 30 when r.battery <= 50 then 50 else 100 end
         where device_id = r.device_id and batt_step > 10;
      elsif r.battery <= 20 and r.batt_step > 20 then
        perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' battery LOW ' || r.battery || '% and NOT charging.');
        update public.kiosk_app_devices set batt_step = 20, low_batt_alerted = true where device_id = r.device_id;
      elsif r.battery <= 30 and r.batt_step > 30 then
        perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' battery ' || r.battery || '% and NOT charging.');
        update public.kiosk_app_devices set batt_step = 30 where device_id = r.device_id;
      elsif r.battery <= 50 and r.batt_step > 50 then
        perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' battery ' || r.battery || '% and NOT charging.');
        update public.kiosk_app_devices set batt_step = 50 where device_id = r.device_id;
      end if;
    elsif r.charging is true and (r.batt_step < 100 or r.low_batt_alerted or r.risk_alerted_for is not null) then
      update public.kiosk_app_devices set batt_step = 100, low_batt_alerted = false, risk_alerted_for = null
       where device_id = r.device_id;
    end if;
  end loop;

  -- notable app events (office commands are already marked notified)
  for e in select ev.id, ev.event, ev.at, ev.device_id, coalesce(nullif(k.name,''), ev.device_id) as nm
             from public.kiosk_app_events ev
             left join public.kiosk_app_devices k on k.device_id = ev.device_id
            where not ev.notified and ev.at > now() - interval '1 hour'
            order by ev.at loop
    if e.event like 'tablet restarted%' or e.event like 'updated to build%'
       or e.event like 'maintenance opened%' or e.event like 'update install failed%'
       or e.event like 'installing build%' or e.event = 'screen on failed'
       or e.event = 'screen woken by phone call' then   -- every call (owner 2026-11-16: new SIMs, no spam expected)
      v_sent := v_sent + 1;
      exit when v_sent > 5;                       -- at most 5 event messages per 5-minute tick
      perform public.kiosk_alert_send('RSR Kiosk: ' || e.nm || ' - '
              || case when e.event = 'screen on failed' then 'screen did NOT turn on by itself. Press the power button; check the Tablets page.'
                      when e.event = 'screen woken by phone call' then 'screen woken by your phone call.'
                      else e.event end || ' (' 
              || to_char(e.at at time zone 'Asia/Manila', 'HH12:MI AM') || ')');
    end if;
    update public.kiosk_app_events set notified = true where id = e.id;
  end loop;

  -- BUILD-6 telco texts: load received / expiring / expired / low go to Telegram (at most 5 per tick); others stay on the page
  v_sent := 0;
  for tx in select x.id, x.kind, x.body, x.received_at, x.load_id, coalesce(nullif(k.name,''), x.device_id) as nm,
                  coalesce(k.sim_provider, k.sim_operator, x.sender) as prov
             from public.kiosk_app_sms x left join public.kiosk_app_devices k on k.device_id = x.device_id
            where not x.notified order by x.received_at loop
    if tx.kind not in ('other', 'otp') and tx.received_at > now() - interval '2 days' then
      v_sent := v_sent + 1;
      exit when v_sent > 5;
      if tx.kind = 'load' then
        select * into l from public.kiosk_app_loads x where x.id = tx.load_id;
        perform public.kiosk_alert_send('RSR Kiosk: ' || tx.nm || ' - LOAD RECEIVED (' || tx.prov || ' text, '
                || to_char(tx.received_at at time zone 'Asia/Manila', 'Mon DD HH12:MI AM') || ')'
                || coalesce(': ' || trim_scale(l.gb) || ' GB', '') || coalesce(', expires ' || to_char(l.expires_on, 'Mon DD, YYYY'), '')
                || '. Recorded. Text: "' || left(tx.body, 200) || '"');
      else
        perform public.kiosk_alert_send('RSR Kiosk: ' || tx.nm || ' - ' || tx.prov || ' text ('
                || case tx.kind when 'expired' then 'EXPIRED' when 'expiring' then 'expiring' else 'data low' end || ', '
                || to_char(tx.received_at at time zone 'Asia/Manila', 'Mon DD HH12:MI AM') || '): "' || left(tx.body, 200) || '"');
      end if;
    end if;
    update public.kiosk_app_sms set notified = true where id = tx.id;
  end loop;
  -- a Wi-Fi password never waits on the server longer than the command itself (30 min)
  update public.kiosk_app_devices set cmd_arg = null
   where cmd = 'set_wifi' and cmd_arg is not null and cmd_at < now() - interval '30 minutes';

  -- keep the log small (free tier)
  delete from public.kiosk_app_events where at < now() - interval '60 days';
  -- free the 20-tablet cap from UNNAMED ids that never finished setup and stopped a week ago. Named tablets
  -- (Carmen, Mandaue) are never deleted here, so a long shutdown keeps their generator hours and history.
  delete from public.kiosk_app_devices where coalesce(name, '') = '' and last_seen < now() - interval '7 days';
  delete from public.kiosk_app_shots s where not exists (select 1 from public.kiosk_app_devices d where d.device_id = s.device_id);
  delete from public.kiosk_app_conn where coalesce(ended_at, now()) < now() - interval '60 days';
  -- rows of a forgotten tablet (factory reset = new id): gone after 30 days; load history kept
  delete from public.kiosk_app_conn c where not exists (select 1 from public.kiosk_app_devices d where d.device_id = c.device_id) and c.started_at < now() - interval '30 days';
  delete from public.kiosk_app_sms x where not exists (select 1 from public.kiosk_app_devices d where d.device_id = x.device_id) and x.received_at < now() - interval '30 days';
  delete from public.kiosk_app_data_days x where not exists (select 1 from public.kiosk_app_devices d where d.device_id = x.device_id) and x.day < v_today - 30;
  delete from public.kiosk_app_load_shots x where not exists (select 1 from public.kiosk_app_devices d where d.device_id = x.device_id);
  delete from public.kiosk_app_data_days where day < v_today - 400;
  delete from public.kiosk_app_sms where received_at < now() - interval '180 days' and load_id is null;
  delete from public.kiosk_app_sms where kind = 'otp' and created_at < now() - interval '15 minutes';   -- codes never kept
end $$;
revoke all on function public.kiosk_app_tick() from public, anon, authenticated;

-- STEP 7 - schedule (pg_cron runs in UTC; every 5 min needs no conversion)
do $$ begin perform cron.unschedule('kiosk-app-tick'); exception when others then null; end $$;
select cron.schedule('kiosk-app-tick', '*/5 * * * *', 'select public.kiosk_app_tick();');

-- STEP 8 - CHECK (read-only)
select jobname, schedule, active from cron.job where jobname = 'kiosk-app-tick';   -- expect 1 row, active
select public.kiosk_app_beat('{"device_id":"bad id"}'::jsonb);                       -- expect {}
select count(*) as tablets,                                                          -- 0 until a tablet runs the app
       to_regclass('public.kiosk_app_shots') is not null as shots_table,                 -- expect true
       to_regprocedure('public.kiosk_app_shot_put(text,text,text)') is not null as shot_put,   -- expect true
       to_regprocedure('public.kiosk_app_shot_get(text,text)') is not null as shot_get,        -- expect true
       (select count(*) from information_schema.columns where table_schema = 'public'
          and table_name = 'kiosk_app_devices' and column_name in ('page_version','page_error','page_error_at','shot_at')) as new_columns  -- expect 4
  from public.kiosk_app_devices;
-- build-6 check: expect 5 tables, 6 functions, 15 columns
select (select count(*) from information_schema.tables where table_schema = 'public'
          and table_name in ('kiosk_app_conn','kiosk_app_data_days','kiosk_app_sms','kiosk_app_loads','kiosk_app_load_shots')) as build6_tables,
       (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
          and proname in ('kiosk_app_sms_put','kiosk_app_load_add','kiosk_app_load_wait','kiosk_app_sim_set','kiosk_app_load_shot_get','kiosk_app_sim_info')) as build6_functions,
       (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'kiosk_app_devices'
          and column_name in ('net_type','net_since','mobile_alerted','mobile_signal','mobile_ok','mobile_bad_since','mobile_bad_alerted',
                              'sim_operator','sim_state','sms_ok','sim_provider','sim_close_days','sim_alerts','load_wait_from','battery_unrestricted')) as build6_columns;
