select current_database();
select count(*) from public.attendance_records;
select extname from pg_extension where extname in ('pg_cron','pg_net');
select to_regprocedure('public.kiosk_alert_send(text)')       as alert_send,
       to_regprocedure('public.admin_verify_passcode(text)')  as admin_verify,
       to_regclass('public.kiosk_app_devices')                as devices_before;
select tgname from pg_trigger where tgrelid = to_regclass('public.kiosk_app_devices') and not tgisinternal;
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
alter table public.kiosk_app_devices add column if not exists net_type          text;
alter table public.kiosk_app_devices add column if not exists net_since         timestamptz;
alter table public.kiosk_app_devices add column if not exists mobile_alerted    boolean not null default false;
alter table public.kiosk_app_devices add column if not exists mobile_signal     integer;
alter table public.kiosk_app_devices add column if not exists mobile_ok         boolean;
alter table public.kiosk_app_devices add column if not exists mobile_bad_since  timestamptz;
alter table public.kiosk_app_devices add column if not exists mobile_bad_alerted boolean not null default false;
alter table public.kiosk_app_devices add column if not exists sim_operator      text;
alter table public.kiosk_app_devices add column if not exists sim_state         text;
alter table public.kiosk_app_devices add column if not exists sms_ok            boolean;
alter table public.kiosk_app_devices add column if not exists sim_provider      text;
alter table public.kiosk_app_devices add column if not exists sim_close_days    integer;
alter table public.kiosk_app_devices add column if not exists sim_alerts        jsonb not null default '{}'::jsonb;
alter table public.kiosk_app_devices add column if not exists load_wait_from    timestamptz;
alter table public.kiosk_app_devices add column if not exists battery_unrestricted boolean;
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
alter table public.kiosk_app_conn enable row level security;
create table if not exists public.kiosk_app_data_days (
  device_id  text not null,
  day        date not null,
  bytes      bigint not null default 0,
  primary key (device_id, day)
);
revoke all on public.kiosk_app_data_days from public, anon, authenticated;
alter table public.kiosk_app_data_days enable row level security;
create table if not exists public.kiosk_app_sms (
  id           bigserial primary key,
  device_id    text not null,
  sender       text not null,
  body         text not null,
  received_at  timestamptz not null default now(),
  kind         text not null default 'other',
  notified     boolean not null default false,
  load_id      bigint
);
create index if not exists kiosk_app_sms_dev on public.kiosk_app_sms (device_id, received_at desc);
alter table public.kiosk_app_sms add column if not exists created_at timestamptz not null default now();
revoke all on public.kiosk_app_sms from public, anon, authenticated;
alter table public.kiosk_app_sms enable row level security;
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
alter table public.kiosk_app_loads enable row level security;
create table if not exists public.kiosk_app_load_shots (
  load_id    bigint primary key,
  device_id  text not null,
  jpeg       text not null
);
revoke all on public.kiosk_app_load_shots from public, anon, authenticated;
alter table public.kiosk_app_load_shots enable row level security;
create table if not exists public.kiosk_app_modem (
  device_id      text primary key,
  host           text,
  cum_bytes      bigint not null default 0,
  last_total     bigint,
  last_secs      bigint,
  last_read_at   timestamptz,
  first_read_at  timestamptz,
  day_bytes      bigint,
  month_bytes    bigint,
  inbox          integer,
  restarts       integer not null default 0,
  load_gb        numeric(8,2),
  load_date      date,
  load_at        timestamptz,
  load_cum       bigint,
  alerted_gb     integer,
  test_from      date,
  test_until     date,
  test_last      date,
  test_summary   boolean not null default true,
  weekly_last    date,
  read_fail_alerted  boolean not null default false,
  inbox_full_alerted boolean not null default false
);
alter table public.kiosk_app_modem add column if not exists month_clear date;
revoke all on public.kiosk_app_modem from public, anon, authenticated;
alter table public.kiosk_app_modem enable row level security;
create table if not exists public.kiosk_app_modem_reads (
  id           bigserial primary key,
  device_id    text not null,
  at           timestamptz not null,
  total_bytes  bigint not null,
  total_secs   bigint,
  day_bytes    bigint,
  inbox        integer,
  cum_bytes    bigint not null,
  restarted    boolean not null default false
);
create index if not exists kiosk_app_modem_reads_dev on public.kiosk_app_modem_reads (device_id, at desc);
revoke all on public.kiosk_app_modem_reads from public, anon, authenticated;
alter table public.kiosk_app_modem_reads enable row level security;
revoke all on sequence public.kiosk_app_modem_reads_id_seq from public, anon, authenticated;
alter table public.kiosk_app_devices add column if not exists modem_err text;
alter table public.kiosk_app_devices add column if not exists batt_health       text;
alter table public.kiosk_app_devices add column if not exists batt_cycles       integer;
alter table public.kiosk_app_devices add column if not exists batt_design_mah   integer;
alter table public.kiosk_app_devices add column if not exists batt_cap_mah      numeric(7,1);
alter table public.kiosk_app_devices add column if not exists batt_cap_n        integer not null default 0;
alter table public.kiosk_app_devices add column if not exists batt_wear_alerted integer;
alter table public.kiosk_app_devices add column if not exists batt_bad_alerted  boolean not null default false;
alter table public.kiosk_app_devices add column if not exists batt_cap_at       timestamptz;
alter table public.kiosk_app_devices add column if not exists sleep_from        timestamptz;
alter table public.kiosk_app_devices add column if not exists sleep_until       timestamptz;
alter table public.kiosk_app_devices add column if not exists deep_sleep_until  timestamptz;
alter table public.kiosk_app_devices add column if not exists deep_sleep_reason text;
alter table public.kiosk_app_devices add column if not exists sleep_missed_alerted boolean not null default false;
alter table public.kiosk_app_devices add column if not exists power_last_at     timestamptz;
create table if not exists public.kiosk_app_power_log (
  id         bigserial primary key,
  device_id  text not null,
  off_at     timestamptz not null,
  on_at      timestamptz,
  batt_off   integer,
  batt_on    integer,
  died_at    timestamptz,
  booted_at  timestamptz
);
alter table public.kiosk_app_power_log add column if not exists back_unknown boolean not null default false;
create index if not exists kiosk_app_power_log_dev on public.kiosk_app_power_log (device_id, off_at desc);
revoke all on public.kiosk_app_power_log from public, anon, authenticated;
alter table public.kiosk_app_power_log enable row level security;
revoke all on sequence public.kiosk_app_power_log_id_seq from public, anon, authenticated;
alter table public.kiosk_app_devices add column if not exists batt_bad_at       timestamptz;
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
create or replace function public.kiosk_app_sms_kind(p_body text)
returns text language sql immutable as $$
  select case
    when (p_body ~* '(otp|one-?time (pin|password|code)|verification code|security code|\mcode|\mpin)[^0-9]{0,25}\m[0-9]{4,8}\M'
          or p_body ~* '\m[0-9]{4,8}\M[^0-9]{0,6}(is|as) your[^0-9.]{0,20}(otp|code|pin)')
         and p_body !~* '(successfully|registered|subscribed|purchased|reloaded|valid until|valid till|expire|expiring|\mgb\M|\mmb\M)' then 'otp'
    when p_body ~* '(\mfree\M|freebie|\mbonus\M|\mgift|pasaload|share-?a-?load|from (\+?63|0)9[0-9]|\mdial\M|\*[0-9]{2,4}#|register now|avail now|\mget [0-9]+\s*gb|\mbuy now|\moffer\M|limited time|until supplies)' then 'other'
    when p_body ~* '\myour\M[^.]{0,80}(has expired|have expired|is expired|already expired|expired na|nag-?expire na)' then 'expired'
    when p_body ~* '(you have (successfully )?(registered|subscribed|purchased|bought|loaded|reloaded)|successfully (registered|subscribed|purchased|loaded|reloaded)|registration .*successful|you are now (registered|subscribed)|thank you for (loading|reloading|purchasing|subscribing|registering))'
         and p_body ~* '([0-9]+(\.[0-9]+)?\s*(gb|mb)|data|valid|day|expir|promo)' then 'load'
    when p_body ~* '\myour\M[^.]{0,80}(will expire|expiring|expires (on|in|today|tomorrow)|valid until|valid till)' then 'expiring'
    when p_body ~* '\myour\M[^.]{0,80}(running low|is low|low data|only [0-9.]+\s*(gb|mb).* left|remaining (data|balance).* [0-9.]+\s*(gb|mb)|used up|consumed)' then 'low'
    else 'other' end
