const PUBLIC_CHECK = "select t as table_name,\n       has_table_privilege('anon', 'public.' || t, 'select') as public_can_read,\n       has_table_privilege('authenticated', 'public.' || t, 'select') as signed_in_can_read\n  from unnest(array['kiosk_app_devices','kiosk_app_events','kiosk_app_shots','kiosk_app_conn','kiosk_app_data_days',\n                    'kiosk_app_sms','kiosk_app_loads','kiosk_app_load_shots']) t;\n";
// SQL test for kiosk-app.sql on a throwaway local Postgres (npm i embedded-postgres pg; run as a non-root user from this folder).
import EmbeddedPostgres from 'embedded-postgres';
import pg from 'pg';
import fs from 'fs';
const db = new EmbeddedPostgres({ databaseDir: './.pgdata', user: 'postgres', password: 'pw', port: 54329, persistent: false });
await db.initialise(); await db.start();
const c = new pg.Client({ host:'localhost', port:54329, user:'postgres', password:'pw', database:'postgres' });
await c.connect();
const q = async (s, p) => (await c.query(s, p)).rows;
let fails = 0; const ok = (cond, msg) => { console.log((cond?'PASS ':'FAIL ')+msg); if(!cond) fails++; };
await c.query(`
create role anon; create role authenticated;
create table public.attendance_records(id int);
create table public.kiosk_health(device_id text primary key, site text, stuck_count int not null default 0, queue_length int not null default 0, stuck_details jsonb, offline_queue_length int not null default 0, oldest_unsynced_at timestamptz, last_seen timestamptz not null default now());
create schema cron; create table cron.job(jobid serial, jobname text, schedule text, command text, active boolean default true);
create function cron.schedule(n text, s text, cmd text) returns bigint language sql as $$ insert into cron.job(jobname,schedule,command) values (n,s,cmd) returning jobid::bigint $$;
create function cron.unschedule(n text) returns boolean language plpgsql as $$ begin delete from cron.job where jobname=n; if not found then raise exception 'no job'; end if; return true; end $$;
create table public.sent(id serial, msg text);
create function public.kiosk_alert_send(p_msg text) returns void language sql as $$ insert into public.sent(msg) values (p_msg) $$;
create table public.fails(n int); insert into public.fails values (0);
create function public.admin_verify_passcode(p_input text) returns boolean language plpgsql as $$ begin if p_input='123456' then return true; end if; update public.fails set n=n+1; return false; end $$;
`);
const sql = fs.readFileSync('./kiosk-app.sql','utf8');
await c.query(sql); await c.query(sql); ok(true,'migration runs twice (idempotent)');
ok((await q(`select count(*)::int n from cron.job where jobname='kiosk-app-tick'`))[0].n===1,'one cron job');
const TOK = {};   // the secret each test tablet got on its first report
const beat = async p => {
  const body = Object.assign({}, p);
  if (TOK[p.device_id] && !('token' in p)) body.token = TOK[p.device_id];
  const r = (await q(`select public.kiosk_app_beat($1::jsonb) r`,[JSON.stringify(body)]))[0].r;
  if (r && r.token) TOK[p.device_id] = r.token;
  if (r) delete r.token;
  return r;
};
ok(JSON.stringify(await beat({device_id:'x; drop'}))==='{}','bad id ignored');
let r = await beat({device_id:'app-abc123',name:'Carmen kiosk',battery:80,charging:true,app_version:5,screen_on:true,event:'tablet restarted'});
ok(JSON.stringify(r)==='{}','first beat no command');
ok((await q(`select name from kiosk_app_devices`))[0].name==='Carmen kiosk','device saved');
// wrong passcode -> error json, and counter increments (not rolled back)
r = (await q(`select public.kiosk_app_command('000000','app-abc123','reload','') r`))[0].r;
ok(r.error==='wrong passcode','wrong passcode returns error');
ok((await q(`select n from fails`))[0].n===1,'wrong try counted (not rolled back)');
r = (await q(`select public.kiosk_app_command('123456','app-abc123','schedule','25:00-01:00') r`))[0].r; ok(!!r.error,'bad schedule rejected');
r = (await q(`select public.kiosk_app_command('123456','app-abc123','format_disk','') r`))[0].r; ok(!!r.error,'unknown command rejected');
r = (await q(`select public.kiosk_app_command('123456','app-zzz','reload','') r`))[0].r; ok(r.error==='tablet not found','missing tablet');
r = (await q(`select public.kiosk_app_command('123456','app-abc123','restart','') r`))[0].r; ok(r.ok===true,'command queued');
r = await beat({device_id:'app-abc123',charging:true,battery:80}); ok(r.cmd==='restart' && r.cmd_id>0,'beat returns command');
await q(`select public.kiosk_app_ack('app-abc123','wrong-token',$1,'fake')`,[r.cmd_id]);
ok(JSON.stringify(await beat({device_id:'app-abc123',charging:true,battery:80})).includes('restart'),'ack with wrong token ignored');
await q(`select public.kiosk_app_ack('app-abc123',$1,$2,'restarting')`,[TOK['app-abc123'],r.cmd_id]);
r = await beat({device_id:'app-abc123',charging:true,battery:80}); ok(JSON.stringify(r)==='{}','after ack no command');
// stale command expires
await q(`select public.kiosk_app_command('123456','app-abc123','reload','')`); await q(`update kiosk_app_devices set cmd_at=now()-interval '31 minutes'`);
r = await beat({device_id:'app-abc123',charging:true,battery:80}); ok(JSON.stringify(r)==='{}','30-min old command expires');
// list
let L = (await q(`select public.kiosk_app_list('123456') r`))[0].r; ok(Array.isArray(L)&&L.length===1&&L[0].online===true&&L[0].events.length>=1,'list works with events');
ok((await q(`select public.kiosk_app_list('1') r`))[0].r.error==='wrong passcode','list wrong passcode');
// tick: event notice
await q(`select public.kiosk_app_tick()`); let S=(await q(`select msg from sent order by id`)).map(x=>x.msg);
ok(S.some(m=>m.includes('tablet restarted')),'restart event sent to Telegram'); ok(!S.some(m=>m.includes('office:')),'office commands not re-sent');
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`); ok((await q(`select count(*)::int n from sent`))[0].n===0,'no duplicate on next tick');
// low battery
await beat({device_id:'app-abc123',charging:false,battery:15});
await q(`select public.kiosk_app_tick()`); S=(await q(`select msg from sent order by id`)).map(x=>x.msg);
ok(S.filter(m=>m.includes('battery LOW')).length===1,'low battery alert once');
await q(`select public.kiosk_app_tick()`); ok((await q(`select count(*)::int n from sent where msg like '%battery LOW%'`))[0].n===1,'low battery not repeated');
// NOT CHARGING: alert after 5 min with battery %, reminder after 30 min (day) / 2 h (night)
await q(`delete from sent`);
await q(`update kiosk_app_devices set unplugged_since=now()-interval '3 minutes' where device_id='app-abc123'`);
await q(`select public.kiosk_app_tick()`); ok((await q(`select count(*)::int n from sent where msg like '%NOT CHARGING for%'`))[0].n===0,'no not-charging alert before 5 min');
await q(`update kiosk_app_devices set unplugged_since=now()-interval '75 minutes' where device_id='app-abc123'`);
await q(`select public.kiosk_app_tick()`);
let M=(await q(`select msg from sent where msg like '%NOT CHARGING for%'`)).map(x=>x.msg);
ok(M.length===1 && M[0].includes('1 h 15 min') && M[0].includes('Battery 15%'),'not-charging alert shows time + battery %: '+M[0]);
await q(`select public.kiosk_app_tick()`); ok((await q(`select count(*)::int n from sent where msg like '%NOT CHARGING for%'`))[0].n===1,'no repeat right away');
await q(`update kiosk_app_devices set unplugged_alerted_at=now()-interval '31 minutes'`);
await q(`select public.kiosk_app_tick()`);
const hr = (await q(`select extract(hour from now() at time zone 'Asia/Manila')::int h`))[0].h;
const rem=(await q(`select count(*)::int n from sent where msg like '%NOT CHARGING for%'`))[0].n;
ok((hr>=6&&hr<22)? rem===2 : rem===1, 'reminder after 30 min in daytime, not at night (hour '+hr+')');
await q(`update kiosk_app_devices set unplugged_alerted_at=now()-interval '121 minutes'`);
await q(`select public.kiosk_app_tick()`); ok((await q(`select count(*)::int n from sent where msg like '%NOT CHARGING for%'`))[0].n===rem+1,'reminder after 2 h always');
// battery steps 50/30/20/10, each once
await q(`delete from sent`); await q(`update kiosk_app_devices set batt_step=100, low_batt_alerted=false where device_id='app-abc123'`);
for (const b of [60,48,47,29,19,9,8]) { await beat({device_id:'app-abc123',charging:false,battery:b}); await q(`select public.kiosk_app_tick()`); }
const steps=(await q(`select msg from sent where msg like '%battery%' order by id`)).map(x=>x.msg);
ok(steps.length===4 && steps[0].includes('48%') && steps[1].includes('29%') && steps[2].includes('LOW 19%') && steps[3].includes('CRITICAL 9%'),'battery steps once each: '+JSON.stringify(steps));
await beat({device_id:'app-abc123',charging:true,battery:9});
await q(`select public.kiosk_app_tick()`);
ok((await q(`select unplugged_since is null and not low_batt_alerted and batt_step=100 and not unplugged_alerted ok from kiosk_app_devices where device_id='app-abc123'`))[0].ok,'charging resets flags');
ok((await q(`select count(*)::int n from sent where msg like '%charging again. Battery 9%'`))[0].n===1,'charging-again notice with battery %');
// silent tablet skipped
await q(`update kiosk_app_devices set last_seen=now()-interval '20 minutes', charging=false, battery=5, low_batt_alerted=false`);
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`); ok((await q(`select count(*)::int n from sent where msg not like '%OFFLINE%'`))[0].n===0,'silent tablet: no battery alerts (only the offline alarm)');
// 20 tablet cap
for (let i=0;i<25;i++) await beat({device_id:'app-t'+i});
ok((await q(`select count(*)::int n from kiosk_app_devices`))[0].n===20,'max 20 tablets');
// flood guard: same event within 60 s dropped
await q(`delete from kiosk_app_events`);
for (let i=0;i<5;i++) await beat({device_id:'app-abc123',charging:true,battery:80,event:'tablet restarted'});
ok((await q(`select count(*)::int n from kiosk_app_events`))[0].n===1,'duplicate events dropped');
for (let i=0;i<30;i++) await beat({device_id:'app-abc123',charging:true,battery:80,event:'updated to build '+(100+i)});
ok((await q(`select count(*)::int n from kiosk_app_events`))[0].n===20,'max 20 events per hour');
await q(`delete from sent`); await q(`update kiosk_app_events set notified=false, event='tablet restarted '||id`);
await q(`select public.kiosk_app_tick()`); ok((await q(`select count(*)::int n from sent where msg like '%tablet restarted%'`))[0].n===5,'max 5 Telegram event messages per tick');
// schedule text validated
await beat({device_id:'app-abc123',sched_on:"0');x",sched_off:'22:30'});
ok((await q(`select sched_on is null and sched_off='22:30' ok from kiosk_app_devices where device_id='app-abc123'`))[0].ok,'bad schedule text not stored');
// 7-day cleanup
await q(`update kiosk_app_devices set last_seen=now()-interval '8 days' where device_id='app-t3'`);
await q(`select public.kiosk_app_tick()`); ok((await q(`select count(*)::int n from kiosk_app_devices where device_id='app-t3'`))[0].n===0,'stale tablet removed after 7 days');
// dashboard status RPC (no passcode, read-only)
let ST=(await q(`select public.kiosk_app_status() r`))[0].r;
ok(Array.isArray(ST) && ST.length>0 && 'battery' in ST[0] && 'charging' in ST[0] && !('cmd' in ST[0]) && !('page_url' in ST[0]) && !('device_id' in ST[0]),'status RPC: battery/charging only, no tablet ids');
// ---- security ----
const fake = (await q(`select public.kiosk_app_beat('{"device_id":"app-abc123","charging":true,"battery":100,"name":"Hacked"}') r`))[0].r;
ok(fake.error==='token' && (await q(`select name from kiosk_app_devices where device_id='app-abc123'`))[0].name==='Carmen kiosk','report without the secret is ignored');
await beat({device_id:'app-abc123',name:'Carmen <b>kiosk</b>',event:'hello <script>'});
ok((await q(`select name from kiosk_app_devices where device_id='app-abc123'`))[0].name==='Carmen bkioskb','name: only letters, digits, space . _ -');
ok((await q(`select count(*)::int n from kiosk_app_events where event like '%script%' or event like 'hello%'`))[0].n===0,'unknown event text dropped');
await beat({device_id:'app-abc123',name:'Carmen kiosk'});
// ---- Wi-Fi / offline / heat (2026-11-03) ----
const MH = (await q(`select extract(hour from now() at time zone 'Asia/Manila')::int*60 + extract(minute from now() at time zone 'Asia/Manila')::int m`))[0].m;
const inWork = MH >= 360 && MH < 1320;
const hh = m => String(Math.floor(((m%1440)+1440)%1440/60)).padStart(2,'0')+':'+String(((m%1440)+1440)%1440%60).padStart(2,'0');
await q(`delete from sent`);
await beat({device_id:'app-w1',name:'Carmen kiosk',charging:true,battery:70,wifi:true,internet:true,wifi_signal:3,battery_temp:'33.5',sched_on:'00:00',sched_off:'23:59'});
let W=(await q(`select wifi,internet,wifi_signal,battery_temp::float t from kiosk_app_devices where device_id='app-w1'`))[0];
ok(W.wifi===true && W.internet===true && W.wifi_signal===3 && W.t===33.5,'wifi/signal/temp stored');
await beat({device_id:'app-w1',wifi_signal:'9',battery_temp:'hot'});
W=(await q(`select wifi_signal,battery_temp from kiosk_app_devices where device_id='app-w1'`))[0];
ok(W.wifi_signal===null && W.battery_temp===null,'bad wifi/temp values not stored');
// offline 12 min with last report "no wifi"
await beat({device_id:'app-w1',name:'Carmen kiosk',charging:true,battery:70,wifi:false,sched_on:'00:00',sched_off:'23:59'});
await q(`update kiosk_app_devices set last_seen=now()-interval '12 minutes' where device_id='app-w1'`);
await q(`select public.kiosk_app_tick()`);
let O=(await q(`select msg from sent where msg like '%OFFLINE%'`)).map(x=>x.msg);
ok(inWork ? (O.length===1 && O[0].includes('Carmen kiosk is OFFLINE - no report for 12 min') && O[0].includes('no Wi-Fi')) : O.length===0, 'offline alert at 10+ min (work hours): '+O[0]);
await q(`select public.kiosk_app_tick()`);
ok((await q(`select count(*)::int n from sent where msg like '%OFFLINE%'`))[0].n===O.length,'offline not repeated within the hour');
if (inWork) { await q(`update kiosk_app_devices set offline_alerted_at=now()-interval '61 minutes' where device_id='app-w1'`);
  await q(`select public.kiosk_app_tick()`); ok((await q(`select count(*)::int n from sent where msg like '%OFFLINE%'`))[0].n===2,'offline reminder after 60 min'); }
