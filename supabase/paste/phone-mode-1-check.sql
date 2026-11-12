-- RSR Kiosk app - ROLL-CALL PHONE MODE - PART 1 of 2: CHECK ONLY (changes nothing). 2026-11-12
-- Paste ALL of this in the Supabase SQL editor and press Run. Send the one result row.
-- all three *_ok must be true: the live functions are the version the phone mode was built on.
select current_database() as db,
  (select replace_ok from (select md5(replace(prosrc, chr(13), '')) in ('733ca850da3aac456ff98d90537990e8','d6fc292bd582f50cd041dd7c1d29be04') as replace_ok
     from pg_proc where proname = 'kiosk_app_list') x) as list_ok,
  (select md5(replace(prosrc, chr(13), '')) = '3c5c88cabf790fea72884e67f7d92af3' from pg_proc where proname = 'kiosk_app_status') as status_ok,
  (select md5(replace(prosrc, chr(13), '')) in ('0fdbb595dbaf666e993be983ab012d90','79226da5271a7cfdf8d6635d5f62ce70') from pg_proc where proname = 'kiosk_app_tick') as tick_ok,
  (select count(*) from public.kiosk_app_devices) as devices;