$$;
revoke all on function public.kiosk_app_sms_kind(text) from public, anon, authenticated;
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
  return null;
end $$;
revoke all on function public.kiosk_app_text_date(text) from public, anon, authenticated;
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
create or replace function public.kiosk_app_beat(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_id   text := btrim(coalesce(p->>'device_id',''));
  v_chg  boolean := (p->>'charging')::boolean;
  v_ev   text := left(btrim(coalesce(p->>'event','')), 120);
  v_out  jsonb := case when jsonb_typeof(p->'outage') = 'object' then p->'outage' end;
  v_otxt text;
  v_prev timestamptz;
  v_full integer;
  v_plan jsonb := '{}'::jsonb;
  v_wear integer;
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
  if v_ev !~ '^(started|setup done|tablet restarted|maintenance opened|maintenance ended \(auto\)|page crashed, rebuilt|page froze, reloaded|reload \(settings\)|full reload \(settings\)|updated to build [0-9]{1,6}|installing build [0-9]{1,6}|update install failed: -?[0-9]{1,3}|screen on failed|screen on needed a second try|screen woken by phone call|deep sleep \((power cut|holiday)\) until [A-Z][a-z]{2} [0-9]{1,2} [0-9]{1,2}:[0-9]{2} (AM|PM)(, battery [0-9]{1,3}%)?|woke from deep sleep \((power back|wake time|screen turned on|screen touched|phone call|office Screen on|plan cancelled|tablet restarted)\)(, battery [0-9]{1,3}%)?)$' then
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
  select k.last_seen, k.net_type into v_prev, v_old_nt from public.kiosk_app_devices k where k.device_id = v_id;
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
    modem_err       = nullif(left(regexp_replace(coalesce(p->>'modem_err', ''), '[^[:alnum:] ./()-]', '', 'g'), 60), ''),
    batt_health     = case when p->>'batt_health' in ('good','overheat','dead','over_voltage','failure','cold') then p->>'batt_health' else k.batt_health end,
    batt_cycles     = case when p->>'batt_cycles' ~ '^[0-9]{1,5}$' then (p->>'batt_cycles')::integer else k.batt_cycles end,
    batt_design_mah = case when p->>'batt_design_mah' ~ '^[0-9]{3,5}$' and (p->>'batt_design_mah')::integer between 500 and 30000
                           then (p->>'batt_design_mah')::integer else k.batt_design_mah end,
    last_seen       = now(),
    unplugged_since = case when v_chg is false then coalesce(k.unplugged_since, now()) else null end
  where k.device_id = v_id
  returning * into d;
  if v_ev <> '' and v_ev <> 'started'
     and not exists (select 1 from public.kiosk_app_events x
                      where x.device_id = v_id and x.event = v_ev
                        and x.at > now() - case when v_ev = 'screen woken by phone call' then interval '15 seconds'
                                                else interval '60 seconds' end)
     and (select count(*) from public.kiosk_app_events x
           where x.device_id = v_id and x.at > now() - interval '1 hour') < 20 then
    if v_ev = 'screen woken by phone call' then
      insert into public.kiosk_app_events (device_id, event, notified) values (v_id, v_ev, true);
      perform public.kiosk_alert_send('RSR Kiosk: ' || coalesce(nullif(d.name, ''), v_id) || ' - screen woken by your phone call. ('
              || to_char(now() at time zone 'Asia/Manila', 'HH12:MI:SS AM') || ')');
    elsif v_ev like 'deep sleep (%' or v_ev like 'woke from deep sleep (%' then
      insert into public.kiosk_app_events (device_id, event, notified) values (v_id, v_ev, true);
      perform public.kiosk_alert_send('RSR Kiosk: ' || coalesce(nullif(d.name, ''), v_id) || ' - '
              || case when v_ev like 'deep sleep (%' then upper(left(v_ev, 10)) || substr(v_ev, 11)
                        || '. Screen and Wi-Fi off; a short report every 12 hours. Any touch, the power button, a call or the charger wakes it.'
                      else v_ev || '. Ready for punches.' end);
    else
      insert into public.kiosk_app_events (device_id, event) values (v_id, v_ev);
    end if;
  end if;
  if coalesce(p->>'batt_full_mah', '') ~ '^[0-9]{3,5}$' and (d.batt_cap_at is null or d.batt_cap_at < now() - interval '30 minutes') then
    v_full := (p->>'batt_full_mah')::integer;
    if v_full between 500 and 30000 and (d.batt_design_mah is null or v_full between d.batt_design_mah * 0.3 and d.batt_design_mah * 1.3) then
      update public.kiosk_app_devices k set
        batt_cap_mah = case when k.batt_cap_mah is null or k.batt_cap_n = 0 then v_full
                            when k.batt_cap_n < 30 then round((k.batt_cap_mah * k.batt_cap_n + v_full) / (k.batt_cap_n + 1), 1)
                            else round(k.batt_cap_mah * 0.95 + v_full * 0.05, 1) end,
        batt_cap_n = least(k.batt_cap_n + 1, 1000000),
        batt_cap_at = now()
       where k.device_id = v_id
       returning k.batt_cap_mah, k.batt_cap_n into d.batt_cap_mah, d.batt_cap_n;
    end if;
  end if;
  if d.batt_cap_n >= 30 and d.batt_design_mah > 0 then
    v_wear := round(d.batt_cap_mah / d.batt_design_mah * 100);
    if v_wear < 65 and coalesce(d.batt_wear_alerted, 100) > 65 then
      update public.kiosk_app_devices k set batt_wear_alerted = 65 where k.device_id = v_id;
      perform public.kiosk_alert_send('RSR Kiosk: ' || coalesce(nullif(d.name, ''), v_id) || ' - BATTERY WORN OUT: a full charge holds only about '
              || v_wear || '% of a new battery (' || round(d.batt_cap_mah) || ' of ' || d.batt_design_mah
              || ' mAh). It runs down fast - REPLACE the battery soon (Samsung service center).');
    elsif v_wear < 80 and v_wear >= 65 and coalesce(d.batt_wear_alerted, 100) > 80 then
      update public.kiosk_app_devices k set batt_wear_alerted = 80 where k.device_id = v_id;
      perform public.kiosk_alert_send('RSR Kiosk: ' || coalesce(nullif(d.name, ''), v_id) || ' - battery is wearing: a full charge holds about '
              || v_wear || '% of a new battery (' || round(d.batt_cap_mah) || ' of ' || d.batt_design_mah
              || ' mAh). Plan a battery replacement.');
    elsif v_wear >= 85 and d.batt_wear_alerted is not null then
      update public.kiosk_app_devices k set batt_wear_alerted = null where k.device_id = v_id;
    end if;
  end if;
  if d.batt_health in ('dead','over_voltage','failure') then
    if d.batt_bad_at is null or d.batt_bad_at < now() - interval '24 hours' then
      perform public.kiosk_alert_send('RSR Kiosk: ' || coalesce(nullif(d.name, ''), v_id) || ' - Android reports the battery as '
              || upper(replace(d.batt_health, '_', ' ')) || '. '
              || case when d.batt_health = 'over_voltage' then 'Check the charger and cable first (use the original Samsung charger).'
                      else 'Replace the battery (Samsung service center).' end);
      update public.kiosk_app_devices k set batt_bad_at = now(), batt_bad_alerted = true where k.device_id = v_id;
    end if;
  elsif d.batt_health = 'good' and d.batt_bad_alerted then
    update public.kiosk_app_devices k set batt_bad_alerted = false where k.device_id = v_id;
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
  if v_nt is not null and v_nt is distinct from v_old_nt then
    update public.kiosk_app_conn c set ended_at = now()
     where c.device_id = v_id and c.ended_at is null and c.kind in ('mobile','none');
    if v_nt in ('mobile','none') then
      insert into public.kiosk_app_conn (device_id, kind, started_at) values (v_id, v_nt, now());
    end if;
  end if;
  if v_out is not null and v_out->>'minutes' ~ '^[0-9]{1,5}$' and (v_out->>'minutes')::int >= 2
     and v_out->>'reason' in ('Wi-Fi off / not connected', 'Wi-Fi connected but no internet', 'internet OK but server not reachable')
     and not exists (select 1 from public.kiosk_app_conn c where c.device_id = v_id and c.kind = 'offline'
                       and c.ended_at > now() - interval '5 minutes') then
    insert into public.kiosk_app_conn (device_id, kind, started_at, ended_at, reason)
    values (v_id, 'offline', now() - make_interval(mins => least((v_out->>'minutes')::int, 20000)), now(), v_out->>'reason');
  end if;
  if jsonb_typeof(p->'mobile_days') = 'object' then
    for v_day in select jsonb_object_keys(p->'mobile_days') loop
      continue when v_day !~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}$' or (p->'mobile_days'->>v_day) !~ '^[0-9]{1,13}$';
      continue when public.kiosk_app_text_date(v_day) is null or public.kiosk_app_text_date(v_day) not between v_today - 2 and v_today;
      insert into public.kiosk_app_data_days as x (device_id, day, bytes) values (v_id, public.kiosk_app_text_date(v_day), (p->'mobile_days'->>v_day)::bigint)
      on conflict (device_id, day) do update set bytes = greatest(x.bytes, excluded.bytes);
    end loop;
  end if;
  if v_tok is not null and v_new is null then
    update public.kiosk_app_devices k set
      deep_sleep_until = case when jsonb_typeof(p->'deep_sleep') = 'object' then public.kiosk_app_ts(p->'deep_sleep'->>'until') end,
      deep_sleep_reason = case when jsonb_typeof(p->'deep_sleep') = 'object' and p->'deep_sleep'->>'reason' in ('power cut','holiday')
                               then p->'deep_sleep'->>'reason' end,
      sleep_missed_alerted = false
     where k.device_id = v_id;
    if jsonb_typeof(p->'power_events') = 'array' then
      begin
        perform public.kiosk_app_power_put(v_id, p->'power_events');
      exception when others then null;
      end;
    end if;
  end if;
  if v_tok is not null and v_new is null then
    if jsonb_typeof(p->'modem') = 'object' then
      begin
        perform public.kiosk_app_modem_put(v_id, p->'modem');
      exception when others then null;
      end;
    end if;
  end if;
  v_plan := case when v_tok is not null and v_new is null
                 then jsonb_build_object('power_windows', coalesce(d.power_windows, ''),
                        'sleep_from', coalesce(to_char(d.sleep_from at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), ''),
                        'sleep_until', coalesce(to_char(d.sleep_until at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), ''))
                 else '{}'::jsonb end;
  if d.cmd_id is not null and d.cmd_id > coalesce(d.cmd_done_id, 0)
     and d.cmd_at > now() - interval '30 minutes'
     and (d.cmd <> 'set_wifi' or d.token_confirmed) then
    return jsonb_build_object('cmd_id', d.cmd_id, 'cmd', d.cmd, 'arg', coalesce(d.cmd_arg,''))
           || case when v_new is not null then jsonb_build_object('token', v_new) else '{}'::jsonb end
           || v_plan;
  end if;
  return case when v_new is not null then jsonb_build_object('token', v_new) else '{}'::jsonb end || v_plan;
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
         cmd_done_at = now(),
         cmd_arg     = case when k.cmd = 'set_wifi' then null else k.cmd_arg end
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
create or replace function public.kiosk_app_down_min(p_device text, p_from timestamptz)
returns integer language sql stable as $$
  select coalesce(round(sum(extract(epoch from (upper(r) - lower(r)))) / 60.0)::int, 0)
    from (select unnest(range_agg(tstzrange(greatest(c.started_at, p_from), e.t))) r
            from public.kiosk_app_conn c
            cross join lateral (select least(coalesce(c.ended_at,
                     (select d.last_seen + interval '2 minutes' from public.kiosk_app_devices d where d.device_id = c.device_id), now()), now()) t) e
           where c.device_id = p_device and e.t > greatest(c.started_at, p_from)) x
