select current_database();
select count(*) from public.attendance_records;
select extname from pg_extension where extname in ('pg_cron','pg_net');
select to_regprocedure('public.kiosk_alert_send(text)')       as alert_send,
       to_regprocedure('public.admin_verify_passcode(text)')  as admin_verify,
       to_regclass('public.kiosk_app_devices')                as devices_before;
create table if not exists public.kiosk_app_devices (
  device_id         text primary key,
  name              text,
  kiosk_device_id   text,
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
alter table public.kiosk_app_devices add column if not exists unplugged_alerted_at timestamptz;
alter table public.kiosk_app_devices add column if not exists batt_step integer not null default 100;
alter table public.kiosk_app_devices add column if not exists wifi               boolean;
alter table public.kiosk_app_devices add column if not exists internet           boolean;
alter table public.kiosk_app_devices add column if not exists wifi_signal        integer;
alter table public.kiosk_app_devices add column if not exists battery_temp       numeric(4,1);
alter table public.kiosk_app_devices add column if not exists last_outage        jsonb;
alter table public.kiosk_app_devices add column if not exists offline_alerted_at timestamptz;
alter table public.kiosk_app_devices add column if not exists offline_first_at   timestamptz;
alter table public.kiosk_app_devices add column if not exists hot_alerted        boolean not null default false;
alter table public.kiosk_app_devices add column if not exists power_windows      text;
alter table public.kiosk_app_devices add column if not exists risk_alerted_for   timestamptz;
alter table public.kiosk_app_devices add column if not exists drain_on           numeric(5,2);
alter table public.kiosk_app_devices add column if not exists drain_off          numeric(5,2);
alter table public.kiosk_app_devices add column if not exists drain_on_n         integer not null default 0;
alter table public.kiosk_app_devices add column if not exists drain_off_n        integer not null default 0;
alter table public.kiosk_app_devices add column if not exists drain_anchor_at    timestamptz;
alter table public.kiosk_app_devices add column if not exists drain_anchor_batt  integer;
alter table public.kiosk_app_devices add column if not exists drain_anchor_screen boolean;
alter table public.kiosk_app_devices add column if not exists token             text;
alter table public.kiosk_app_devices add column if not exists token_confirmed   boolean not null default false;
alter table public.kiosk_app_devices add column if not exists charge_state      text;
alter table public.kiosk_app_devices add column if not exists weak_since        timestamptz;
alter table public.kiosk_app_devices add column if not exists weak_alerted      boolean not null default false;
alter table public.kiosk_app_devices add column if not exists page_version      text;
alter table public.kiosk_app_devices add column if not exists page_error        text;
alter table public.kiosk_app_devices add column if not exists page_error_at     timestamptz;
alter table public.kiosk_app_devices add column if not exists shot_at           timestamptz;
alter table public.kiosk_app_devices add column if not exists phone_mode        boolean not null default false;
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
create sequence if not exists public.kiosk_app_cmd_seq;
revoke all on sequence public.kiosk_app_cmd_seq from anon, authenticated;
create or replace function public.kiosk_app_ts(p text)
returns timestamptz language plpgsql immutable as $$
begin
  if p !~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' then return null; end if;
  return p::timestamptz;
exception when others then
  return null;
end $$;
revoke all on function public.kiosk_app_ts(text) from public, anon, authenticated;
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
  if v_ev !~ '^(started|setup done|tablet restarted|maintenance opened|maintenance ended \(auto\)|page crashed, rebuilt|page froze, reloaded|reload \(settings\)|full reload \(settings\)|updated to build [0-9]{1,6}|installing build [0-9]{1,6}|update install failed: -?[0-9]{1,3})$' then
    v_ev := '';
  end if;
  select k.token, k.token_confirmed into v_tok, v_conf from public.kiosk_app_devices k where k.device_id = v_id;
  if v_tok is not null then
    if (p->>'token') = v_tok then
      if not v_conf then update public.kiosk_app_devices k set token_confirmed = true where k.device_id = v_id; end if;
    elsif not v_conf and coalesce(p->>'token', '') = '' then
      v_new := v_tok;
    else
      return jsonb_build_object('error', 'token');
    end if;
  end if;
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
    page_version    = case when p->>'page_version' ~ '^v[0-9]{4}-[0-9]{2}-[0-9]{2}[a-z]?$' then p->>'page_version' else k.page_version end,
    page_error      = case when btrim(coalesce(p->>'page_error','')) <> ''
                           then left(regexp_replace(p->>'page_error', '[<>]', '', 'g'), 300) else k.page_error end,
    page_error_at   = case when btrim(coalesce(p->>'page_error','')) <> ''
                           then coalesce(least(public.kiosk_app_ts(p->>'page_error_at'), now()), now())
                           else k.page_error_at end,
    last_seen       = now(),
    unplugged_since = case when v_chg is false then coalesce(k.unplugged_since, now()) else null end
  where k.device_id = v_id
  returning * into d;
  if v_ev <> '' and v_ev <> 'started'
     and not exists (select 1 from public.kiosk_app_events x
                      where x.device_id = v_id and x.event = v_ev and x.at > now() - interval '60 seconds')
     and (select count(*) from public.kiosk_app_events x
           where x.device_id = v_id and x.at > now() - interval '1 hour') < 20 then
    insert into public.kiosk_app_events (device_id, event) values (v_id, v_ev);
  end if;
  if d.charging is false and d.battery is not null then
    if d.drain_anchor_at is null then
      update public.kiosk_app_devices k set drain_anchor_at = now(), drain_anchor_batt = d.battery,
             drain_anchor_screen = d.screen_on where k.device_id = v_id;
    elsif d.screen_on is distinct from d.drain_anchor_screen or d.drain_anchor_batt - d.battery >= 5
          or (d.drain_anchor_screen and v_prev < now() - interval '15 minutes') then
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
     and d.cmd_at > now() - interval '30 minutes' then
    return jsonb_build_object('cmd_id', d.cmd_id, 'cmd', d.cmd, 'arg', coalesce(d.cmd_arg,''))
           || case when v_new is not null then jsonb_build_object('token', v_new) else '{}'::jsonb end;
  end if;
  return case when v_new is not null then jsonb_build_object('token', v_new) else '{}'::jsonb end;
end $$;
revoke all on function public.kiosk_app_beat(jsonb) from public;
grant execute on function public.kiosk_app_beat(jsonb) to anon, authenticated;
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
create or replace function public.kiosk_app_list(p_passcode text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v jsonb;
begin
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
         ) order by k.name), '[]'::jsonb)
    into v from public.kiosk_app_devices k;
  return v;
