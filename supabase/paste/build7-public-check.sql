select t as table_name,
       has_table_privilege('anon', 'public.' || t, 'select') as public_can_read,
       has_table_privilege('authenticated', 'public.' || t, 'select') as signed_in_can_read
  from unnest(array['kiosk_app_devices','kiosk_app_events','kiosk_app_shots','kiosk_app_conn','kiosk_app_data_days',
                    'kiosk_app_sms','kiosk_app_loads','kiosk_app_load_shots','kiosk_app_modem','kiosk_app_modem_reads','kiosk_app_power_log']) t;