$$;
revoke all on function public.kiosk_app_down_min(text, timestamptz) from public, anon, authenticated;
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
                                      'code', public.kiosk_app_otp_code(x.body))
              from public.kiosk_app_sms x where x.device_id = p_device and x.kind = 'otp'
               and x.created_at > now() - interval '15 minutes' order by x.created_at desc limit 1));
end $$;
revoke all on function public.kiosk_app_sim_info(text) from public, anon, authenticated;
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
           'last_seen', k.last_seen, 'online', k.last_seen > now() - interval '3 minutes', 'unplugged_since', k.unplugged_since,
           'wifi', k.wifi, 'internet', k.internet, 'wifi_signal', k.wifi_signal,
           'battery_temp', k.battery_temp, 'last_outage', k.last_outage, 'power_windows', k.power_windows,
           'page_version', k.page_version, 'page_error', k.page_error, 'page_error_at', k.page_error_at, 'shot_at', k.shot_at,
           'drain_on', case when k.drain_on_n >= 3 then k.drain_on end, 'drain_off', case when k.drain_off_n >= 3 then k.drain_off end,
           'batt_health', k.batt_health, 'batt_cycles', k.batt_cycles, 'batt_design_mah', k.batt_design_mah,
           'batt_cap_mah', case when k.batt_cap_n >= 30 then round(k.batt_cap_mah) end,
           'batt_cap_n', k.batt_cap_n,
           'batt_wear_pct', case when k.batt_cap_n >= 30 and k.batt_design_mah > 0 then least(100, round(k.batt_cap_mah / k.batt_design_mah * 100)) end,
           'asleep', not public.kiosk_app_awake_now(k.sched_on, k.sched_off) or k.deep_sleep_until > now(),
           'phone', k.phone_mode or public.kiosk_app_is_phone(k.page_url),
           'cmd', k.cmd, 'cmd_at', k.cmd_at, 'cmd_result', k.cmd_result, 'cmd_done_at', k.cmd_done_at,
           'pending', (k.cmd_id is not null and k.cmd_id > coalesce(k.cmd_done_id,0) and k.cmd_at > now() - interval '30 minutes'),
           'events', (select coalesce(jsonb_agg(jsonb_build_object('event', e.event, 'at', e.at) order by e.at desc), '[]'::jsonb)
                        from (select * from public.kiosk_app_events e2 where e2.device_id = k.device_id
                               order by e2.at desc limit 5) e)
         ) || jsonb_build_object(
           'battery_unrestricted', k.battery_unrestricted,
           'net', jsonb_build_object('type', k.net_type, 'since', k.net_since, 'mobile_signal', k.mobile_signal, 'mobile_ok', k.mobile_ok,
                    'down_today_min', public.kiosk_app_down_min(k.device_id, (date_trunc('day', now() at time zone 'Asia/Manila')) at time zone 'Asia/Manila'),
                    'down_7d_min', public.kiosk_app_down_min(k.device_id, now() - interval '7 days'),
                    'periods', (select coalesce(jsonb_agg(jsonb_build_object('kind', c.kind, 'from', c.started_at, 'to', c.ended_at, 'reason', c.reason)
                                                          order by c.started_at desc), '[]'::jsonb)
                                  from (select * from public.kiosk_app_conn c2 where c2.device_id = k.device_id
                                         order by c2.started_at desc limit 15) c)),
           'punches', (select jsonb_build_object('queue', h.j->'queue_length', 'offline_queue', h.j->'offline_queue_length',
                                'stuck', h.j->'stuck_count', 'stuck_details', h.j->'stuck_details',
                                'oldest_unsynced_at', h.j->'oldest_unsynced_at', 'reported_at', h.j->'last_seen')
                         from (select to_jsonb(kh) as j from public.kiosk_health kh where kh.device_id = k.kiosk_device_id) h),
           'sim', public.kiosk_app_sim_info(k.device_id),
           'modem', public.kiosk_app_modem_info(k.device_id), 'modem_err', k.modem_err,
           'sleep_from', k.sleep_from, 'sleep_until', k.sleep_until,
           'deep_sleep_until', case when k.deep_sleep_until > now() then k.deep_sleep_until end, 'deep_sleep_reason', k.deep_sleep_reason,
           'power', public.kiosk_app_power_info(k.device_id)
         ) order by k.name), '[]'::jsonb)
    into v from public.kiosk_app_devices k;
  return v;