// battery ran out
await q(`delete from sent`);
await q(`update kiosk_app_devices set charging=false,battery=8,offline_alerted_at=null,offline_first_at=null,last_seen=now()-interval '15 minutes' where device_id='app-w1'`);
await q(`select public.kiosk_app_tick()`);
O=(await q(`select msg from sent where msg like '%OFFLINE%'`)).map(x=>x.msg);
ok(!inWork || (O.length===1 && O[0].includes('battery probably ran out')),'offline reason: battery ran out');
// back online with the tablet's own reason
await q(`delete from sent`);
await beat({device_id:'app-w1',charging:true,battery:9,outage:{from:'x',to:'y',minutes:25,reason:'Wi-Fi connected but no internet'}});
await q(`select public.kiosk_app_tick()`);
O=(await q(`select msg from sent where msg like '%back ONLINE%'`)).map(x=>x.msg);
ok(!inWork || (O.length===1 && O[0].includes('offline 25 min - Wi-Fi connected but no internet') && O[0].includes('Battery 9%')),'back online with reason: '+O[0]);
ok((await q(`select count(*)::int n from kiosk_app_events where device_id='app-w1' and event='was offline 25 min: Wi-Fi connected but no internet'`))[0].n===1,'outage logged as event');
await beat({device_id:'app-w1',charging:true,battery:9,outage:{minutes:25,reason:'Wi-Fi connected but no internet'}});
ok((await q(`select count(*)::int n from kiosk_app_events where device_id='app-w1' and event like 'was offline%'`))[0].n===1,'same outage not logged twice');
await beat({device_id:'app-w1',outage:{minutes:5,reason:'<script>'}});
ok((await q(`select count(*)::int n from kiosk_app_events where event like '%script%'`))[0].n===0,'unknown outage reason ignored');
await q(`select public.kiosk_app_tick()`);
ok((await q(`select count(*)::int n from sent where msg like '%back ONLINE%'`))[0].n===O.length,'back online sent once');
// flapping Wi-Fi: back online, then offline again 15 min later -> no second OFFLINE within the hour
if (inWork) { await q(`delete from sent`);
  await q(`update kiosk_app_devices set last_seen=now()-interval '15 minutes' where device_id='app-w1'`);
  await q(`select public.kiosk_app_tick()`);
  ok((await q(`select count(*)::int n from sent where msg like '%OFFLINE%'`))[0].n===0,'flapping Wi-Fi: no new OFFLINE within the hour');
  await q(`update kiosk_app_devices set last_seen=now() where device_id='app-w1'`); await q(`select public.kiosk_app_tick()`);
  ok((await q(`select count(*)::int n from sent where msg like '%back ONLINE%'`))[0].n===0,'no BACK ONLINE without an OFFLINE'); }
