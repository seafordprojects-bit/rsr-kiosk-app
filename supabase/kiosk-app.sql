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

create table if not exists public.kiosk_app_events (
  id         bigserial primary key,
  device_id  text not null,
  event      text not null,
  at         timestamptz not null default now(),
  notified   boolean not null default false
);
create index if not exists kiosk_app_events_dev_at on public.kiosk_app_events (device_id, at desc);
revoke all on public.kiosk_app_events from anon, authenticated;

create sequence if not exists public.kiosk_app_cmd_seq;
revoke all on sequence public.kiosk_app_cmd_seq from anon, authenticated;

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
begin
  if v_id !~ '^app-[A-Za-z0-9]{1,64}$' then return '{}'::jsonb; end if;
  -- Only exact app messages go into the log (they end up in Telegram); anything else is dropped.
  if v_ev !~ '^(started|setup done|tablet restarted|maintenance opened|maintenance ended \(auto\)|page crashed, rebuilt|page froze, reloaded|reload \(settings\)|full reload \(settings\)|updated to build [0-9]{1,6}|installing build [0-9]{1,6}|update install failed: -?[0-9]{1,3})$' then
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
  select k.last_seen into v_prev from public.kiosk_app_devices k where k.device_id = v_id;

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
    last_seen       = now(),
    unplugged_since = case when v_chg is false then coalesce(k.unplugged_since, now()) else null end
  where k.device_id = v_id
  returning * into d;

  -- event log, flood-guarded: same event within 60 s is dropped; max 20 events per tablet per hour
  if v_ev <> '' and v_ev <> 'started'
     and not exists (select 1 from public.kiosk_app_events x
                      where x.device_id = v_id and x.event = v_ev and x.at > now() - interval '60 seconds')
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

  if d.cmd_id is not null and d.cmd_id > coalesce(d.cmd_done_id, 0)
     and d.cmd_at > now() - interval '30 minutes' then   -- an old, never-picked-up command expires
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
         cmd_done_at = now()
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
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.kiosk_app_forget(text, text) from public;
grant execute on function public.kiosk_app_forget(text, text) to anon, authenticated;

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
           'drain_on', case when k.drain_on_n >= 3 then k.drain_on end, 'drain_off', case when k.drain_off_n >= 3 then k.drain_off end,
           'asleep', not public.kiosk_app_awake_now(k.sched_on, k.sched_off),
           'cmd', k.cmd, 'cmd_at', k.cmd_at, 'cmd_result', k.cmd_result, 'cmd_done_at', k.cmd_done_at,
           'pending', (k.cmd_id is not null and k.cmd_id > coalesce(k.cmd_done_id,0) and k.cmd_at > now() - interval '30 minutes'),
           'events', (select coalesce(jsonb_agg(jsonb_build_object('event', e.event, 'at', e.at) order by e.at desc), '[]'::jsonb)
                        from (select * from public.kiosk_app_events e2 where e2.device_id = k.device_id
                               order by e2.at desc limit 5) e)
         ) order by k.name), '[]'::jsonb)
    into v from public.kiosk_app_devices k;
  return v;
end $$;
revoke all on function public.kiosk_app_list(text) from public;
grant execute on function public.kiosk_app_list(text) to anon, authenticated;

-- STEP 5 - office page: send a command (admin passcode)
create or replace function public.kiosk_app_command(p_passcode text, p_device text, p_cmd text, p_arg text default '')
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_arg text := btrim(coalesce(p_arg,''));
begin
  -- Return (never raise) on a wrong passcode: raising would roll back the wrong-try counter
  -- inside admin_verify_passcode and remove its brute-force lockout.
  if not public.admin_verify_passcode(p_passcode) then
    return jsonb_build_object('error', 'wrong passcode');
  end if;
  if p_cmd not in ('reload','hard_reload','restart','update','screen_on','screen_off','open_settings','schedule') then
    return jsonb_build_object('error', 'unknown command');
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
  values (p_device, 'office: ' || p_cmd || case when v_arg <> '' then ' ' || v_arg else '' end, true);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.kiosk_app_command(text, text, text, text) from public;
grant execute on function public.kiosk_app_command(text, text, text, text) to anon, authenticated;

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
            (extract(hour from (now() at time zone 'Asia/Manila'))*60 + extract(minute from (now() at time zone 'Asia/Manila')))::int) as state) st) x
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
begin
  v_work := (v_min >= 6*60 and v_min < 22*60);

  for r in select * from public.kiosk_app_devices loop
    v_name := coalesce(nullif(r.name,''), r.device_id);

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
            or r.unplugged_alerted_at < now() - case when v_work or v_win then interval '30 minutes' else interval '2 hours' end) then
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is NOT CHARGING'
              || case when v_win then ' although the generator should be ON (check charger, cable, plug)' else '' end
              || case when v_win then '' else ' for ' || public.kiosk_app_dur(now() - r.unplugged_since) end
              || '. Battery '
              || coalesce(r.battery::text,'?') || '%. Please plug in the charger.');
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
  for e in select ev.id, ev.event, ev.at, coalesce(nullif(k.name,''), ev.device_id) as nm
             from public.kiosk_app_events ev
             left join public.kiosk_app_devices k on k.device_id = ev.device_id
            where not ev.notified and ev.at > now() - interval '1 hour'
            order by ev.at loop
    if e.event like 'tablet restarted%' or e.event like 'updated to build%'
       or e.event like 'maintenance opened%' or e.event like 'update install failed%'
       or e.event like 'installing build%' then
      v_sent := v_sent + 1;
      exit when v_sent > 5;                       -- at most 5 event messages per 5-minute tick
      perform public.kiosk_alert_send('RSR Kiosk: ' || e.nm || ' - ' || e.event || ' ('
              || to_char(e.at at time zone 'Asia/Manila', 'HH12:MI AM') || ')');
    end if;
    update public.kiosk_app_events set notified = true where id = e.id;
  end loop;

  -- keep the log small (free tier)
  delete from public.kiosk_app_events where at < now() - interval '60 days';
  -- free the 20-tablet cap from UNNAMED ids that never finished setup and stopped a week ago. Named tablets
  -- (Carmen, Mandaue) are never deleted here, so a long shutdown keeps their generator hours and history.
  delete from public.kiosk_app_devices where coalesce(name, '') = '' and last_seen < now() - interval '7 days';
end $$;
revoke all on function public.kiosk_app_tick() from public, anon, authenticated;

-- STEP 7 - schedule (pg_cron runs in UTC; every 5 min needs no conversion)
do $$ begin perform cron.unschedule('kiosk-app-tick'); exception when others then null; end $$;
select cron.schedule('kiosk-app-tick', '*/5 * * * *', 'select public.kiosk_app_tick();');

-- STEP 8 - CHECK (read-only)
select jobname, schedule, active from cron.job where jobname = 'kiosk-app-tick';   -- expect 1 row, active
select public.kiosk_app_beat('{"device_id":"bad id"}'::jsonb);                       -- expect {}
select count(*) as tablets from public.kiosk_app_devices;                            -- 0 until a tablet runs the app