end $$;
revoke all on function public.kiosk_app_list(text) from public;
grant execute on function public.kiosk_app_list(text) to anon, authenticated;
create or replace function public.kiosk_app_command(p_passcode text, p_device text, p_cmd text, p_arg text default '')
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_arg text := btrim(coalesce(p_arg,'')); v_wifi jsonb; v_log text;
begin
  if not public.admin_verify_passcode(p_passcode) then
    return jsonb_build_object('error', 'wrong passcode');
  end if;
  if p_cmd not in ('reload','hard_reload','restart','update','screen_on','screen_off','open_settings','schedule','screenshot',
                   'retry_punches','set_wifi','read_modem') then
    return jsonb_build_object('error', 'unknown command');
  end if;
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
    v_log := 'set_wifi ' || regexp_replace(v_wifi->>'ssid', '[^[:alnum:] ._-]', '', 'g');
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
create or replace function public.kiosk_app_otp_code(p_body text)
returns text language sql immutable set search_path = public as $$
  select coalesce((regexp_match(p_body, '(otp|one-?time (pin|password|code)|verification code|security code|\mcode|\mpin)[^0-9]{0,25}\m([0-9]{4,8})\M', 'i'))[3],
                  (regexp_match(p_body, '\m([0-9]{4,8})\M[^0-9]{0,6}(is|as) your', 'i'))[1])
$$;
revoke all on function public.kiosk_app_otp_code(text) from public, anon, authenticated;
create or replace function public.kiosk_app_sms_alert(p_id bigint)
returns boolean language plpgsql volatile security definer set search_path = public as $$
declare
  tx record;
  l  public.kiosk_app_loads%rowtype;
  v_t text;
begin
  update public.kiosk_app_sms x set notified = true where x.id = p_id and not x.notified;
  if not found then return false; end if;
  select x.id, x.kind, x.body, x.received_at, x.created_at, x.load_id, coalesce(nullif(k.name,''), x.device_id) as nm,
         coalesce(k.sim_provider, k.sim_operator, x.sender) as prov
    into tx
    from public.kiosk_app_sms x left join public.kiosk_app_devices k on k.device_id = x.device_id
   where x.id = p_id;
  if tx.kind = 'other' or tx.received_at < now() - interval '2 days' then return false; end if;
  if tx.kind = 'otp' and (tx.received_at < now() - interval '15 minutes' or tx.created_at < now() - interval '15 minutes') then
    return false;
  end if;
  v_t := to_char(tx.received_at at time zone 'Asia/Manila', 'Mon DD HH12:MI AM');
  if tx.kind = 'otp' then
    perform public.kiosk_alert_send('RSR Kiosk: ' || tx.nm || ' - ' || tx.prov || ' CODE: '
            || coalesce(public.kiosk_app_otp_code(tx.body), '(see text)') || '  (' || v_t
            || '). Use it now - it expires in a few minutes. Text: "' || left(tx.body, 200) || '"');
  elsif tx.kind = 'load' then
    select * into l from public.kiosk_app_loads x where x.id = tx.load_id;
    perform public.kiosk_alert_send('RSR Kiosk: ' || tx.nm || ' - LOAD RECEIVED (' || tx.prov || ' text, ' || v_t || ')'
            || coalesce(': ' || trim_scale(l.gb) || ' GB', '') || coalesce(', expires ' || to_char(l.expires_on, 'Mon DD, YYYY'), '')
            || '. Recorded. Text: "' || left(tx.body, 200) || '"');
  else
    perform public.kiosk_alert_send('RSR Kiosk: ' || tx.nm || ' - ' || tx.prov || ' text ('
            || case tx.kind when 'expired' then 'EXPIRED' when 'expiring' then 'expiring' else 'data low' end || ', '
            || v_t || '): "' || left(tx.body, 200) || '"');
  end if;
  return true;
