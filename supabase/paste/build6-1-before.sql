select current_database() as db,
       (select count(*) from public.attendance_records) as canary,
       (select count(*) from pg_trigger where tgrelid = to_regclass('public.kiosk_app_devices') and not tgisinternal) as triggers_on_tablets;
