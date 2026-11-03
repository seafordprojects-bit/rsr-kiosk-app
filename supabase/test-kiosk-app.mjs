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
const beat = async p => (await q(`select public.kiosk_app_beat($1::jsonb) r`,[JSON.stringify(p)]))[0].r;
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
await q(`select public.kiosk_app_ack('app-abc123',$1,'restarting')`,[r.cmd_id]);
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
for (let i=0;i<30;i++) await beat({device_id:'app-abc123',charging:true,battery:80,event:'x'+i});
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
ok(Array.isArray(ST) && ST.length>0 && 'battery' in ST[0] && 'charging' in ST[0] && !('cmd' in ST[0]) && !('page_url' in ST[0]),'status RPC: battery/charging only');
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