end $$;
revoke all on function public.kiosk_app_sms_alert(bigint) from public, anon, authenticated;
create or replace function public.kiosk_app_sms_put(p_device text, p_token text, p_sender text, p_body text, p_at text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_from text := left(regexp_replace(btrim(coalesce(p_sender,'')), '[^[:alnum:] ._+-]', '', 'g'), 20);
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
  if not (v_from ~* '(dito|gomo|globe|\mtm\M|smart|\mtnt\M|\msun\M)' or v_from ~ '^[0-9]{3,5}$') then
    return jsonb_build_object('ok', true, 'ignored', true);
  end if;
  if v_at > now() or v_at < now() - interval '11 days' then v_at := now(); end if;
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
  begin
    perform public.kiosk_app_sms_alert(v_id);
  exception when others then null;
  end;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.kiosk_app_sms_put(text, text, text, text, text) from public;
grant execute on function public.kiosk_app_sms_put(text, text, text, text, text) to anon, authenticated;
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
create or replace function public.kiosk_app_modem_cum_at(p_device text, p_t timestamptz)
returns bigint language sql stable security definer set search_path = public as $$
  select r.cum_bytes from public.kiosk_app_modem_reads r where r.device_id = p_device and r.at <= p_t order by r.at desc limit 1
$$;
revoke all on function public.kiosk_app_modem_cum_at(text, timestamptz) from public, anon, authenticated;
create or replace function public.kiosk_app_gb(p bigint)
returns text language sql immutable as $$ select coalesce(trim_scale(round(p / 1073741824.0, 2))::text, '?') $$;
revoke all on function public.kiosk_app_gb(bigint) from public, anon, authenticated;
create or replace function public.kiosk_app_modem_parts(p_device text, p_day date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c0 bigint; c1 bigint; c2 bigint; c3 bigint; v_first bigint;
begin
  select r.cum_bytes into v_first from public.kiosk_app_modem_reads r where r.device_id = p_device order by r.at limit 1;
  c0 := coalesce(public.kiosk_app_modem_cum_at(p_device, ((p_day - 1) + time '19:10') at time zone 'Asia/Manila'), v_first);
  c1 := coalesce(public.kiosk_app_modem_cum_at(p_device, (p_day + time '10:01') at time zone 'Asia/Manila'), v_first);
  c2 := coalesce(public.kiosk_app_modem_cum_at(p_device, (p_day + time '15:00') at time zone 'Asia/Manila'), v_first);
  c3 := coalesce(public.kiosk_app_modem_cum_at(p_device, (p_day + time '19:10') at time zone 'Asia/Manila'), v_first);
  return jsonb_build_object('night', c1 - c0, 'am', c2 - c1, 'pm', c3 - c2, 'day', c3 - c0);
end $$;
revoke all on function public.kiosk_app_modem_parts(text, date) from public, anon, authenticated;
create or replace function public.kiosk_app_modem_put(p_device text, m jsonb)
returns void language plpgsql volatile security definer set search_path = public as $$
declare
  v_tot   bigint;
  v_secs  bigint  := case when m->>'total_secs'  ~ '^[0-9]{1,12}$' then (m->>'total_secs')::bigint end;
  v_dayb  bigint  := case when m->>'day_bytes'   ~ '^[0-9]{1,15}$' then (m->>'day_bytes')::bigint end;
  v_monb  bigint  := case when m->>'month_bytes' ~ '^[0-9]{1,15}$' then (m->>'month_bytes')::bigint end;
  v_inbox integer := case when m->>'inbox' ~ '^[0-9]{1,5}$' then (m->>'inbox')::integer end;
  v_host  text    := case when m->>'host' in ('192.168.1.1','192.168.8.1','192.168.0.1','192.168.254.254') then m->>'host' end;
  v_at    timestamptz := public.kiosk_app_ts(m->>'at');
  v_delta bigint;
  v_rst   boolean := false;
  v_mclr  date    := case when m->>'month_clear' ~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}$' then public.kiosk_app_text_date(m->>'month_clear') end;
  v_cum   bigint;
  x       public.kiosk_app_modem%rowtype;
  v_nm    text;
  v_left  numeric;
  v_lvl   integer;
begin
  if coalesce(m->>'total_bytes', '') !~ '^[0-9]{1,15}$' then return; end if;
  v_tot := (m->>'total_bytes')::bigint;
  if v_at is null or v_at > now() + interval '2 minutes' or v_at < now() - interval '1 day' then v_at := now(); end if;
  insert into public.kiosk_app_modem as y (device_id) values (p_device) on conflict (device_id) do nothing;
  select * into x from public.kiosk_app_modem y where y.device_id = p_device for update;
  if x.last_read_at is not null and v_at <= x.last_read_at then return; end if;
  if x.last_total is null or coalesce(v_host, x.host) is distinct from x.host then
    v_delta := 0;
  elsif v_tot < x.last_total or (v_secs is not null and x.last_secs is not null and v_secs < x.last_secs) then
    v_delta := v_tot; v_rst := true;
  else
    v_delta := v_tot - x.last_total;
  end if;
  if v_delta is not null and x.last_total is not null and v_mclr is not null and v_mclr = x.month_clear
     and v_monb is not null and x.month_bytes is not null and v_monb >= x.month_bytes
     and coalesce(v_host, x.host) is not distinct from x.host then
    v_delta := greatest(v_delta, v_monb - x.month_bytes);
  end if;
  if v_delta > 30 * 1073741824::bigint then v_delta := 0; v_rst := false; end if;
  v_cum := x.cum_bytes + v_delta;
  update public.kiosk_app_modem y set
    host = coalesce(v_host, y.host), cum_bytes = v_cum, last_total = v_tot, last_secs = v_secs, last_read_at = v_at,
    first_read_at = coalesce(y.first_read_at, v_at), day_bytes = v_dayb, month_bytes = v_monb, month_clear = v_mclr,
    inbox = coalesce(v_inbox, y.inbox),
    restarts = y.restarts + case when v_rst and y.load_gb is not null then 1 else 0 end,
    read_fail_alerted = false,
    inbox_full_alerted = case when v_inbox is null then y.inbox_full_alerted when v_inbox < 400 then false else y.inbox_full_alerted end
   where y.device_id = p_device;
  insert into public.kiosk_app_modem_reads (device_id, at, total_bytes, total_secs, day_bytes, inbox, cum_bytes, restarted)
  values (p_device, v_at, v_tot, v_secs, v_dayb, v_inbox, v_cum, v_rst);
  select coalesce(nullif(k.name, ''), p_device) into v_nm from public.kiosk_app_devices k where k.device_id = p_device;
  if x.load_gb is not null then
    v_left := x.load_gb - (v_cum - x.load_cum) / 1073741824.0;
    v_lvl := case when v_left < 5 then 5 when v_left < 10 then 10 when v_left < 20 then 20 end;
    if v_lvl is not null and v_lvl < coalesce(x.alerted_gb, 1000) then
      update public.kiosk_app_modem y set alerted_gb = v_lvl where y.device_id = p_device;
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_nm || ' - YARD WIFI LOAD: about ' || trim_scale(round(greatest(v_left, 0), 1))
              || ' GB left of ' || trim_scale(x.load_gb) || ' GB (below ' || v_lvl || ' GB).'
              || case when v_lvl = 5 then ' LOAD NOW (GCash / Maya, the modem number), then record it on the Tablets page.' else '' end
              || ' Used since ' || to_char(x.load_date, 'Mon DD') || ': ' || public.kiosk_app_gb(v_cum - x.load_cum) || ' GB.');
    end if;
  end if;
  if v_inbox is not null and x.inbox is not null and v_inbox > x.inbox then
    perform public.kiosk_alert_send('RSR Kiosk: ' || v_nm || ' - the yard WiFi modem received ' || (v_inbox - x.inbox)
            || ' new text' || case when v_inbox - x.inbox > 1 then 's' else '' end || ' (' || v_inbox
            || ' in its inbox). To read: on the yard WiFi open http://192.168.1.1 > Tools > SMS.');
  end if;
  if v_inbox >= 450 and not x.inbox_full_alerted then
    update public.kiosk_app_modem y set inbox_full_alerted = true where y.device_id = p_device;
    perform public.kiosk_alert_send('RSR Kiosk: ' || v_nm || ' - the yard WiFi modem inbox is almost full (' || v_inbox
            || ' of 500 texts). Delete old texts (http://192.168.1.1 > Tools > SMS), or new load texts cannot come in.');
  end if;
end $$;
revoke all on function public.kiosk_app_modem_put(text, jsonb) from public, anon, authenticated;
create or replace function public.kiosk_app_modem_msg(p_device text, p_kind text)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  x       public.kiosk_app_modem%rowtype;
  v_nm    text;
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_left  numeric;
  v_parts jsonb;
  v_rate  numeric;
  v_avg   numeric;
  v_max   bigint;
  v_night numeric;
  v_maxday date;
  v_wk    bigint;
  v_rst   integer;
begin
  select * into x from public.kiosk_app_modem y where y.device_id = p_device;
  if not found or x.load_gb is null then return null; end if;
  select coalesce(nullif(k.name, ''), p_device) into v_nm from public.kiosk_app_devices k where k.device_id = p_device;
  v_left := greatest(x.load_gb - (x.cum_bytes - x.load_cum) / 1073741824.0, 0);
  if p_kind = 'test' then
    v_parts := public.kiosk_app_modem_parts(p_device, v_today);
    v_rate := (x.cum_bytes - x.load_cum) / 1073741824.0 / greatest(extract(epoch from now() - x.load_at) / 86400.0, 1);
    return 'RSR Kiosk: ' || v_nm || ' - Yard WiFi TEST day ' || (v_today - x.test_from + 1) || ' of '
           || (x.test_until - x.test_from + 1) || ': used ' || public.kiosk_app_gb((v_parts->>'day')::bigint)
           || ' GB since 7:10 PM yesterday (night to 10 AM ' || public.kiosk_app_gb((v_parts->>'night')::bigint)
           || ', 10 AM-3 PM ' || public.kiosk_app_gb((v_parts->>'am')::bigint)
           || ', 3-7:10 PM ' || public.kiosk_app_gb((v_parts->>'pm')::bigint) || '). About '
           || trim_scale(round(v_left, 1)) || ' GB left'
           || case when v_rate > 0.01 then ', about ' || floor(v_left / v_rate) || ' days at this rate' else '' end
           || '.' || case when x.restarts > 0 then ' Modem restarted ' || x.restarts || 'x since the load (figure may be a bit low).' else '' end;
  elsif p_kind = 'summary' then
    select avg((p.j->>'day')::bigint), max((p.j->>'day')::bigint), avg((p.j->>'night')::bigint),
           (array_agg(p.d order by (p.j->>'day')::bigint desc nulls last))[1]
      into v_avg, v_max, v_night, v_maxday
      from (select g::date as d, public.kiosk_app_modem_parts(p_device, g::date) as j
              from generate_series(x.test_from, x.test_until, interval '1 day') g) p;
    return 'RSR Kiosk: ' || v_nm || ' - Yard WiFi TEST finished (' || (x.test_until - x.test_from + 1)
           || ' days): average ' || public.kiosk_app_gb(round(v_avg)::bigint) || ' GB a day, highest '
           || public.kiosk_app_gb(v_max) || ' GB (' || coalesce(to_char(v_maxday, 'Mon DD'), '?') || '), night (7:10 PM-10 AM) average '
           || public.kiosk_app_gb(round(v_night)::bigint) || ' GB. About ' || trim_scale(round(v_left, 1)) || ' GB left'
           || case when v_avg > 0 then ', about ' || floor(v_left / (v_avg / 1073741824.0)) || ' days at this rate' else '' end
           || '.' || case when v_night > 0.3 * 1073741824 then ' Night use is HIGH: something else is using the WiFi at night (check Devices on the modem).' else '' end
           || ' From now on: one report every Monday.';
  elsif p_kind = 'weekly' then
    v_wk := greatest(x.cum_bytes - coalesce(public.kiosk_app_modem_cum_at(p_device, now() - interval '7 days'), x.load_cum), 0);
    select count(*) into v_rst from public.kiosk_app_modem_reads r where r.device_id = p_device and r.restarted and r.at > now() - interval '7 days';
    return 'RSR Kiosk: ' || v_nm || ' - Yard WiFi weekly: used ' || public.kiosk_app_gb(v_wk)
           || ' GB in the last 7 days. About ' || trim_scale(round(v_left, 1)) || ' GB left'
           || case when v_wk > 0 then ', about ' || floor(v_left / (v_wk / 1073741824.0)) || ' weeks at this rate' else '' end
           || '.' || case when v_rst > 0 then ' Modem restarted ' || v_rst || 'x this week (figure may be a bit low).' else '' end;
  end if;
  return null;