end $$;
revoke all on function public.kiosk_app_list(text) from public;
grant execute on function public.kiosk_app_list(text) to anon, authenticated;
create or replace function public.kiosk_app_command(p_passcode text, p_device text, p_cmd text, p_arg text default '')
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_arg text := btrim(coalesce(p_arg,''));
begin
  if not public.admin_verify_passcode(p_passcode) then
    return jsonb_build_object('error', 'wrong passcode');
  end if;
  if p_cmd not in ('reload','hard_reload','restart','update','screen_on','screen_off','open_settings','schedule','screenshot') then
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
create or replace function public.kiosk_app_shot_put(p_device text, p_token text, p_jpeg text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  if not exists (select 1 from public.kiosk_app_devices k
                  where k.device_id = p_device and k.token is not null and k.token = p_token) then
    return jsonb_build_object('error', 'token');
  end if;
  if length(coalesce(p_jpeg, '')) > 700000 then return jsonb_build_object('error', 'too big'); end if;
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
  if not public.admin_verify_passcode(p_passcode) then
    return jsonb_build_object('error', 'wrong passcode');
  end if;
  select jsonb_build_object('taken_at', s.taken_at, 'jpeg', s.jpeg) into v
    from public.kiosk_app_shots s where s.device_id = p_device;
  return coalesce(v, jsonb_build_object('error', 'no screenshot yet'));
end $$;
revoke all on function public.kiosk_app_shot_get(text, text) from public;
grant execute on function public.kiosk_app_shot_get(text, text) to anon, authenticated;
create or replace function public.kiosk_app_dur(p interval)
returns text language sql immutable as $$
  select case when extract(epoch from p) >= 3600
              then floor(extract(epoch from p)/3600)::int || ' h ' || (floor(extract(epoch from p)/60)::int % 60) || ' min'
              else floor(extract(epoch from p)/60)::int || ' min' end
$$;
revoke all on function public.kiosk_app_dur(interval) from public, anon, authenticated;
create or replace function public.kiosk_app_hhmm(p text)
returns integer language sql immutable as $$
  select case when p ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
              then split_part(p, ':', 1)::int * 60 + split_part(p, ':', 2)::int end
$$;
revoke all on function public.kiosk_app_hhmm(text) from public, anon, authenticated;
create or replace function public.kiosk_app_awake_now(p_on text, p_off text)
returns boolean language plpgsql stable as $$
declare m int := extract(hour from (now() at time zone 'Asia/Manila'))*60 + extract(minute from (now() at time zone 'Asia/Manila'));
        a int := public.kiosk_app_hhmm(p_on); b int := public.kiosk_app_hhmm(p_off);
begin
  if a is null or b is null or a = b then return true; end if;
  return case when a < b then m >= a and m < b else m >= a or m < b end;
end $$;
revoke all on function public.kiosk_app_awake_now(text, text) from public, anon, authenticated;
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
    need := need + case when awake then r_on else r_off end / 4.0;
    t := t + interval '15 minutes'; n := n + 1;
  end loop;
  return ceil(need)::int;
end $$;
drop function if exists public.kiosk_app_need_pct(timestamptz, timestamptz, text, text);
revoke all on function public.kiosk_app_power_on(text, int) from public, anon, authenticated;
revoke all on function public.kiosk_app_power_state(text, int) from public, anon, authenticated;
revoke all on function public.kiosk_app_next_power(text, timestamptz) from public, anon, authenticated;
revoke all on function public.kiosk_app_need_pct(timestamptz, timestamptz, text, text, numeric, numeric) from public, anon, authenticated;
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
create or replace function public.kiosk_app_is_phone(p_url text)
returns boolean language sql immutable as $$
  select coalesce(lower(split_part(split_part(btrim(p_url), '?', 1), '#', 1))
                  like 'https://seafordprojects-bit.github.io/%/monitoring/%', false)
$$;
revoke all on function public.kiosk_app_is_phone(text) from public, anon, authenticated;
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
  v_win   boolean;
  v_pwr   boolean;
  v_next  timestamptz;
  v_need  int;
  v_state text;
  v_phone boolean;
begin
  v_work := (v_min >= 6*60 and v_min < 22*60);
  for r in select * from public.kiosk_app_devices loop
    v_name := coalesce(nullif(r.name,''), r.device_id);
    v_phone := case when public.kiosk_app_is_phone(r.page_url) then true
                    when lower(coalesce(r.page_url, '')) like 'https://seafordprojects-bit.github.io/%/kiosk/%' then false
                    else r.phone_mode end;
    if v_phone is distinct from r.phone_mode then
      update public.kiosk_app_devices set phone_mode = v_phone where device_id = r.device_id;
    end if;
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
      if r.offline_first_at is not null or r.unplugged_alerted then
        update public.kiosk_app_devices set offline_first_at = null, unplugged_alerted = false, unplugged_alerted_at = null
         where device_id = r.device_id;
      end if;
      continue;
    end if;
    v_on  := public.kiosk_app_hhmm(r.sched_on);
    v_off := public.kiosk_app_hhmm(r.sched_off);
    v_awake := case when v_on is null or v_off is null or v_on = v_off then true
                    when v_on < v_off then v_min >= v_on + 15 and v_min < v_off
                    else v_min >= v_on + 15 or v_min < v_off end;
    if r.last_seen < now() - interval '10 minutes' then
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
      continue;
    end if;
    if r.offline_first_at is not null then
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is back ONLINE.'
              || case when r.last_outage is not null and (r.last_outage->>'reported_at')::timestamptz > now() - interval '30 minutes'
                      then ' It was offline ' || public.kiosk_app_dur(((r.last_outage->>'minutes')::int || ' minutes')::interval)
                           || ' - ' || (r.last_outage->>'reason') || '.'
                      else '' end
              || ' Battery ' || coalesce(r.battery::text,'?') || '%.');
      update public.kiosk_app_devices set offline_first_at = null where device_id = r.device_id;
    end if;
    if r.weak_since is not null and r.weak_since < now() - interval '15 minutes' and not r.weak_alerted then
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is PLUGGED IN but NOT taking charge for '
              || public.kiosk_app_dur(now() - r.weak_since) || ' (battery ' || coalesce(r.battery::text,'?')
              || '%). Check the charger, cable and the power source (UPS / generator).');
      update public.kiosk_app_devices set weak_alerted = true where device_id = r.device_id;
    elsif r.weak_since is null and r.weak_alerted then
      update public.kiosk_app_devices set weak_alerted = false where device_id = r.device_id;
    end if;
    if r.battery_temp is not null and r.battery_temp >= 45 and not r.hot_alerted then
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is HOT - battery ' || r.battery_temp
              || ' C. Move it out of the sun / give it air. Heat damages the battery.');
      update public.kiosk_app_devices set hot_alerted = true where device_id = r.device_id;
    elsif r.hot_alerted and coalesce(r.battery_temp, 0) < 40 then
      update public.kiosk_app_devices set hot_alerted = false where device_id = r.device_id;
    end if;
    v_win := r.power_windows is not null;
    v_state := public.kiosk_app_power_state(r.power_windows, v_min);
    v_pwr := v_state = 'on' and public.kiosk_app_power_state(r.power_windows, greatest(v_min - 5, 0)) = 'on';
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
    if r.charging is false and r.battery is not null then
      if r.battery <= 10 and r.batt_step > 10 then
        perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' battery CRITICAL ' || r.battery
                || '% - it will switch off soon. Plug in NOW.');
        update public.kiosk_app_devices set batt_step = 10, low_batt_alerted = true where device_id = r.device_id;
      elsif not v_pwr then
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
  for e in select ev.id, ev.event, ev.at, coalesce(nullif(k.name,''), ev.device_id) as nm
             from public.kiosk_app_events ev
             left join public.kiosk_app_devices k on k.device_id = ev.device_id
            where not ev.notified and ev.at > now() - interval '1 hour'
            order by ev.at loop
    if e.event like 'tablet restarted%' or e.event like 'updated to build%'
       or e.event like 'maintenance opened%' or e.event like 'update install failed%'
       or e.event like 'installing build%' then
      v_sent := v_sent + 1;
      exit when v_sent > 5;
      perform public.kiosk_alert_send('RSR Kiosk: ' || e.nm || ' - ' || e.event || ' ('
              || to_char(e.at at time zone 'Asia/Manila', 'HH12:MI AM') || ')');
    end if;
    update public.kiosk_app_events set notified = true where id = e.id;
  end loop;
  delete from public.kiosk_app_events where at < now() - interval '60 days';
  delete from public.kiosk_app_devices where coalesce(name, '') = '' and last_seen < now() - interval '7 days';
  delete from public.kiosk_app_shots s where not exists (select 1 from public.kiosk_app_devices d where d.device_id = s.device_id);
end $$;
revoke all on function public.kiosk_app_tick() from public, anon, authenticated;
do $$ begin perform cron.unschedule('kiosk-app-tick'); exception when others then null; end $$;
select cron.schedule('kiosk-app-tick', '*/5 * * * *', 'select public.kiosk_app_tick();');
select jobname, schedule, active from cron.job where jobname = 'kiosk-app-tick';
select public.kiosk_app_beat('{"device_id":"bad id"}'::jsonb);
select count(*) as tablets,
       to_regclass('public.kiosk_app_shots') is not null as shots_table,
       to_regprocedure('public.kiosk_app_shot_put(text,text,text)') is not null as shot_put,
       to_regprocedure('public.kiosk_app_shot_get(text,text)') is not null as shot_get,
       (select count(*) from information_schema.columns where table_schema = 'public'
          and table_name = 'kiosk_app_devices' and column_name in ('page_version','page_error','page_error_at','shot_at')) as new_columns
  from public.kiosk_app_devices;