// screen schedule says asleep -> no offline alarm
await q(`delete from sent`);
await q(`update kiosk_app_devices set sched_on=$1, sched_off=$2, last_seen=now()-interval '20 minutes', offline_alerted_at=null, offline_first_at=null where device_id='app-w1'`,[hh(MH+60),hh(MH+600)]);
await q(`select public.kiosk_app_tick()`);
ok((await q(`select count(*)::int n from sent where msg like '%OFFLINE%'`))[0].n===0,'no offline alarm while the screen schedule has it off');
// within 15 min after ON time -> no alarm yet
await q(`update kiosk_app_devices set sched_on=$1, sched_off=$2 where device_id='app-w1'`,[hh(MH-10),hh(MH+600)]);
await q(`select public.kiosk_app_tick()`);
ok((await q(`select count(*)::int n from sent where msg like '%OFFLINE%'`))[0].n===0,'15-min grace after screen ON time');
// retired tablet (2 days silent) -> no alarm
await q(`update kiosk_app_devices set sched_on='00:00', sched_off='23:59', last_seen=now()-interval '2 days' where device_id='app-w1'`);
await q(`select public.kiosk_app_tick()`);
ok((await q(`select count(*)::int n from sent where msg like '%OFFLINE%'`))[0].n===0,'tablet silent over 24 h: no alarm');
// hot battery
await q(`delete from sent`);
await beat({device_id:'app-w1',charging:true,battery:80,battery_temp:'46.2'});
await q(`select public.kiosk_app_tick()`); await q(`select public.kiosk_app_tick()`);
ok((await q(`select count(*)::int n from sent where msg like '%HOT - battery 46.2 C%'`))[0].n===1,'hot alert once');
await beat({device_id:'app-w1',charging:true,battery:80,battery_temp:'42'}); await q(`select public.kiosk_app_tick()`);
ok((await q(`select hot_alerted from kiosk_app_devices where device_id='app-w1'`))[0].hot_alerted===true,'hot flag stays until below 40 C');
await beat({device_id:'app-w1',charging:true,battery:80,battery_temp:'38'}); await q(`select public.kiosk_app_tick()`);
ok((await q(`select hot_alerted from kiosk_app_devices where device_id='app-w1'`))[0].hot_alerted===false,'hot flag clears below 40 C');
L = (await q(`select public.kiosk_app_list('123456') r`))[0].r;
ok(L.some(x=>'wifi_signal' in x && 'battery_temp' in x && 'last_outage' in x),'list includes wifi/temp/outage');
// ---- generator hours (Carmen) ----
if (MH > 90 && MH < 1290) {
  await q(`delete from kiosk_app_devices where device_id like 'app-t%'`);   // free the 20-tablet cap used earlier
  await q(`delete from sent`);
  await beat({device_id:'app-g1',name:'Carmen kiosk G',charging:true,battery:80,sched_on:'06:45',sched_off:'22:30'});
  let R = (await q(`select public.kiosk_app_set_power('000000','app-g1','08:00-11:30') r`))[0].r; ok(R.error==='wrong passcode','set power: passcode needed');
  R = (await q(`select public.kiosk_app_set_power('123456','app-g1','11:30-08:00') r`))[0].r; ok(!!R.error,'set power: end before start rejected');
  R = (await q(`select public.kiosk_app_set_power('123456','app-g1','8-11') r`))[0].r; ok(!!R.error,'set power: bad format rejected');
  R = (await q(`select public.kiosk_app_set_power('123456','app-g1','08:00-11:30, 13:00-16:30,18:00-21:00+24:00') r`))[0].r; ok(R.ok===true,'set power: Carmen hours accepted (spaces, +24:00 overtime)');
  ok((await q(`select power_windows from kiosk_app_devices where device_id='app-g1'`))[0].power_windows==='08:00-11:30,13:00-16:30,18:00-21:00+24:00','set power: stored clean');
  R = (await q(`select public.kiosk_app_set_power('123456','app-g1','08:00-08:20') r`))[0].r; ok(!!R.error,'set power: under 30 min rejected');
  R = (await q(`select public.kiosk_app_set_power('123456','app-g1','18:00-21:00+20:00') r`))[0].r; ok(!!R.error,'set power: overtime before stop rejected');
  const ST=(await q(`select public.kiosk_app_power_state('08:00-11:30,13:00-16:30,18:00-21:00+24:00', m) s, m from unnest(array[455,485,680,687,690,750,790,1000,1095,1100,1258,1265,1439,5]) m`)).map(x=>x.m+':'+x.s).join(' ');
  ok(ST==='455:off 485:grace 680:on 687:grace 690:off 750:off 790:grace 1000:off 1095:on 1100:on 1258:grace 1265:overtime 1439:overtime 5:off','power states through a Carmen day: '+ST);
  await q(`select public.kiosk_app_set_power('123456','app-g1','08:00-11:30,13:00-16:30,18:00-21:00+24:00')`);
  ok((await q(`select public.kiosk_app_power_on('08:00-11:30,13:00-16:30',${8*60+20}) a, public.kiosk_app_power_on('08:00-11:30,13:00-16:30',${8*60+10}) b, public.kiosk_app_power_on('08:00-11:30,13:00-16:30',${12*60}) c, public.kiosk_app_power_on(null,${12*60}) d`))[0].a===true,'power_on: 8:20 on');
  const P=(await q(`select public.kiosk_app_power_on('08:00-11:30,13:00-16:30',${8*60+10}) b, public.kiosk_app_power_on('08:00-11:30,13:00-16:30',${12*60}) c, public.kiosk_app_power_on(null,${12*60}) d, public.kiosk_app_power_on('08:00-11:30',${11*60+27}) e`))[0];
  ok(P.b===false && P.c===false && P.d===true && P.e===false,'power_on: 15-min start grace, lunch off, grid always on, 5 min before stop');
  // generator OFF now, not charging, plenty of battery -> silence
  await q(`select public.kiosk_app_set_power('123456','app-g1',$1)`,[hh(MH+60)+'-'+hh(MH+120)]);
  await beat({device_id:'app-g1',charging:false,battery:90});
  await q(`update kiosk_app_devices set unplugged_since=now()-interval '40 minutes', batt_step=100 where device_id='app-g1'`);
  await beat({device_id:'app-g1',charging:false,battery:48});
  await q(`select public.kiosk_app_tick()`);
  let G=(await q(`select msg from sent`)).map(x=>x.msg).filter(m=>m.includes('Carmen kiosk'));
  ok(G.length===0,'generator off, battery fine: no alerts at all (no NOT CHARGING, no 50% step): '+JSON.stringify(G));
  // generator OFF, battery too low to last -> one run-out warning
  await beat({device_id:'app-g1',charging:false,battery:15});
  await q(`select public.kiosk_app_tick()`); await q(`select public.kiosk_app_tick()`);
  G=(await q(`select msg from sent where msg like '%may RUN OUT%'`)).map(x=>x.msg);
  ok(G.length===1 && G[0].includes('on battery (generator off): 15%') && G[0].includes('Generator back at'),'run-out warning once: '+G[0]);
  ok((await q(`select count(*)::int n from sent where msg like '%LOW 15%'`))[0].n===0,'generator off: no 20% LOW step');
  await beat({device_id:'app-g1',charging:false,battery:9}); await q(`select public.kiosk_app_tick()`);
  ok((await q(`select count(*)::int n from sent where msg like '%CRITICAL 9%'`))[0].n===1,'generator off: 10% CRITICAL still sent');
  // status for dashboard
  let ST2=(await q(`select public.kiosk_app_status() r`))[0].r.find(x=>x.name==='Carmen kiosk G');
  ok(ST2.power_expected===false && ST2.may_run_out===true && !!ST2.power_back_at,'status: generator off, may run out, back-at time');
  // generator ON (window started 30 min ago) and not charging -> NOT CHARGING with generator wording
  await q(`delete from sent`);
  await q(`select public.kiosk_app_set_power('123456','app-g1',$1)`,[hh(MH-30)+'-'+hh(MH+120)]);
  await beat({device_id:'app-g1',charging:false,battery:60});
  await q(`update kiosk_app_devices set unplugged_alerted_at=null, unplugged_alerted=false where device_id='app-g1'`);
  await q(`select public.kiosk_app_tick()`);
  G=(await q(`select msg from sent where msg like '%NOT CHARGING%'`)).map(x=>x.msg);
  ok(G.length===1 && G[0].includes('generator should be ON') && G[0].includes('Battery 60%'),'generator on + not charging: alert: '+G[0]);
  ST2=(await q(`select public.kiosk_app_status() r`))[0].r.find(x=>x.name==='Carmen kiosk G');
  ok(ST2.power_expected===true && ST2.may_run_out===false,'status: generator on');
  ok((await q(`select count(*)::int n from sent where msg like '%60%% and NOT CHARGING%' or msg like '%battery 60%'`))[0].n===0,'no stale battery-step message when generator comes on');
  // generator just started (grace): no NOT CHARGING and NO false run-out warning
  await q(`delete from sent`);
  await q(`select public.kiosk_app_set_power('123456','app-g1',$1)`,[hh(MH-3)+'-'+hh(MH+120)]);
  await beat({device_id:'app-g1',charging:false,battery:40});
  await q(`update kiosk_app_devices set unplugged_alerted_at=null, unplugged_alerted=false, risk_alerted_for=null where device_id='app-g1'`);
  await q(`select public.kiosk_app_tick()`);
  ok((await q(`select count(*)::int n from sent`))[0].n===0,'generator start grace: no NOT CHARGING, no false run-out');
  ST2=(await q(`select public.kiosk_app_status() r`))[0].r.find(x=>x.name==='Carmen kiosk G');
  ok(ST2.power_state==='grace' && ST2.may_run_out===false && ST2.generator===true,'status in grace: no may_run_out');
  // overtime part: on battery is normal; no NOT CHARGING, no 50/30/20 steps
  await q(`delete from sent`);
  await q(`select public.kiosk_app_set_power('123456','app-g1',$1)`,[hh(MH-120)+'-'+hh(MH-30)+'+'+hh(MH+120)]);
  await beat({device_id:'app-g1',charging:false,battery:45});
  await q(`update kiosk_app_devices set unplugged_since=now()-interval '40 minutes', unplugged_alerted_at=null, unplugged_alerted=false, batt_step=100, risk_alerted_for=null where device_id='app-g1'`);
  await q(`select public.kiosk_app_tick()`);
  G=(await q(`select msg from sent`)).map(x=>x.msg);
  ok(!G.some(m=>m.includes('NOT CHARGING')||m.includes('45% and NOT')),'overtime part: no NOT CHARGING, no steps: '+JSON.stringify(G));
  // window started only 10 min ago -> grace, no alert
  await q(`delete from sent`);
  await q(`select public.kiosk_app_set_power('123456','app-g1',$1)`,[hh(MH-10)+'-'+hh(MH+120)]);
  await q(`update kiosk_app_devices set unplugged_alerted_at=null, unplugged_alerted=false where device_id='app-g1'`);
  await q(`select public.kiosk_app_tick()`);
  ok((await q(`select count(*)::int n from sent where msg like '%NOT CHARGING%'`))[0].n===0,'generator start grace 15 min');
  // charging again resets the run-out flag
  await beat({device_id:'app-g1',charging:true,battery:20}); await q(`select public.kiosk_app_tick()`);
  ok((await q(`select risk_alerted_for is null ok from kiosk_app_devices where device_id='app-g1'`))[0].ok,'charging clears run-out flag');
  // need_pct: 1 h awake = 20% + 10 margin = 30
  ok((await q(`select public.kiosk_app_need_pct(now(), now()+interval '1 hour', '00:00','23:59') n`))[0].n===25,'need 25% for 1 h awake (starting estimate 15%/h + 10)');
  ok((await q(`select public.kiosk_app_need_pct(now(), now()+interval '1 hour', '00:00','23:59', 8, null) n`))[0].n===18,'measured 8%/h used: need 18%');
  ok((await q(`select public.kiosk_app_need_pct(now(), now()+interval '1 hour', '00:00','23:59', 500, null) n`))[0].n===50,'crazy measured rate clamped to 40%/h');
  // a Carmen night at 9 PM with the starting estimate: 21:00-22:30 on, 22:30-06:45 off, 06:45-08:00 on
  const night=(await q(`select public.kiosk_app_need_pct('2026-11-03 21:00+08','2026-11-04 08:00+08','06:45','22:30') n`))[0].n;
  ok(night <= 80,'9 PM to 8 AM need with starting estimate is under 85% (no nightly false warning): '+night);
  ok((await q(`select public.kiosk_app_set_power('123456','app-g1','') r`))[0].r.ok===true && (await q(`select power_windows is null ok from kiosk_app_devices where device_id='app-g1'`))[0].ok,'clear generator hours = grid power');
}
// ---- drain learning ----
await q(`delete from kiosk_app_devices where device_id like 'app-t%'`);
await beat({device_id:'app-d1',name:'Drain test',charging:false,battery:80,screen_on:true});
let D=(await q(`select drain_anchor_batt b, drain_anchor_screen s from kiosk_app_devices where device_id='app-d1'`))[0];
ok(D.b===80 && D.s===true,'drain: anchor set on battery');
await q(`update kiosk_app_devices set drain_anchor_at=now()-interval '30 minutes', last_seen=now()-interval '1 minute' where device_id='app-d1'`);
await beat({device_id:'app-d1',charging:false,battery:75,screen_on:true});
D=(await q(`select drain_on::float r, drain_on_n n, drain_anchor_batt b from kiosk_app_devices where device_id='app-d1'`))[0];
ok(D.n===1 && Math.abs(D.r-10)<0.2 && D.b===75,'drain: 5 points in 30 min = 10%/h learned: '+D.r);
// screen off overnight with a long gap: counts as sleep drain
await beat({device_id:'app-d1',charging:false,battery:75,screen_on:false});
await q(`update kiosk_app_devices set drain_anchor_at=now()-interval '8 hours', last_seen=now()-interval '8 hours' where device_id='app-d1'`);
await beat({device_id:'app-d1',charging:false,battery:51,screen_on:true});
D=(await q(`select drain_off::float r, drain_off_n n from kiosk_app_devices where device_id='app-d1'`))[0];
ok(D.n===1 && Math.abs(D.r-3)<0.1,'drain: night sleep 24 points in 8 h = 3%/h: '+D.r);
// screen ON with a long gap: dropped
await q(`update kiosk_app_devices set drain_anchor_at=now()-interval '3 hours', last_seen=now()-interval '3 hours' where device_id='app-d1'`);
await beat({device_id:'app-d1',charging:false,battery:40,screen_on:true});
D=(await q(`select drain_on_n n from kiosk_app_devices where device_id='app-d1'`))[0];
ok(D.n===1,'drain: screen-on measurement across a reporting gap is dropped');
// charging clears the anchor
await beat({device_id:'app-d1',charging:true,battery:41,screen_on:true});
ok((await q(`select drain_anchor_at is null ok from kiosk_app_devices where device_id='app-d1'`))[0].ok,'drain: charging ends the measurement');
// list shows learned rates only after 3 measurements, and asleep flag
await q(`update kiosk_app_devices set drain_on_n=3, sched_on='00:00', sched_off='00:01' where device_id='app-d1'`);
L = (await q(`select public.kiosk_app_list('123456') r`))[0].r.find(x=>x.device_id==='app-d1');
ok(L.drain_on!==null && L.drain_off===null && L.asleep===true,'list: learned rate after 3, asleep by schedule');
// ---- weak charger, named tablets kept, evening screen-off ----
await q(`delete from sent`);
await beat({device_id:'app-w2',name:'Weak test',charging:true,charge_state:'discharging',battery:60});
await q(`update kiosk_app_devices set weak_since=now()-interval '16 minutes' where device_id='app-w2'`);
await q(`select public.kiosk_app_tick()`); await q(`select public.kiosk_app_tick()`);
ok((await q(`select count(*)::int n from sent where msg like '%PLUGGED IN but NOT taking charge%'`))[0].n===1,'weak charger alert once');
await beat({device_id:'app-w2',charging:true,charge_state:'not_charging',battery:85});
ok((await q(`select weak_since is null ok from kiosk_app_devices where device_id='app-w2'`))[0].ok,'not_charging at 85% (Protect battery) is not a weak charger');
await q(`update kiosk_app_devices set last_seen=now()-interval '9 days' where device_id='app-w2'`);
await q(`select public.kiosk_app_tick()`);
ok((await q(`select count(*)::int n from kiosk_app_devices where device_id='app-w2'`))[0].n===1,'named tablet silent 9 days is kept (generator hours survive a shutdown)');
ok((await q(`select public.kiosk_app_forget('123456','app-w2') r`))[0].r.ok===true && (await q(`select count(*)::int n from kiosk_app_devices where device_id='app-w2'`))[0].n===0,'office can forget a tablet');
// ---- token: lost first reply must not lock the tablet out ----
const t1 = (await q(`select public.kiosk_app_beat('{"device_id":"app-tk1","name":"Token test"}') r`))[0].r;
ok(/^[0-9a-f-]{36}$/.test(t1.token||''),'first report gets a secret');
const t2 = (await q(`select public.kiosk_app_beat('{"device_id":"app-tk1","battery":50}') r`))[0].r;
ok(t2.token===t1.token && !t2.error,'first reply lost: next report without secret accepted, same secret sent again');
const t3 = (await q(`select public.kiosk_app_beat($1::jsonb) r`,[JSON.stringify({device_id:'app-tk1',token:t1.token,battery:49})]))[0].r;
ok(!t3.error && !t3.token && (await q(`select token_confirmed c from kiosk_app_devices where device_id='app-tk1'`))[0].c===true,'secret sent back: confirmed');
const t4 = (await q(`select public.kiosk_app_beat('{"device_id":"app-tk1","battery":10}') r`))[0].r;
ok(t4.error==='token' && (await q(`select battery from kiosk_app_devices where device_id='app-tk1'`))[0].battery===49,'after confirm: report without secret refused');
const t5 = (await q(`select public.kiosk_app_beat('{"device_id":"app-tk1","token":"guess"}') r`))[0].r;
ok(t5.error==='token','wrong secret refused');
await beat({device_id:'app-tk1',token:t1.token,name:'Niño kiosk'});
ok((await q(`select name from kiosk_app_devices where device_id='app-tk1'`))[0].name==='Niño kiosk','accented names kept');
// ---- page version + last page error + screenshot (2026-11-04) ----
await beat({device_id:'app-tk1',token:t1.token,page_version:'v2026-10-16d',page_error:'Uncaught TypeError: x is <b>null</b>',page_error_at:'2026-11-04T06:00:00Z'});
let PV=(await q(`select page_version,page_error,page_error_at from kiosk_app_devices where device_id='app-tk1'`))[0];
ok(PV.page_version==='v2026-10-16d','kiosk page version saved');
ok(PV.page_error==='Uncaught TypeError: x is bnull/b' && PV.page_error_at!==null,'last page error saved, < > stripped');
await beat({device_id:'app-tk1',token:t1.token,page_version:'<script>alert(1)</script>'});
ok((await q(`select page_version v from kiosk_app_devices where device_id='app-tk1'`))[0].v==='v2026-10-16d','junk version ignored (old one kept)');
await beat({device_id:'app-tk1',token:t1.token,page_error:'x'.repeat(5000)});
ok((await q(`select length(page_error) n from kiosk_app_devices where device_id='app-tk1'`))[0].n<=300,'long error cut to 300');
await beat({device_id:'app-tk1',token:t1.token});
ok((await q(`select page_error e from kiosk_app_devices where device_id='app-tk1'`))[0].e!==null,'a report without an error keeps the last error');
r=(await q(`select public.kiosk_app_command('123456','app-tk1','screenshot','') r`))[0].r; ok(r.ok===true,'screenshot command accepted');
const JPG='/9j/'+'A'.repeat(2000);
r=(await q(`select public.kiosk_app_shot_put('app-tk1','guess',$1) r`,[JPG]))[0].r; ok(r.error==='token','shot with wrong secret refused');
ok((await q(`select count(*)::int n from kiosk_app_shots`))[0].n===0,'nothing stored on refusal');
r=(await q(`select public.kiosk_app_shot_put('app-tk1',$1,$2) r`,[t1.token,'hello<script>']))[0].r; ok(r.error==='not a jpeg','non-jpeg refused');
r=(await q(`select public.kiosk_app_shot_put('app-tk1',$1,$2) r`,[t1.token,'/9j/'+'A'.repeat(700001)]))[0].r; ok(r.error==='too big','over-size picture refused');
r=(await q(`select public.kiosk_app_shot_put('app-tk1',$1,$2) r`,[t1.token,JPG]))[0].r; ok(r.ok===true,'shot stored');
r=(await q(`select public.kiosk_app_shot_put('app-tk1',$1,$2) r`,[t1.token,JPG+'B']))[0].r;
ok((await q(`select count(*)::int n from kiosk_app_shots`))[0].n===1,'only the latest shot per tablet is kept');
r=(await q(`select public.kiosk_app_shot_get('000000','app-tk1') r`))[0].r; ok(r.error==='wrong passcode' && !r.jpeg,'shot needs the admin passcode');
r=(await q(`select public.kiosk_app_shot_get('123456','app-tk1') r`))[0].r; ok(r.jpeg===JPG+'B' && !!r.taken_at,'office gets the latest shot');
r=(await q(`select public.kiosk_app_shot_get('123456','app-none') r`))[0].r; ok(r.error==='no screenshot yet','no shot yet');
L=(await q(`select public.kiosk_app_list('123456') r`))[0].r; const LT=L.find(x=>x.device_id==='app-tk1');
ok(LT.page_version==='v2026-10-16d' && !!LT.page_error && !!LT.shot_at && !('jpeg' in LT),'list shows version, error, shot time (never the picture itself)');
r=await beat({device_id:'app-tk1',token:t1.token,battery:48,page_error:'later error',page_error_at:'2026-02-31T25:00:00Z'});
ok(!r.error && (await q(`select battery from kiosk_app_devices where device_id='app-tk1'`))[0].battery===48,'impossible error time never breaks the heartbeat');
ok((await q(`select page_error_at>now()-interval '1 minute' f from kiosk_app_devices where device_id='app-tk1'`))[0].f===true,'bad error time -> report time used');
await beat({device_id:'app-tk1',token:t1.token,page_error:'future',page_error_at:'2099-01-01T00:00:00Z'});
ok((await q(`select page_error_at<=now() f from kiosk_app_devices where device_id='app-tk1'`))[0].f===true,'error time never in the future');
await q(`select public.kiosk_app_forget('123456','app-tk1')`);
ok((await q(`select count(*)::int n from kiosk_app_shots where device_id='app-tk1'`))[0].n===0,'forget tablet also deletes its screenshot');
// ROLL-CALL PHONE (owner 2026-11-12): page = Job Monitoring -> no OFFLINE / NOT CHARGING, battery only 20% + 10%
const RC='https://seafordprojects-bit.github.io/rsr-engineering/monitoring/roll-call.html?site=Carmen';
ok((await q(`select public.kiosk_app_is_phone($1) a, public.kiosk_app_is_phone($2) b, public.kiosk_app_is_phone(null) c, public.kiosk_app_is_phone($3) d`,
   [RC,'https://seafordprojects-bit.github.io/rsr-engineering/kiosk/?site=Mandaue','https://seafordprojects-bit.github.io/rsr-engineering/kiosk/?x=/monitoring/'])).map(x=>[x.a,x.b,x.c,x.d].join())[0]==='true,false,false,false',
   'phone = Job Monitoring page only (kiosk, empty, query trick = tablet)');