end $$;
revoke all on function public.kiosk_app_modem_msg(text, text) from public, anon, authenticated;
create or replace function public.kiosk_app_modem_info(p_device text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  x       public.kiosk_app_modem%rowtype;
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_first bigint;
  v_used  bigint;
  v_left  numeric;
  v_days  numeric;
  v_rate  numeric;
begin
  select * into x from public.kiosk_app_modem y where y.device_id = p_device;
  if not found then return null; end if;
  select r.cum_bytes into v_first from public.kiosk_app_modem_reads r where r.device_id = p_device order by r.at limit 1;
  if x.load_gb is not null then
    v_used := x.cum_bytes - x.load_cum;
    v_left := x.load_gb - v_used / 1073741824.0;
    v_days := extract(epoch from now() - x.load_at) / 86400.0;
    if v_days >= 1 and v_used > 0 then v_rate := v_used / 1073741824.0 / v_days; end if;
  end if;
  return jsonb_build_object(
    'host', x.host, 'last_read_at', x.last_read_at, 'inbox', x.inbox, 'restarts', x.restarts,
    'used_today_gb', round((x.cum_bytes - coalesce(public.kiosk_app_modem_cum_at(p_device, v_today::timestamp at time zone 'Asia/Manila'), v_first)) / 1073741824.0, 2),
    'used_7d_gb', round((x.cum_bytes - coalesce(public.kiosk_app_modem_cum_at(p_device, now() - interval '7 days'), v_first)) / 1073741824.0, 2),
    'modem_day_gb', round(x.day_bytes / 1073741824.0, 2),
    'load_gb', x.load_gb, 'load_date', x.load_date,
    'used_since_load_gb', round(v_used / 1073741824.0, 2),
    'left_gb', round(v_left, 2),
    'gb_per_day', round(v_rate, 2),
    'days_to_empty', case when v_rate > 0 then floor(greatest(v_left, 0) / v_rate) end,
    'alerted_gb', x.alerted_gb,
    'mode', case when x.test_until >= v_today then 'test' else 'weekly' end,
    'test_day', case when x.test_until >= v_today then v_today - x.test_from + 1 end,
    'test_days', case when x.test_until >= v_today then x.test_until - x.test_from + 1 end);
end $$;
revoke all on function public.kiosk_app_modem_info(text) from public, anon, authenticated;
create or replace function public.kiosk_app_modem_set(p_passcode text, p_device text, p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  x       public.kiosk_app_modem%rowtype;
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_ld    date;
  v_add   numeric;
  v_left  numeric;
  v_now   numeric;
  v_td    integer;
  v_log   text;
begin
  if not public.admin_verify_passcode(p_passcode) then
    return jsonb_build_object('error', 'wrong passcode');
  end if;
  if not exists (select 1 from public.kiosk_app_devices k where k.device_id = p_device) then
    return jsonb_build_object('error', 'tablet not found');
  end if;
  if jsonb_typeof(p) <> 'object' then return jsonb_build_object('error', 'nothing to save'); end if;
  if p ? 'test_days' then
    if coalesce(p->>'test_days', '') !~ '^[0-9]{1,2}$' or (p->>'test_days')::int > 60 then
      return jsonb_build_object('error', 'test days must be 0 to 60');
    end if;
    v_td := (p->>'test_days')::int;
  end if;
  insert into public.kiosk_app_modem as y (device_id) values (p_device) on conflict (device_id) do nothing;
  select * into x from public.kiosk_app_modem y where y.device_id = p_device for update;
  if p ? 'add_gb' then
    if coalesce(p->>'add_gb', '') !~ '^[0-9]{1,4}(\.[0-9]{1,2})?$' or (p->>'add_gb')::numeric <= 0 then
      return jsonb_build_object('error', 'GB loaded must be a number like 16 or 1.5');
    end if;
    v_add := (p->>'add_gb')::numeric;
    v_ld := coalesce(public.kiosk_app_text_date(p->>'load_date'), v_today);
    if v_ld > v_today or v_ld < v_today - 60 then
      return jsonb_build_object('error', 'load date must be today or up to 60 days back');
    end if;
    v_now := case when x.load_gb is null then 0 else greatest(0, x.load_gb - (x.cum_bytes - x.load_cum) / 1073741824.0) end;
    if v_td is null and x.test_from is null then v_td := 14; end if;
    update public.kiosk_app_modem y set load_gb = round(v_now + v_add, 2), load_date = v_ld, load_at = now(),
           load_cum = y.cum_bytes, alerted_gb = null, restarts = 0
     where y.device_id = p_device;
    v_log := 'office: yard WiFi load +' || trim_scale(v_add) || ' GB (' || to_char(v_ld, 'YYYY-MM-DD') || '), now about '
             || trim_scale(round(v_now + v_add, 2)) || ' GB';
  elsif p ? 'left_gb' then
    if coalesce(p->>'left_gb', '') !~ '^[0-9]{1,4}(\.[0-9]{1,2})?$' then
      return jsonb_build_object('error', 'GB left must be a number like 12.5');
    end if;
    if x.load_gb is null then return jsonb_build_object('error', 'record a load first'); end if;
    v_left := (p->>'left_gb')::numeric;
    update public.kiosk_app_modem y set load_gb = greatest(y.load_gb, v_left),
           load_cum = y.cum_bytes - round((greatest(y.load_gb, v_left) - v_left) * 1073741824),
           alerted_gb = case when v_left < 5 then 5 when v_left < 10 then 10 when v_left < 20 then 20 end
     where y.device_id = p_device;
    v_log := 'office: yard WiFi GB left corrected to ' || trim_scale(v_left) || ' GB';
  end if;
  if v_td is not null then
    if v_td = 0 then
      update public.kiosk_app_modem y set test_from = coalesce(y.test_from, v_today), test_until = null, test_summary = true
       where y.device_id = p_device;
    else
      update public.kiosk_app_modem y set test_from = v_today, test_until = v_today + v_td - 1, test_last = null, test_summary = false
       where y.device_id = p_device;
    end if;
    v_log := coalesce(v_log || ', ', 'office: ') || case when v_td = 0 then 'yard WiFi test ended (weekly reports)'
                                                         else 'yard WiFi test ' || v_td || ' days from today' end;
  end if;
  if v_log is null then return jsonb_build_object('error', 'nothing to save'); end if;
  insert into public.kiosk_app_events (device_id, event, notified) values (p_device, left(v_log, 120), true);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.kiosk_app_modem_set(text, text, jsonb) from public;
grant execute on function public.kiosk_app_modem_set(text, text, jsonb) to anon, authenticated;
create or replace function public.kiosk_app_power_put(p_device text, p_events jsonb)
returns void language plpgsql volatile security definer set search_path = public as $$
declare
  e      jsonb;
  v_at   timestamptz;
  v_kind text;
  v_b    integer;
  v_last timestamptz;
  v_open bigint;
begin
  if jsonb_typeof(p_events) <> 'array' then return; end if;
  select k.power_last_at into v_last from public.kiosk_app_devices k where k.device_id = p_device for update;
  for e in select x from jsonb_array_elements(p_events) x
             where jsonb_typeof(x) = 'object' and x->>'at' ~ '^[0-9]{12,14}$'
             order by (x->>'at')::bigint limit 100 loop
    v_at := to_timestamp((e->>'at')::bigint / 1000.0);
    continue when v_at > now() + interval '5 minutes' or v_at < now() - interval '60 days';
    continue when v_last is not null and v_at <= v_last;
    v_kind := e->>'kind';
    v_b := case when e->>'batt' ~ '^[0-9]{1,3}$' and (e->>'batt')::int <= 100 then (e->>'batt')::int end;
    select l.id into v_open from public.kiosk_app_power_log l
     where l.device_id = p_device and l.on_at is null and not l.back_unknown order by l.off_at desc limit 1;
    if v_kind = 'off' then
      if v_open is not null then
        update public.kiosk_app_power_log l set back_unknown = true where l.id = v_open;
      end if;
      insert into public.kiosk_app_power_log (device_id, off_at, batt_off) values (p_device, v_at, v_b);
    elsif v_kind = 'on' then
      if v_open is not null then
        update public.kiosk_app_power_log l set on_at = v_at, batt_on = v_b where l.id = v_open;
      end if;
    elsif v_kind = 'shutdown' then
      if v_open is not null then update public.kiosk_app_power_log l set died_at = coalesce(l.died_at, v_at) where l.id = v_open; end if;
    elsif v_kind = 'boot' then
      if v_open is not null then update public.kiosk_app_power_log l set booted_at = v_at where l.id = v_open and l.died_at is not null; end if;
    else
      continue;
    end if;
    v_last := v_at;
  end loop;
  update public.kiosk_app_devices k set power_last_at = v_last where k.device_id = p_device and v_last is not null;
end $$;
revoke all on function public.kiosk_app_power_put(text, jsonb) from public, anon, authenticated;
create or replace function public.kiosk_app_power_info(p_device text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('off_at', l.off_at, 'on_at', l.on_at, 'batt_off', l.batt_off,
                                                          'batt_on', l.batt_on, 'died_at', l.died_at, 'booted_at', l.booted_at,
                                                          'back_unknown', l.back_unknown)
                                       order by l.off_at desc)
                        from (select * from public.kiosk_app_power_log x where x.device_id = p_device order by x.off_at desc limit 30) l), '[]'::jsonb),
    'cuts_7d', (select count(*) from public.kiosk_app_power_log x where x.device_id = p_device and x.off_at > now() - interval '7 days'),
    'off_min_7d', (select round(coalesce(sum(extract(epoch from least(coalesce(x.on_at, now()), now())
                                  - greatest(x.off_at, now() - interval '7 days')) / 60), 0))
                     from public.kiosk_app_power_log x where x.device_id = p_device and not x.back_unknown
                      and coalesce(x.on_at, now()) > now() - interval '7 days'))
