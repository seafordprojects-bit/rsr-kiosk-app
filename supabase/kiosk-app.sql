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
--        - tablet restarted / app updated / maintenance opened / update failed
--      It reuses kiosk_alert_send (kiosk-alerts.sql). The existing "tablet went silent" alert
--      stays as it is, so there is no double offline alert.
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
  d      public.kiosk_app_devices%rowtype;
begin
  if v_id !~ '^app-[A-Za-z0-9]{1,64}$' then return '{}'::jsonb; end if;
  -- spam guard: at most 20 tablets ever register
  if not exists (select 1 from public.kiosk_app_devices x where x.device_id = v_id)
     and (select count(*) from public.kiosk_app_devices) >= 20 then
    return '{}'::jsonb;
  end if;

  insert into public.kiosk_app_devices as k (device_id) values (v_id)
  on conflict (device_id) do nothing;

  update public.kiosk_app_devices k set
    name            = left(coalesce(nullif(btrim(p->>'name'),''), k.name), 60),
    kiosk_device_id = left(coalesce(nullif(btrim(p->>'kiosk_device_id'),''), k.kiosk_device_id), 80),
    model           = left(p->>'model', 120),
    app_version     = nullif(p->>'app_version','')::integer,
    battery         = nullif(p->>'battery','')::integer,
    charging        = v_chg,
    screen_on       = (p->>'screen_on')::boolean,
    device_owner    = (p->>'device_owner')::boolean,
    maintenance     = (p->>'maintenance')::boolean,
    page_url        = left(p->>'page_url', 300),
    page_ok         = (p->>'page_ok')::boolean,
    sched_on        = case when p->>'sched_on'  ~ '^[0-2][0-9]:[0-5][0-9]$' then p->>'sched_on'  end,
    sched_off       = case when p->>'sched_off' ~ '^[0-2][0-9]:[0-5][0-9]$' then p->>'sched_off' end,
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

  if d.cmd_id is not null and d.cmd_id > coalesce(d.cmd_done_id, 0)
     and d.cmd_at > now() - interval '30 minutes' then   -- an old, never-picked-up command expires
    return jsonb_build_object('cmd_id', d.cmd_id, 'cmd', d.cmd, 'arg', coalesce(d.cmd_arg,''));
  end if;
  return '{}'::jsonb;
end $$;
revoke all on function public.kiosk_app_beat(jsonb) from public;
grant execute on function public.kiosk_app_beat(jsonb) to anon, authenticated;

-- STEP 3 - the app confirms a command
create or replace function public.kiosk_app_ack(p_device text, p_cmd_id bigint, p_result text)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  update public.kiosk_app_devices k
     set cmd_done_id = greatest(coalesce(k.cmd_done_id,0), p_cmd_id),
         cmd_result  = left(coalesce(p_result,''), 200),
         cmd_done_at = now()
   where k.device_id = p_device and k.cmd_id = p_cmd_id;
end $$;
revoke all on function public.kiosk_app_ack(text, bigint, text) from public;
grant execute on function public.kiosk_app_ack(text, bigint, text) to anon, authenticated;

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
begin
  v_work := (v_min >= 6*60 and v_min < 22*60);

  for r in select * from public.kiosk_app_devices loop
    v_name := coalesce(nullif(r.name,''), r.device_id);
    continue when r.last_seen < now() - interval '10 minutes';   -- silent tablet: the existing alert handles it

    -- NOT CHARGING: first alert after 5 min, then a reminder with the current battery %
    -- every 30 min (every 2 h at night, 10 PM - 6 AM) until the charger is back.
    if r.unplugged_since is not null and r.unplugged_since < now() - interval '5 minutes'
       and (r.unplugged_alerted_at is null
            or r.unplugged_alerted_at < now() - case when v_work then interval '30 minutes' else interval '2 hours' end) then
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is NOT CHARGING for '
              || public.kiosk_app_dur(now() - r.unplugged_since) || '. Battery '
              || coalesce(r.battery::text,'?') || '%. Please plug in the charger.');
      update public.kiosk_app_devices set unplugged_alerted = true, unplugged_alerted_at = now()
       where device_id = r.device_id;
    elsif r.unplugged_since is null and r.unplugged_alerted then
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is charging again. Battery '
              || coalesce(r.battery::text,'?') || '%. OK.');
      update public.kiosk_app_devices set unplugged_alerted = false, unplugged_alerted_at = null
       where device_id = r.device_id;
    end if;

    -- BATTERY DROPPING while not charging: one message each time it crosses 50%, 30%, 20%, 10%
    -- (sent even inside a reminder gap, so a fast drop is never missed).
    if r.charging is false and r.battery is not null then
      if r.battery <= 10 and r.batt_step > 10 then
        perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' battery CRITICAL ' || r.battery
                || '% - it will switch off soon. Plug in NOW.');
        update public.kiosk_app_devices set batt_step = 10, low_batt_alerted = true where device_id = r.device_id;
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
    elsif r.charging is true and (r.batt_step < 100 or r.low_batt_alerted) then
      update public.kiosk_app_devices set batt_step = 100, low_batt_alerted = false where device_id = r.device_id;
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
  -- free the 20-tablet cap from ids that stopped reporting a week ago (a real tablet re-registers on its next beat)
  delete from public.kiosk_app_devices where last_seen < now() - interval '7 days';
end $$;
revoke all on function public.kiosk_app_tick() from public, anon, authenticated;

-- STEP 7 - schedule (pg_cron runs in UTC; every 5 min needs no conversion)
do $$ begin perform cron.unschedule('kiosk-app-tick'); exception when others then null; end $$;
select cron.schedule('kiosk-app-tick', '*/5 * * * *', 'select public.kiosk_app_tick();');

-- STEP 8 - CHECK (read-only)
select jobname, schedule, active from cron.job where jobname = 'kiosk-app-tick';   -- expect 1 row, active
select public.kiosk_app_beat('{"device_id":"bad id"}'::jsonb);                       -- expect {}
select count(*) as tablets from public.kiosk_app_devices;                            -- 0 until a tablet runs the app
