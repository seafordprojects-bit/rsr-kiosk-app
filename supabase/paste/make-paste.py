# Regenerates kiosk-app-paste.sql from ../kiosk-app.sql: every "-- comment" removed, so a phone paste that joins
# lines can never comment out code (2026-11-04: a phone paste failed with "syntax error at or near if").
# Run from the repo root: python supabase/paste/make-paste.py   (kiosk-app.sql never has "--" inside a string)
src = open('supabase/kiosk-app.sql', encoding='ascii').read()
out = [l.split('--', 1)[0].rstrip() for l in src.split('\n')]
open('supabase/paste/kiosk-app-paste.sql', 'w', encoding='ascii', newline='\n').write('\n'.join(l for l in out if l.strip()) + '\n')