$$;
revoke all on function public.kiosk_app_power_info(text) from public, anon, authenticated;
create or replace function public.kiosk_app_sleep_set(p_passcode text, p_device text, p_from text, p_until text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_from  timestamptz;
  v_until timestamptz;
begin
  if not public.admin_verify_passcode(p_passcode) then
    return jsonb_build_object('error', 'wrong passcode');
  end if;
  if not exists (select 1 from public.kiosk_app_devices k where k.device_id = p_device) then
    return jsonb_build_object('error', 'tablet not found');
  end if;
  if coalesce(p_from, '') = '' and coalesce(p_until, '') = '' then
    update public.kiosk_app_devices k set sleep_from = null, sleep_until = null where k.device_id = p_device;
    insert into public.kiosk_app_events (device_id, event, notified) values (p_device, 'office: holiday sleep plan cancelled', true);
    return jsonb_build_object('ok', true);
  end if;
  if coalesce(p_from, '') !~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$' or coalesce(p_until, '') !~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$' then
    return jsonb_build_object('error', 'dates must look like 2026-12-24 18:00');
  end if;
  begin
    v_from := (p_from || ':00')::timestamp at time zone 'Asia/Manila';
    v_until := (p_until || ':00')::timestamp at time zone 'Asia/Manila';
  exception when others then
    return jsonb_build_object('error', 'not a real date');
  end;
  if v_until <= now() then return jsonb_build_object('error', 'the wake-up time is already past'); end if;
  if v_until <= v_from then return jsonb_build_object('error', 'wake-up must be after the start'); end if;
  if v_until - v_from > interval '31 days' then return jsonb_build_object('error', 'at most 31 days'); end if;
  if v_from < now() - interval '1 day' then v_from := now(); end if;
  update public.kiosk_app_devices k set sleep_from = v_from, sleep_until = v_until where k.device_id = p_device;
  insert into public.kiosk_app_events (device_id, event, notified)
  values (p_device, left('office: holiday sleep ' || to_char(v_from at time zone 'Asia/Manila', 'Mon DD HH12:MI AM') || ' to '
                         || to_char(v_until at time zone 'Asia/Manila', 'Mon DD HH12:MI AM'), 120), true);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.kiosk_app_sleep_set(text, text, text, text) from public;
grant execute on function public.kiosk_app_sleep_set(text, text, text, text) to anon, authenticated;
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
  l       public.kiosk_app_loads%rowtype;
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_day8  boolean;
  v_left  int;
  v_long  boolean;
  v_used  bigint;
  v_close date;
  v_prov  text;
  v_alrt  jsonb;
  v_txt   text;
  tx      record;
  mm      record;
begin
  v_work := (v_min >= 6*60 and v_min < 22*60);
  v_day8 := (v_min >= 8*60 and v_min < 20*60);
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
    l := null;
    select * into l from public.kiosk_app_loads x where x.device_id = r.device_id order by x.load_date desc, x.id desc limit 1;
    v_prov := coalesce(r.sim_provider, l.provider, r.sim_operator, 'SIM');
    v_alrt := (select coalesce(jsonb_object_agg(a.key, a.value), '{}'::jsonb) from jsonb_each(r.sim_alerts) a
                where (l.id is not null and a.key like '%:' || l.id) or a.key = 'noload:' || to_char(v_today, 'YYYY-MM'));
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
      if l.gb is not null and l.gb > 0 and not v_alrt ? ('data80:' || l.id) then
        select coalesce(sum(x.bytes), 0) into v_used from public.kiosk_app_data_days x where x.device_id = r.device_id and x.day >= l.load_date;
        if v_used >= l.gb * 0.8 * 1073741824 then
          perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' has used about ' || round(v_used / 1073741824.0, 1)
                  || ' GB of its ' || trim_scale(l.gb) || ' GB ' || v_prov || ' load (80%+). Reload soon.');
          v_alrt := v_alrt || jsonb_build_object('data80:' || l.id, true);
        end if;
      end if;
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
    v_on  := public.kiosk_app_hhmm(r.sched_on);
    v_off := public.kiosk_app_hhmm(r.sched_off);
    v_awake := case when v_on is null or v_off is null or v_on = v_off then true
                    when v_on < v_off then v_min >= v_on + 15 and v_min < v_off
                    else v_min >= v_on + 15 or v_min < v_off end;
    if r.deep_sleep_until > now() and r.last_seen > now() - interval '24 hours' then
      if r.last_seen < now() - interval '13 hours' and not r.sleep_missed_alerted then
        update public.kiosk_app_devices set sleep_missed_alerted = true where device_id = r.device_id;
        perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is in deep sleep but MISSED its 12-hour report (last '
                || to_char(r.last_seen at time zone 'Asia/Manila', 'Mon DD HH12:MI AM') || ', battery ' || coalesce(r.battery::text, '?')
                || '%). The battery may be empty: check the tablet when someone is at the yard.');
      end if;
      continue;
    end if;
    if r.last_seen < now() - interval '10 minutes' then
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
    if r.net_type = 'mobile' and r.net_since < now() - interval '30 minutes' and not r.mobile_alerted
       and v_work and public.kiosk_app_power_state(r.power_windows, v_min) = 'on' then
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is on MOBILE DATA for ' || public.kiosk_app_dur(now() - r.net_since)
              || ' - the yard Wi-Fi may be down. Punches still sync.'
              || coalesce(' Mobile data used today: ' || (select round(x.bytes / 1048576.0) from public.kiosk_app_data_days x
                                                           where x.device_id = r.device_id and x.day = v_today) || ' MB.', ''));
      update public.kiosk_app_devices set mobile_alerted = true where device_id = r.device_id;
    elsif r.net_type = 'wifi' and r.mobile_alerted then
      perform public.kiosk_alert_send('RSR Kiosk: ' || v_name || ' is back on Wi-Fi.'
              || coalesce(' It was on mobile data ' || (select public.kiosk_app_dur(c.ended_at - c.started_at) from public.kiosk_app_conn c
                                                        where c.device_id = r.device_id and c.kind = 'mobile' and c.ended_at is not null
                                                        order by c.started_at desc limit 1) || '.', ''));
      update public.kiosk_app_devices set mobile_alerted = false where device_id = r.device_id;
    end if;
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
            or r.unplugged_alerted_at < now() - case
                 when not v_win and (r.net_type in ('mobile','none') or r.wifi is false) then interval '60 minutes'
                 when v_work or v_win then interval '30 minutes' else interval '2 hours' end) then
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
  for e in select ev.id, ev.event, ev.at, ev.device_id, coalesce(nullif(k.name,''), ev.device_id) as nm
             from public.kiosk_app_events ev
             left join public.kiosk_app_devices k on k.device_id = ev.device_id
            where not ev.notified and ev.at > now() - interval '1 hour'
            order by ev.at loop
    if e.event like 'tablet restarted%' or e.event like 'updated to build%'
       or e.event like 'maintenance opened%' or e.event like 'update install failed%'
       or e.event like 'installing build%' or e.event = 'screen on failed'
       or e.event = 'screen woken by phone call' then
      v_sent := v_sent + 1;
      exit when v_sent > 5;
      perform public.kiosk_alert_send('RSR Kiosk: ' || e.nm || ' - '
              || case when e.event = 'screen on failed' then 'screen did NOT turn on by itself. Press the power button; check the Tablets page.'
                      when e.event = 'screen woken by phone call' then 'screen woken by your phone call.'
                      else e.event end || ' ('
              || to_char(e.at at time zone 'Asia/Manila', 'HH12:MI AM') || ')');
    end if;
    update public.kiosk_app_events set notified = true where id = e.id;
  end loop;
  v_sent := 0;
  for tx in select x.id from public.kiosk_app_sms x where not x.notified order by x.received_at limit 50 loop
    exit when v_sent >= 5;
    if public.kiosk_app_sms_alert(tx.id) then v_sent := v_sent + 1; end if;
  end loop;
  for mm in select x.*, coalesce(nullif(k.name, ''), x.device_id) as nm, k.last_seen as seen, k.modem_err as err
              from public.kiosk_app_modem x join public.kiosk_app_devices k on k.device_id = x.device_id loop
   begin
    if coalesce(mm.last_read_at, mm.load_at) < now() - interval '2 days' and mm.seen > now() - interval '30 minutes' and not mm.read_fail_alerted then
      update public.kiosk_app_modem y set read_fail_alerted = true where y.device_id = mm.device_id;
      perform public.kiosk_alert_send('RSR Kiosk: ' || mm.nm || ' - the yard WiFi modem has not been read for 2 days ('
              || coalesce(mm.err, 'no reason given') || '). The load left is not being watched: check that the tablet is on the PLDT WiFi.');
    end if;
    continue when mm.load_gb is null;
    if mm.test_until is not null and v_today between mm.test_from and mm.test_until and v_min >= 19*60 + 15
       and mm.test_last is distinct from v_today then
      update public.kiosk_app_modem y set test_last = v_today where y.device_id = mm.device_id;
      perform public.kiosk_alert_send(public.kiosk_app_modem_msg(mm.device_id, 'test'));
    end if;
    if mm.test_until is not null and not mm.test_summary
       and ((v_today = mm.test_until and v_min >= 19*60 + 20 and mm.test_last = v_today) or (v_today > mm.test_until and v_min >= 7*60)) then
      update public.kiosk_app_modem y set test_summary = true where y.device_id = mm.device_id;
      perform public.kiosk_alert_send(public.kiosk_app_modem_msg(mm.device_id, 'summary'));
    end if;
    if (mm.test_until is null or v_today > mm.test_until) and extract(isodow from v_today) = 1 and v_min >= 10*60 + 5
       and mm.weekly_last is distinct from v_today then
      update public.kiosk_app_modem y set weekly_last = v_today where y.device_id = mm.device_id;
      perform public.kiosk_alert_send(public.kiosk_app_modem_msg(mm.device_id, 'weekly'));
    end if;
   exception when others then null;
   end;
  end loop;
  update public.kiosk_app_devices set cmd_arg = null
   where cmd = 'set_wifi' and cmd_arg is not null and cmd_at < now() - interval '30 minutes';
  delete from public.kiosk_app_events where at < now() - interval '60 days';
  delete from public.kiosk_app_devices where coalesce(name, '') = '' and last_seen < now() - interval '7 days';
  delete from public.kiosk_app_shots s where not exists (select 1 from public.kiosk_app_devices d where d.device_id = s.device_id);
  delete from public.kiosk_app_conn where coalesce(ended_at, now()) < now() - interval '60 days';
  delete from public.kiosk_app_conn c where not exists (select 1 from public.kiosk_app_devices d where d.device_id = c.device_id) and c.started_at < now() - interval '30 days';
  delete from public.kiosk_app_sms x where not exists (select 1 from public.kiosk_app_devices d where d.device_id = x.device_id) and x.received_at < now() - interval '30 days';
  delete from public.kiosk_app_data_days x where not exists (select 1 from public.kiosk_app_devices d where d.device_id = x.device_id) and x.day < v_today - 30;
  delete from public.kiosk_app_load_shots x where not exists (select 1 from public.kiosk_app_devices d where d.device_id = x.device_id);
  delete from public.kiosk_app_data_days where day < v_today - 400;
  delete from public.kiosk_app_sms where received_at < now() - interval '180 days' and load_id is null;
  delete from public.kiosk_app_sms where kind = 'otp' and created_at < now() - interval '15 minutes';
  delete from public.kiosk_app_modem_reads where at < now() - interval '120 days';
  delete from public.kiosk_app_power_log where off_at < now() - interval '365 days';
  delete from public.kiosk_app_modem_reads mr where not exists (select 1 from public.kiosk_app_devices d where d.device_id = mr.device_id)
     and mr.at < now() - interval '30 days';
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
select (select count(*) from information_schema.tables where table_schema = 'public'
          and table_name in ('kiosk_app_conn','kiosk_app_data_days','kiosk_app_sms','kiosk_app_loads','kiosk_app_load_shots')) as build6_tables,
       (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
          and proname in ('kiosk_app_sms_put','kiosk_app_load_add','kiosk_app_load_wait','kiosk_app_sim_set','kiosk_app_load_shot_get','kiosk_app_sim_info',
                          'kiosk_app_sms_alert','kiosk_app_otp_code')) as build6_functions,
       (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'kiosk_app_devices'
          and column_name in ('net_type','net_since','mobile_alerted','mobile_signal','mobile_ok','mobile_bad_since','mobile_bad_alerted',
                              'sim_operator','sim_state','sms_ok','sim_provider','sim_close_days','sim_alerts','load_wait_from','battery_unrestricted')) as build6_columns;
select (select count(*) from information_schema.tables where table_schema = 'public'
          and table_name in ('kiosk_app_modem','kiosk_app_modem_reads','kiosk_app_power_log')) as build7_tables,
       (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
          and proname in ('kiosk_app_modem_cum_at','kiosk_app_gb','kiosk_app_modem_parts','kiosk_app_modem_put',
                          'kiosk_app_modem_info','kiosk_app_modem_set','kiosk_app_modem_msg','kiosk_app_tick',
                          'kiosk_app_power_put','kiosk_app_power_info','kiosk_app_sleep_set')) as build7_functions,
       (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'kiosk_app_devices'
          and column_name in ('modem_err','batt_health','batt_cycles','batt_design_mah','batt_cap_mah','batt_cap_n',
                              'batt_wear_alerted','batt_bad_alerted','batt_cap_at','batt_bad_at',
                              'sleep_from','sleep_until','deep_sleep_until','deep_sleep_reason','sleep_missed_alerted','power_last_at')) as build7_columns;
