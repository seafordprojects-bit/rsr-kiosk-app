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
// anon cannot read tables
await c.query(`grant usage on schema public to anon`);
await c.query(`set role anon`); let denied=false; try{ await c.query(`select * from kiosk_app_devices`);}catch(e){denied=true;}
ok(denied,'anon cannot read table directly'); let tickDenied=false; try{ await c.query(`select public.kiosk_app_tick()`);}catch(e){tickDenied=true;} ok(tickDenied,'anon cannot run tick');
let stOk=true; try{ await c.query(`select public.kiosk_app_status()`);}catch(e){stOk=false;} ok(stOk,'anon can read status');
let beatOk=true; try{ await c.query(`select public.kiosk_app_beat('{"device_id":"app-t1"}')`);}catch(e){beatOk=false; console.log(e.message)} ok(beatOk,'anon can beat');
await c.query(`reset role`);
// rollback
await c.query(fs.readFileSync('./kiosk-app-rollback.sql','utf8'));
ok((await q(`select to_regclass('public.kiosk_app_devices') t`))[0].t===null && (await q(`select count(*)::int n from cron.job`))[0].n===0,'rollback clean');
await c.end(); await db.stop();
console.log(fails? `${fails} FAILED` : 'ALL PASS'); process.exit(fails?1:0);