await q(`delete from sent`);
await beat({device_id:'app-ph1',name:'Carmen roll-call phone',battery:60,charging:false,screen_on:false,page_url:RC});
await q(`update kiosk_app_devices set unplugged_since=now()-interval '3 hours' where device_id='app-ph1'`);
await q(`select public.kiosk_app_tick()`);
ok((await q(`select count(*)::int n from sent where msg like '%Carmen roll-call phone%'`))[0].n===0,'phone on battery 60%: no NOT CHARGING, no 50% step');
await beat({device_id:'app-ph1',battery:45,charging:false,page_url:RC}); await q(`select public.kiosk_app_tick()`);
await beat({device_id:'app-ph1',battery:28,charging:false,page_url:RC}); await q(`select public.kiosk_app_tick()`);
ok((await q(`select count(*)::int n from sent where msg like '%Carmen roll-call phone%'`))[0].n===0,'phone 45% / 28%: still quiet (no 50/30 steps)');
await beat({device_id:'app-ph1',battery:19,charging:false,page_url:RC}); await q(`select public.kiosk_app_tick()`); await q(`select public.kiosk_app_tick()`);
let PH=(await q(`select msg from sent where msg like '%Carmen roll-call phone%'`)).map(x=>x.msg);
ok(PH.length===1 && /battery LOW 19%/.test(PH[0]),'phone 19%: one LOW alert');
await beat({device_id:'app-ph1',battery:9,charging:false,page_url:RC}); await q(`select public.kiosk_app_tick()`);
PH=(await q(`select msg from sent where msg like '%Carmen roll-call phone%'`)).map(x=>x.msg);
ok(PH.length===2 && /CRITICAL 9%/.test(PH[1]),'phone 9%: one CRITICAL alert');
await q(`update kiosk_app_devices set last_seen=now()-interval '5 hours' where device_id='app-ph1'`);
await q(`select public.kiosk_app_tick()`);
ok((await q(`select count(*)::int n from sent where msg like '%Carmen roll-call phone%OFFLINE%'`))[0].n===0,'phone silent for hours (in the yard): no OFFLINE alert');
await beat({device_id:'app-ph1',battery:15,charging:true,page_url:RC}); await q(`select public.kiosk_app_tick()`);
ok((await q(`select batt_step from kiosk_app_devices where device_id='app-ph1'`))[0].batt_step===100 &&
   (await q(`select count(*)::int n from sent where msg like '%Carmen roll-call phone%' and (msg like '%ONLINE%' or msg like '%charging again%')`))[0].n===0,
   'phone charging: steps reset quietly, no back-ONLINE / charging-again message');
