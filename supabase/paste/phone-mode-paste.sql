-- RSR Kiosk app - ROLL-CALL PHONE MODE - PART 2 of 2: INSTALL (2026-11-12). Only after Part 1 shows all true.
-- Paste ALL of this and press Run. Adds one column (phone_mode, default false = every tablet stays a tablet)
-- and replaces 4 functions. No data is changed. Re-runnable.
-- Last result must show: is_phone_rc = true, is_phone_kiosk = false, tablets_still_tablets = true.
alter table public.kiosk_app_devices add column if not exists phone_mode        boolean not null default false;
create or replace function public.kiosk_app_is_phone(p_url text)
returns boolean language sql immutable as $$
  select coalesce(lower(split_part(split_part(btrim(p_url), '?', 1), '#', 1))
                  like 'https://seafordprojects-bit.github.io/%/monitoring/%', false)
$$;
revoke all on function public.kiosk_app_is_phone(text) from public, anon, authenticated;
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
select public.kiosk_app_is_phone('https://seafordprojects-bit.github.io/rsr-engineering/monitoring/roll-call.html?site=Carmen') as is_phone_rc,
       public.kiosk_app_is_phone('https://seafordprojects-bit.github.io/rsr-engineering/kiosk/?site=Mandaue') as is_phone_kiosk,
       not exists (select 1 from public.kiosk_app_devices where phone_mode) as tablets_still_tablets;
