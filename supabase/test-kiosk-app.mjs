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
// unplugged 10+ min (work hours dependent) - force time window by checking logic
await q(`update kiosk_app_devices set unplugged_since=now()-interval '15 minutes'`);
await q(`select public.kiosk_app_tick()`);
const hr = (await q(`select extract(hour from now() at time zone 'Asia/Manila')::int h`))[0].h;
const unp=(await q(`select count(*)::int n from sent where msg like '%UNPLUGGED%'`))[0].n;
ok((hr>=6&&hr<22)? unp===1 : unp===0, 'unplugged alert respects 6AM-10PM (hour '+hr+')');
await beat({device_id:'app-abc123',charging:true,battery:16});
await q(`select public.kiosk_app_tick()`);
ok((await q(`select unplugged_since is null and not low_batt_alerted ok from kiosk_app_devices`))[0].ok,'charging resets flags');
if ((hr>=6&&hr<22)) ok((await q(`select count(*)::int n from sent where msg like '%charger is back%'`))[0].n===1,'charger back notice');
// silent tablet skipped
await q(`update kiosk_app_devices set last_seen=now()-interval '20 minutes', charging=false, battery=5, low_batt_alerted=false`);
await q(`delete from sent`); await q(`select public.kiosk_app_tick()`); ok((await q(`select count(*)::int n from sent`))[0].n===0,'silent tablet skipped');
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
await q(`select public.kiosk_app_tick()`); ok((await q(`select count(*)::int n from sent`))[0].n===5,'max 5 Telegram event messages per tick');
// schedule text validated
await beat({device_id:'app-abc123',sched_on:"0');x",sched_off:'22:30'});
ok((await q(`select sched_on is null and sched_off='22:30' ok from kiosk_app_devices where device_id='app-abc123'`))[0].ok,'bad schedule text not stored');
// 7-day cleanup
await q(`update kiosk_app_devices set last_seen=now()-interval '8 days' where device_id='app-t3'`);
await q(`select public.kiosk_app_tick()`); ok((await q(`select count(*)::int n from kiosk_app_devices where device_id='app-t3'`))[0].n===0,'stale tablet removed after 7 days');
// anon cannot read tables
await c.query(`grant usage on schema public to anon`);
await c.query(`set role anon`); let denied=false; try{ await c.query(`select * from kiosk_app_devices`);}catch(e){denied=true;}
ok(denied,'anon cannot read table directly'); let tickDenied=false; try{ await c.query(`select public.kiosk_app_tick()`);}catch(e){tickDenied=true;} ok(tickDenied,'anon cannot run tick');
let beatOk=true; try{ await c.query(`select public.kiosk_app_beat('{"device_id":"app-t1"}')`);}catch(e){beatOk=false; console.log(e.message)} ok(beatOk,'anon can beat');
await c.query(`reset role`);
// rollback
await c.query(fs.readFileSync('./kiosk-app-rollback.sql','utf8'));
ok((await q(`select to_regclass('public.kiosk_app_devices') t`))[0].t===null && (await q(`select count(*)::int n from cron.job`))[0].n===0,'rollback clean');
await c.end(); await db.stop();
console.log(fails? `${fails} FAILED` : 'ALL PASS'); process.exit(fails?1:0);