const PST=(await q(`select public.kiosk_app_status() r`))[0].r;
ok(!PST.some(x=>x.name==="Carmen roll-call phone") && PST.length>0,'dashboard charging banner leaves the phone out, tablets stay');
// phone stays a phone when it briefly shows another page or no page yet; a /kiosk/ page makes it a tablet again
await beat({device_id:'app-ph1',battery:15,charging:true,page_url:'https://seafordprojects-bit.github.io/rsr-engineering/index.html'});
await q(`update kiosk_app_devices set last_seen=now()-interval '3 hours' where device_id='app-ph1'`); await q(`select public.kiosk_app_tick()`);
await q(`update kiosk_app_devices set page_url=null, last_seen=now()-interval '3 hours' where device_id='app-ph1'`); await q(`select public.kiosk_app_tick()`);
ok((await q(`select count(*)::int n from sent where msg like '%Carmen roll-call phone%OFFLINE%'`))[0].n===0 &&
   (await q(`select phone_mode from kiosk_app_devices where device_id='app-ph1'`))[0].phone_mode===true,'phone showing another RSR page / no page: still a phone, no OFFLINE');
const LP=(await q(`select public.kiosk_app_list('123456') r`))[0].r.find(x=>x.device_id==='app-ph1');
ok(LP && LP.phone===true,'Tablets page list marks it as phone');
// weak charger on the phone: plugged in but not taking charge 15 min -> one alert
await beat({device_id:'app-ph1',battery:40,charging:true,charge_state:'discharging',page_url:RC});
await q(`update kiosk_app_devices set weak_since=now()-interval '20 minutes' where device_id='app-ph1'`);
await q(`select public.kiosk_app_tick()`); await q(`select public.kiosk_app_tick()`);
ok((await q(`select count(*)::int n from sent where msg like '%Carmen roll-call phone is PLUGGED IN but NOT taking charge%'`))[0].n===1,'phone weak charger: one alert');
await beat({device_id:'app-ph1',battery:50,charging:true,page_url:'https://seafordprojects-bit.github.io/rsr-engineering/kiosk/?site=Carmen'});
await q(`select public.kiosk_app_tick()`);
ok((await q(`select phone_mode from kiosk_app_devices where device_id='app-ph1'`))[0].phone_mode===false,'re-pointed to /kiosk/ = tablet again');
await q(`delete from kiosk_app_devices where device_id='app-ph1'`);
await q(`delete from sent`);

// ===================== BUILD-6 (2026-11-16) =====================
{
await q(`delete from sent`);
const B6='app-b6tab', MAN=`https://seafordprojects-bit.github.io/rsr-engineering/kiosk/?site=Mandaue`;
await beat({device_id:B6,name:'Mandaue Kiosk',battery:90,charging:true,screen_on:true,page_url:MAN,kiosk_device_id:'kd-1',net_type:'wifi',
            sim_operator:'GOMO<script>',sim_state:'ready',sms_ok:true,mobile_ok:true,mobile_signal:3});
let D=(await q(`select * from kiosk_app_devices where device_id=$1`,[B6]))[0];
ok(D.net_type==='wifi' && D.sim_operator==='GOMOscript' && D.sim_state==='ready' && D.sms_ok===true && D.mobile_signal===3,'beat saves connection + SIM info (cleaned)');
// stuck punches from the kiosk page's own report
await q(`insert into kiosk_health(device_id, stuck_count, queue_length, stuck_details, offline_queue_length) values ('kd-1',1,3,'[{"name":"Juan","date":"2026-11-16","times":"in 07:58 AM","reason":"server rejected"}]',2)`);
let LB=(await q(`select public.kiosk_app_list('123456') r`))[0].r.find(x=>x.device_id===B6);
ok(LB.punches && LB.punches.stuck===1 && LB.punches.queue===3 && LB.punches.offline_queue===2 && LB.punches.stuck_details[0].name==='Juan','list shows waiting + stuck punches with names');
ok(LB.net.type==='wifi' && LB.net.down_today_min===0 && Array.isArray(LB.net.periods),'list shows connection, no downtime yet');
ok(LB.sim.operator==='GOMOscript' && LB.sim.load===null && LB.sim.texts.length===0,'list shows SIM card, no load yet');
// Wi-Fi down -> mobile data: a period opens; 30 min later one alert; back on Wi-Fi closes it + one message
await beat({device_id:B6,battery:90,charging:true,page_url:MAN,net_type:'mobile'});
ok((await q(`select count(*)::int n from kiosk_app_conn where device_id=$1 and kind='mobile' and ended_at is null`,[B6]))[0].n===1,'leaving Wi-Fi opens a downtime period');
await beat({device_id:B6,battery:90,charging:true,page_url:MAN,net_type:'mobile'});
ok((await q(`select count(*)::int n from kiosk_app_conn where device_id=$1`,[B6]))[0].n===1,'same state: no second period');
await q(`update kiosk_app_devices set net_since=now()-interval '35 minutes' where device_id=$1`,[B6]);
await q(`update kiosk_app_conn set started_at=now()-interval '35 minutes' where device_id=$1`,[B6]);
await q(`select public.kiosk_app_tick()`); await q(`select public.kiosk_app_tick()`);
ok((await q(`select count(*)::int n from sent where msg like '%Mandaue Kiosk is on MOBILE DATA for 35 min%'`))[0].n===1,'on mobile data 30+ min: one alert');
await beat({device_id:B6,battery:90,charging:true,page_url:MAN,net_type:'wifi'});
await q(`select public.kiosk_app_tick()`); await q(`select public.kiosk_app_tick()`);
ok((await q(`select count(*)::int n from sent where msg like '%Mandaue Kiosk is back on Wi-Fi. It was on mobile data 35 min%'`))[0].n===1,'back on Wi-Fi: one message with how long');
LB=(await q(`select public.kiosk_app_list('123456') r`))[0].r.find(x=>x.device_id===B6);
ok(LB.net.down_7d_min>=34 && LB.net.down_7d_min<=36 && LB.net.periods[0].kind==='mobile' && LB.net.periods[0].to,'downtime 7 days counts the closed period');
// outage reported by the tablet when it is back -> closed offline period
await beat({device_id:B6,battery:90,charging:true,page_url:MAN,net_type:'wifi',outage:{minutes:12,reason:'Wi-Fi off / not connected',from:'x',to:'y'}});
ok((await q(`select count(*)::int n from kiosk_app_conn where device_id=$1 and kind='offline' and ended_at is not null and reason like 'Wi-Fi off%'`,[B6]))[0].n===1,'offline outage becomes a closed period');
// mobile data per day: only today and 2 days before, bad keys ignored, never lowered
const td=(await q(`select to_char((now() at time zone 'Asia/Manila')::date,'YYYY-MM-DD') d`))[0].d;
const old=(await q(`select to_char((now() at time zone 'Asia/Manila')::date-10,'YYYY-MM-DD') d`))[0].d;
await beat({device_id:B6,battery:90,charging:true,page_url:MAN,mobile_days:{[td]:52428800,[old]:999,'2026-02-30':5,'x':1}});
await beat({device_id:B6,battery:90,charging:true,page_url:MAN,mobile_days:{[td]:1000}});
let DD=await q(`select day::text, bytes::bigint from kiosk_app_data_days where device_id=$1`,[B6]);
ok(DD.length===1 && DD[0].day===td && Number(DD[0].bytes)===52428800,'data days: today only, bad dates ignored, never lowered');
// telco texts
const tok=TOK[B6];
const sms=async (from, body, at) => (await q(`select public.kiosk_app_sms_put($1,$2,$3,$4,$5) r`,[B6,tok,from,body,at||null]))[0].r;
ok((await sms('GOMO','x')).ok && true,'text accepted with the tablet secret');
ok((await q(`select public.kiosk_app_sms_put($1,'bad','GOMO','hi',null) r`,[B6]))[0].r.error==='token','text with a wrong secret refused');
ok((await sms('+639171234567','Hi boss, utang nako')).ignored===true && (await q(`select count(*)::int n from kiosk_app_sms where body like 'Hi boss%'`))[0].n===0,'personal number text never stored');
ok((await sms('09171234567','hello')).ignored===true,'personal number (09..) never stored');
await q(`delete from kiosk_app_sms`);
let rr=await sms('GOMO','You have successfully registered to GO+99 with 25GB data valid for 30 days. Thank you!');
ok(rr.ok,'load text accepted');
ok((await sms('GOMO','You have successfully registered to GO+99 with 25GB data valid for 30 days. Thank you!')).duplicate===true,'same text again = duplicate, not a second load');
let LD=await q(`select * from kiosk_app_loads where device_id=$1`,[B6]);
ok(LD.length===1 && Number(LD[0].gb)===25 && LD[0].source==='text','load text -> load recorded by itself (25 GB)');
const exp30=(await q(`select ((now() at time zone 'Asia/Manila')::date + 30)::text d`))[0].d;
ok((await q(`select expires_on::text e from kiosk_app_loads where device_id=$1`,[B6]))[0].e===exp30,'valid for 30 days -> expiry = load day + 30');
await sms('DITO','Your 365-day promo is valid until Nov 16, 2027. You have successfully subscribed. Data: 1.5GB');
ok((await q(`select expires_on::text e, gb from kiosk_app_loads where device_id=$1 order by id desc limit 1`,[B6]))[0].e==='2027-11-16','valid until Nov 16, 2027 read');
await sms('GOMO','Your data promo will expire on 12/20/2026. Reload now to keep surfing.');
await sms('GOMO','Your GO+99 promo has expired. Reload now.');
await sms('GOMO','Your data is running low. Only 500MB left.');
ok((await sms('SHOPEE','11.11 sale! Free shipping')).ignored===true,'shop sender never stored');
ok((await sms('GCash','Your OTP is 123456')).ignored===true,'GCash / bank code never stored');
await sms('GOMO','Congrats! You received 1GB FREE data valid for 3 days.');
await sms('8080','Get 50GB! Promo valid until Nov 30, 2026. Dial *143# now.');
await sms('DITO','You received P50 load from 09171234567 via Pasaload.');
let K=(await q(`select kind from kiosk_app_sms where device_id=$1 order by id`,[B6])).map(x=>x.kind).join(',');
ok(K==='load,load,expiring,expired,low,other,other,other','texts sorted; freebie, ad and pasaload are "other" ('+K+')');
ok((await q(`select count(*)::int n from kiosk_app_loads where device_id=$1`,[B6]))[0].n===2,'freebie / pasaload never become a load');
ok((await q(`select body from kiosk_app_sms where body like '%Pasaload%'`))[0].body.includes('09*********') ,'a person\'s number inside a telco text is masked');
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`);
let SM=(await q(`select msg from sent order by id`)).map(x=>x.msg);
ok(SM.some(m=>m.includes('LOAD RECEIVED (GOMOscript text') && m.includes(': 25 GB, expires')),'Telegram: load received with GB');
ok(SM.some(m=>m.includes('(EXPIRED,')) && SM.some(m=>m.includes('(expiring,')) && SM.some(m=>m.includes('(data low,')),'Telegram: expired / expiring / low texts');
ok(!SM.some(m=>m.includes('SHOPEE') || m.includes('11.11') || m.includes('50GB') || m.includes('FREE') || m.includes('Pasaload')),'ads, freebies, pasaload never sent to Telegram');
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`);
ok(!(await q(`select msg from sent`)).some(x=>x.msg.includes(' text (')),'texts sent once');
// OTP for the telco app: on the Tablets page 15 min, never Telegram, never a load, then deleted
await sms('DITO','Your DITO OTP is 482913. Do not share this code with anyone.');
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`);
ok(!(await q(`select msg from sent`)).some(x=>x.msg.includes('482913')),'OTP never sent to Telegram');
let SI=(await q(`select public.kiosk_app_sim_info($1) r`,[B6]))[0].r;
ok(SI.otp && SI.otp.code==='482913' && !SI.texts.some(x=>x.body.includes('482913')),'OTP shown on its own on the SIM card');
await q(`update kiosk_app_sms set created_at=now()-interval '16 minutes' where body like '%482913%'`); await q(`select public.kiosk_app_tick()`);
ok((await q(`select count(*)::int n from kiosk_app_sms where body like '%482913%'`))[0].n===0 && (await q(`select public.kiosk_app_sim_info($1) r`,[B6]))[0].r.otp===null,'OTP deleted after 15 min');
// a load / expiry text ending with "never share your OTP" is NOT a code (review 2026-11-16)
await sms('DITO','You have successfully registered to Level-Up 99, 25GB valid until 11/20/2026. DITO will never ask for your OTP.');
ok((await q(`select kind from kiosk_app_sms where body like '%Level-Up 99%'`))[0].kind==='load','load text with an OTP warning stays a load');
await sms('GOMO','Your promo will expire on 12/20/2026. Never share your PIN with anyone.');
ok((await q(`select kind from kiosk_app_sms where body like '%Never share your PIN%'`))[0].kind==='expiring','expiry text with a PIN warning stays expiring');
await sms('GOMO','On 11/16/2026 your verification code is 771204. Do not share.');
SI=(await q(`select public.kiosk_app_sim_info($1) r`,[B6]))[0].r;
ok(SI.otp && SI.otp.code==='771204','the code next to "code is" is shown, not the date');
await sms('DITO','551177 is your DITO one-time PIN.');
ok((await q(`select kind from kiosk_app_sms where body like '551177%'`))[0].kind==='otp','"551177 is your ... PIN" is a code');
// a code that reached the server late (tablet was offline) still shows 15 min from when it arrived
await sms('DITO','Your OTP is 909090.', new Date(Date.now()-40*60000).toISOString());
SI=(await q(`select public.kiosk_app_sim_info($1) r`,[B6]))[0].r;
ok(SI.otp && SI.otp.code==='909090','late code still shown (15 min from server receive time)');
await q(`delete from kiosk_app_sms where kind='otp' or body like '%Level-Up 99%' or body like '%Never share your PIN%'`);
await q(`delete from kiosk_app_loads where device_id=$1 and created_at > now() - interval '1 minute' and gb=25 and expires_on='2026-11-20'`,[B6]);
// parser edge cases
const P=async (b)=>(await q(`select public.kiosk_app_parse_load($1,'2026-11-16') r`,[b]))[0].r;
ok((await P('Bad date 02/30/2027 until')).expires_on===null,'impossible date never breaks parsing');
ok((await P('Registered 500MB valid until 16 Dec 2026')).expires_on==='2026-12-16','16 Dec 2026 read');
ok(Math.abs((await P('Registered 500MB')).gb-0.49)<0.01,'MB counted as GB');
ok((await P('valid until Jan 5, 2020')).expires_on===null,'date before the load day ignored');
// owner records a load (screenshot / typed)
await q(`delete from kiosk_app_loads; delete from kiosk_app_sms`);
let R=(await q(`select public.kiosk_app_load_add('000000',$1,'{"load_date":"2026-11-16"}') r`,[B6]))[0].r; ok(R.error==='wrong passcode','record load: wrong passcode');
R=(await q(`select public.kiosk_app_load_add('123456',$1,$2) r`,[B6,JSON.stringify({load_date:'2099-01-01'})]))[0].r; ok(!!R.error,'record load: future date refused');
R=(await q(`select public.kiosk_app_load_add('123456',$1,$2) r`,[B6,JSON.stringify({load_date:td,expires_on:'2020-01-01'})]))[0].r; ok(!!R.error,'record load: expiry before load refused');
R=(await q(`select public.kiosk_app_load_add('123456',$1,$2) r`,[B6,JSON.stringify({load_date:td,gb:'abc'})]))[0].r; ok(!!R.error,'record load: bad GB refused');
R=(await q(`select public.kiosk_app_load_add('123456',$1,$2) r`,[B6,JSON.stringify({load_date:td,shot:'<img>'})]))[0].r; ok(!!R.error,'record load: non-JPEG screenshot refused');
R=(await q(`select public.kiosk_app_load_add('123456',$1,$2) r`,[B6,JSON.stringify({provider:'GOMO',promo:'GO+99 <b>',gb:'25',load_date:td,expires_on:exp30,source:'screenshot',shot:'/9j/AAAA'})]))[0].r;
ok(R.ok===true,'record load from screenshot saved');
LB=(await q(`select public.kiosk_app_list('123456') r`))[0].r.find(x=>x.device_id===B6);
ok(LB.sim.load && LB.sim.load.promo==='GO+99 b' && LB.sim.load.has_shot===true && LB.sim.load.days_left===30 && LB.sim.load.used_mb===50,'SIM card: load, proof, days left, data used since load');
ok((await q(`select public.kiosk_app_load_shot_get('123456',$1) r`,[B6]))[0].r.jpeg==='/9j/AAAA','proof screenshot readable with passcode');
ok((await q(`select public.kiosk_app_load_shot_get('1',$1) r`,[B6]))[0].r.error==='wrong passcode','proof needs passcode');
// SIM provider + closing rule
R=(await q(`select public.kiosk_app_sim_set('123456',$1,'gomo',null) r`,[B6]))[0].r;
ok(R.ok && (await q(`select sim_provider, sim_close_days from kiosk_app_devices where device_id=$1`,[B6]))[0].sim_close_days===365,'GOMO: closes after 365 days by default');
ok((await q(`select public.kiosk_app_sim_set('123456',$1,'DITO',5) r`,[B6]))[0].r.error,'closing days under 30 refused');
const mh=(await q(`select extract(hour from now() at time zone 'Asia/Manila')::int h`))[0].h;
if (mh>=8 && mh<20) {
  // expiry reminders: 3 days before -> one message; nothing again; expired -> one message
  await q(`update kiosk_app_loads set expires_on=(now() at time zone 'Asia/Manila')::date+3 where device_id=$1`,[B6]);
  await q(`delete from sent`); await q(`select public.kiosk_app_tick()`); await q(`select public.kiosk_app_tick()`);
  SM=(await q(`select msg from sent`)).map(x=>x.msg);
  ok(SM.filter(m=>m.includes('load expires in 3 days')).length===1,'expiry: 3 days before, once');
  await q(`update kiosk_app_loads set expires_on=(now() at time zone 'Asia/Manila')::date where device_id=$1`,[B6]);
  await q(`delete from sent`); await q(`select public.kiosk_app_tick()`); await q(`select public.kiosk_app_tick()`);
  ok((await q(`select msg from sent`)).filter(x=>x.msg.includes('load EXPIRED today')).length===1,'expired today: once');
  // long load: 30-day reminder, not the 7-day one at the same time (fresh reminders, as for a new load)
  await q(`update kiosk_app_devices set sim_alerts='{}' where device_id=$1`,[B6]);
  await q(`update kiosk_app_loads set load_date=(now() at time zone 'Asia/Manila')::date-300, expires_on=(now() at time zone 'Asia/Manila')::date+25 where device_id=$1`,[B6]);
  await q(`delete from sent`); await q(`select public.kiosk_app_tick()`);
  SM=(await q(`select msg from sent`)).map(x=>x.msg);
  ok(SM.filter(m=>m.includes('load expires in 25 days')).length===1,'365-day load: 30-day reminder');
  // number closing: GOMO 365 days since the last load -> 30 then 7 days before
  ok(!SM.some(m=>m.includes('number closes')),'closing not yet (65 days left)');
  await q(`update kiosk_app_loads set load_date=(now() at time zone 'Asia/Manila')::date-340 where device_id=$1`,[B6]);
  await q(`delete from sent`); await q(`select public.kiosk_app_tick()`); await q(`select public.kiosk_app_tick()`);
  ok((await q(`select msg from sent`)).filter(x=>x.msg.includes('number closes in 25 days')).length===1,'number closing: 30-day warning once');
  await q(`update kiosk_app_loads set load_date=(now() at time zone 'Asia/Manila')::date-360 where device_id=$1`,[B6]);
  await q(`delete from sent`); await q(`select public.kiosk_app_tick()`); await q(`select public.kiosk_app_tick()`);
  ok((await q(`select msg from sent`)).filter(x=>x.msg.includes('NUMBER WILL CLOSE in 5 days')).length===1,'number closing: 7-day warning once');
  // 80% data used
  await q(`update kiosk_app_loads set gb=0.05 where device_id=$1`,[B6]);
  await q(`delete from sent`); await q(`select public.kiosk_app_tick()`); await q(`select public.kiosk_app_tick()`);
  ok((await q(`select msg from sent`)).filter(x=>x.msg.includes('(80%+)')).length===1,'80% of the data used: once');
  // a NEW load starts fresh reminders
  await q(`select public.kiosk_app_load_add('123456',$1,$2)`,[B6,JSON.stringify({load_date:td,expires_on:(await q(`select ((now() at time zone 'Asia/Manila')::date+2)::text d`))[0].d,source:'typed'})]);
  await q(`delete from sent`); await q(`select public.kiosk_app_tick()`);
  ok((await q(`select msg from sent`)).filter(x=>x.msg.includes('load expires in 2 days')).length===1,'new load: its own reminders');
  const maxId=(await q(`select max(id)::text m from kiosk_app_loads`))[0].m;
  ok(Object.keys((await q(`select sim_alerts from kiosk_app_devices where device_id=$1`,[B6]))[0].sim_alerts).every(k=>k.endsWith(':'+maxId)),'old load reminders cleaned out');
  // no load recorded at all -> one reminder this month
  await q(`delete from kiosk_app_loads where device_id=$1`,[B6]); await q(`update kiosk_app_devices set sim_alerts='{}' where device_id=$1`,[B6]);
  await q(`delete from sent`); await q(`select public.kiosk_app_tick()`); await q(`select public.kiosk_app_tick()`);
  ok((await q(`select msg from sent`)).filter(x=>x.msg.includes('no load recorded yet for its GOMO SIM')).length===1,'no load recorded: one reminder a month');
} else { console.log('SKIP SIM reminder tests (run between 8 AM and 8 PM Manila)'); }
// "I just loaded": no text in 30 min -> ask for the screenshot, once; a text in time -> nothing
await q(`delete from kiosk_app_loads where device_id=$1`,[B6]);
await q(`select public.kiosk_app_load_wait('123456',$1)`,[B6]);
await q(`update kiosk_app_devices set load_wait_from=now()-interval '31 minutes' where device_id=$1`,[B6]);
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`); await q(`select public.kiosk_app_tick()`);
ok((await q(`select msg from sent`)).filter(x=>x.msg.includes('no GOMO text reached the tablet in 30 min')).length===1,'no load text after "I just loaded": asks for the screenshot once');
await q(`select public.kiosk_app_load_wait('123456',$1)`,[B6]);
await sms('GOMO','You have successfully registered to GO+50 with 10GB valid for 7 days.');
await q(`update kiosk_app_devices set load_wait_from=now()-interval '31 minutes' where device_id=$1`,[B6]);
await q(`update kiosk_app_loads set created_at=now() where device_id=$1`,[B6]);
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`);
ok(!(await q(`select msg from sent`)).some(x=>x.msg.includes('no GOMO text reached')),'load text came in time: no screenshot request');
// mobile data not working 30 min -> one alert; works again with no load -> asks for the screenshot
await q(`delete from kiosk_app_loads where device_id=$1`,[B6]);
await beat({device_id:B6,battery:90,charging:true,page_url:MAN,net_type:'wifi',mobile_ok:false,sim_state:'ready'});
await q(`update kiosk_app_devices set mobile_bad_since=now()-interval '40 minutes' where device_id=$1`,[B6]);
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`); await q(`select public.kiosk_app_tick()`);
ok((await q(`select msg from sent`)).filter(x=>x.msg.includes('mobile data is NOT working')).length===1,'mobile data not working 30 min: one alert');
await beat({device_id:B6,battery:90,charging:true,page_url:MAN,net_type:'wifi',mobile_ok:true});
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`); await q(`select public.kiosk_app_tick()`);
ok((await q(`select msg from sent`)).filter(x=>x.msg.includes('mobile data works again') && x.msg.includes('send the screenshot')).length===1,'works again without a load text: asks for the screenshot');
// set Wi-Fi: validated, password never logged, removed on ack
R=(await q(`select public.kiosk_app_command('123456',$1,'set_wifi',$2) r`,[B6,JSON.stringify({ssid:'RSR "x"',pass:'12345678'})]))[0].r; ok(!!R.error,'Wi-Fi name with quotes refused');
R=(await q(`select public.kiosk_app_command('123456',$1,'set_wifi',$2) r`,[B6,JSON.stringify({ssid:'RSR Mandaue',pass:'short'})]))[0].r; ok(!!R.error,'Wi-Fi password under 8 refused');
R=(await q(`select public.kiosk_app_command('123456',$1,'set_wifi','not json') r`,[B6]))[0].r; ok(!!R.error,'unreadable Wi-Fi details refused');
R=(await q(`select public.kiosk_app_command('123456',$1,'set_wifi',$2) r`,[B6,JSON.stringify({ssid:'RSR Mandaue',pass:'s3cretPass!'})]))[0].r; ok(R.ok,'Set Wi-Fi queued');
ok(!(await q(`select event from kiosk_app_events where device_id=$1`,[B6])).some(x=>x.event.includes('s3cretPass')),'password never in the event log');
ok(!JSON.stringify((await q(`select public.kiosk_app_list('123456') r`))[0].r).includes('s3cretPass'),'password never in the Tablets page list');
rr=await beat({device_id:B6,battery:90,charging:true,page_url:MAN});
ok(rr.cmd==='set_wifi' && JSON.parse(rr.arg).pass==='s3cretPass!' && JSON.parse(rr.arg).switch===true,'tablet receives the Wi-Fi details');
await q(`select public.kiosk_app_ack($1,$2,$3,'done: added RSR Mandaue')`,[B6,TOK[B6],rr.cmd_id]);
ok((await q(`select cmd_arg from kiosk_app_devices where device_id=$1`,[B6]))[0].cmd_arg===null,'password removed from the server after the tablet confirms');
await q(`select public.kiosk_app_command('123456',$1,'set_wifi',$2)`,[B6,JSON.stringify({ssid:'RSR Mandaue',pass:'s3cretPass!'})]);
await q(`update kiosk_app_devices set cmd_at=now()-interval '31 minutes' where device_id=$1`,[B6]); await q(`select public.kiosk_app_tick()`);
ok((await q(`select cmd_arg from kiosk_app_devices where device_id=$1`,[B6]))[0].cmd_arg===null,'unclaimed Wi-Fi password removed after 30 min');
R=(await q(`select public.kiosk_app_command('123456',$1,'retry_punches','') r`,[B6]))[0].r; ok(R.ok,'Retry stuck punches command accepted');
await beat({device_id:B6,battery:90,charging:true,page_url:MAN,event:'screen on failed'});
ok((await q(`select count(*)::int n from kiosk_app_events where device_id=$1 and event='screen on failed'`,[B6]))[0].n===1,'"screen on failed" event logged');
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`);
ok((await q(`select msg from sent`)).some(x=>x.msg.includes('screen did NOT turn on by itself')),'"screen on failed" goes to Telegram');
await beat({device_id:B6,battery:90,charging:true,page_url:MAN,event:'screen woken by phone call'});
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`);
ok((await q(`select msg from sent`)).filter(x=>x.msg.includes('screen woken by your phone call')).length===1,'call wake confirmed on Telegram once');
await q(`update kiosk_app_events set at=now()-interval '20 seconds' where device_id=$1 and event='screen woken by phone call'`,[B6]);
await beat({device_id:B6,battery:90,charging:true,page_url:MAN,event:'screen woken by phone call'});
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`);
ok((await q(`select msg from sent`)).filter(x=>x.msg.includes('phone call')).length===1,'second call: its own Telegram (every call)');
// downtime: an outage reported for time already on mobile data is counted once
await q(`delete from kiosk_app_conn where device_id=$1`,[B6]);
await q(`insert into kiosk_app_conn(device_id,kind,started_at,ended_at) values ($1,'mobile',now()-interval '3 hours',now()-interval '10 minutes'),($1,'offline',now()-interval '2 hours 10 minutes',now()-interval '10 minutes')`,[B6]);
ok((await q(`select public.kiosk_app_down_min($1, now()-interval '1 day') m`,[B6]))[0].m===170,'overlapping periods counted once (170 min)');
// an open mobile period of a silent tablet stops counting 2 min after its last report
await q(`delete from kiosk_app_conn where device_id=$1`,[B6]);
await q(`insert into kiosk_app_conn(device_id,kind,started_at) values ($1,'mobile',now()-interval '5 hours')`,[B6]);
await q(`update kiosk_app_devices set last_seen=now()-interval '4 hours' where device_id=$1`,[B6]);
ok((await q(`select public.kiosk_app_down_min($1, now()-interval '1 day') m`,[B6]))[0].m===62,'silent tablet: open period stops at last report + 2 min');
await q(`delete from kiosk_app_conn where device_id=$1`,[B6]); await q(`update kiosk_app_devices set last_seen=now() where device_id=$1`,[B6]);
// BROWNOUT (grid tablet): charger and Wi-Fi lost together -> brownout wording; offline after that -> brownout reason
await q(`update kiosk_app_devices set power_windows=null, unplugged_alerted=false, unplugged_alerted_at=null, offline_alerted_at=null, offline_first_at=null where device_id=$1`,[B6]);
await beat({device_id:B6,battery:80,charging:false,page_url:MAN,net_type:'mobile',wifi:false});
await q(`update kiosk_app_devices set unplugged_since=now()-interval '6 minutes' where device_id=$1`,[B6]);
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`);
const mh2=(await q(`select extract(hour from now() at time zone 'Asia/Manila')::int h`))[0].h;
ok((await q(`select msg from sent`)).some(x=>x.msg.includes('POSSIBLE BROWNOUT') && x.msg.includes('reporting on mobile data') && x.msg.includes('Battery 80%')),'brownout: charger + Wi-Fi lost together');
await q(`update kiosk_app_devices set unplugged_alerted_at=now()-interval '35 minutes' where device_id=$1`,[B6]);
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`);
ok(!(await q(`select msg from sent`)).some(x=>x.msg.includes('BROWNOUT')),'brownout update not after 35 min');
await q(`update kiosk_app_devices set unplugged_alerted_at=now()-interval '61 minutes' where device_id=$1`,[B6]);
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`);
ok((await q(`select msg from sent`)).filter(x=>x.msg.includes('BROWNOUT') && x.msg.includes('Updates every hour')).length===1,'brownout update every hour');
await q(`update kiosk_app_devices set last_seen=now()-interval '15 minutes', sched_on=null, sched_off=null where device_id=$1`,[B6]);
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`);
if (mh2>=6 && mh2<22) ok((await q(`select msg from sent`)).some(x=>x.msg.includes('is OFFLINE') && x.msg.includes('possible BROWNOUT')),'offline after unplugged: brownout reason');
await beat({device_id:B6,battery:79,charging:true,page_url:MAN,net_type:'wifi',wifi:true});
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`);
ok((await q(`select msg from sent`)).some(x=>x.msg.includes('Mandaue Kiosk is charging again')),'power back: charging again message');
await q(`update kiosk_app_devices set offline_first_at=null, offline_alerted_at=null where device_id=$1`,[B6]);
// a Wi-Fi password is only handed to a tablet that confirmed its secret
await q(`select public.kiosk_app_command('123456',$1,'set_wifi',$2)`,[B6,JSON.stringify({ssid:'X1',pass:'abcdefgh'})]);
await q(`update kiosk_app_devices set token_confirmed=false where device_id=$1`,[B6]);
ok(JSON.stringify(await beat({device_id:B6,battery:90,charging:true,page_url:MAN,token:''})).indexOf('abcdefgh')<0,'unconfirmed tablet never receives a Wi-Fi password');
await q(`update kiosk_app_devices set token_confirmed=true, cmd=null, cmd_arg=null where device_id=$1`,[B6]);
// forget removes build-6 rows too? (kept: loads are history) - tick cleanup keeps loads
await q(`delete from sent`);
}

// anon cannot read tables
// the owner's go-live check (supabase/paste/build6-3-public-check.sql): every table "public can read = false"
{ const chk=(await c.query(PUBLIC_CHECK)).rows; ok(chk.length===8 && chk.every(r=>r.public_can_read===false && r.signed_in_can_read===false),'go-live check: public / signed-in can read = false on all 8 tables'); }
await c.query(`grant usage on schema public to anon`);
await c.query(`set role anon`); let denied=false; try{ await c.query(`select * from kiosk_app_devices`);}catch(e){denied=true;}
ok(denied,'anon cannot read table directly'); let tickDenied=false; try{ await c.query(`select public.kiosk_app_tick()`);}catch(e){tickDenied=true;} ok(tickDenied,'anon cannot run tick');
let stOk=true; try{ await c.query(`select public.kiosk_app_status()`);}catch(e){stOk=false;} ok(stOk,'anon can read status');
let shotDenied=false; try{ await c.query(`select * from kiosk_app_shots`);}catch(e){shotDenied=true;} ok(shotDenied,'anon cannot read screenshots directly');
let beatOk=true; try{ await c.query(`select public.kiosk_app_beat('{"device_id":"app-t1"}')`);}catch(e){beatOk=false; console.log(e.message)} ok(beatOk,'anon can beat');
// build-6 data exposure: the public key reads none of the new tables or helper functions
for (const t of ['kiosk_app_conn','kiosk_app_data_days','kiosk_app_sms','kiosk_app_loads','kiosk_app_load_shots']) {
  let d=false; try{ await c.query(`select * from ${t}`);}catch(e){d=true;} ok(d,'public key cannot read '+t);
}
for (const f of [`kiosk_app_sim_info('x')`,`kiosk_app_down_min('x', now())`,`kiosk_app_sms_kind('x')`,`kiosk_app_parse_load('x', current_date)`]) {
  let d=false; try{ await c.query(`select public.${f}`);}catch(e){d=true;} ok(d,'public key cannot run '+f.split('(')[0]);
}
{ const r=(await c.query(`select public.kiosk_app_load_shot_get('000000','x') r`)).rows[0].r; ok(r.error==='wrong passcode','public key + wrong passcode: no load screenshot'); }
await c.query(`reset role`);
// rollback
await c.query(fs.readFileSync('./kiosk-app-rollback.sql','utf8'));
ok((await q(`select to_regclass('public.kiosk_app_shots') t`))[0].t===null,'rollback removes screenshots');
ok((await q(`select to_regclass('public.kiosk_app_devices') t`))[0].t===null && (await q(`select count(*)::int n from cron.job`))[0].n===0,'rollback clean');
await c.end(); await db.stop();
console.log(fails? `${fails} FAILED` : 'ALL PASS'); process.exit(fails?1:0);
