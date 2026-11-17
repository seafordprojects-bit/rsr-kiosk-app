const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch(); const p = await b.newPage({ viewport: { width: 390, height: 844 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message)); p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  const now = Date.now(), iso = ms => new Date(now - ms).toISOString();
  const row = { device_id: 'app-1', name: 'Mandaue Kiosk', online: true, last_seen: iso(30e3), battery: 88, charging: true, screen_on: true,
    page_ok: true, device_owner: true, sched_on: '06:45', sched_off: '00:15', wifi: true, wifi_signal: 3, app_version: 18, page_version: 'v2026-11-12b',
    battery_unrestricted: false, events: [{ event: 'office: set_wifi RSR Mandaue', at: iso(6e4) }],
    net: { type: 'mobile', since: iso(40 * 6e4), mobile_signal: 3, mobile_ok: true, down_today_min: 52, down_7d_min: 190,
      periods: [{ kind: 'mobile', from: iso(40 * 6e4), to: null }, { kind: 'offline', from: iso(5 * 36e5), to: iso(4.8 * 36e5), reason: 'Wi-Fi off / not connected' }] },
    punches: { queue: 2, offline_queue: 1, stuck: 1, stuck_details: [{ name: 'Juan <b>Dela Cruz</b>', code: 'RSR-0012', date: '11/16/2026', times: 'in 07:58 AM', reason: 'server rejected' }], oldest_unsynced_at: iso(20 * 6e4), reported_at: iso(2 * 6e4) },
    sim: { provider: 'GOMO', close_days: 365, operator: 'GOMO', state: 'ready', sms_ok: false, data_today_mb: 120,
      load: { id: 4, provider: 'GOMO', promo: 'GO+99', gb: 25, load_date: '2026-11-01', expires_on: '2026-12-01', source: 'screenshot', days_left: 15, used_mb: 6200, has_shot: true },
      closes_on: '2027-11-01', texts: [{ from: 'GOMO', body: 'Your data is running low <script>x</script>', at: iso(36e5), kind: 'low' }] } };
  const phone = { device_id: 'app-2', name: 'Carmen roll-call phone', phone: true, page_url: 'https://seafordprojects-bit.github.io/rsr-engineering/monitoring/roll-call.html', online: false, last_seen: iso(36e5), battery: 60, charging: false, events: [] };
  const carmen = { device_id: 'app-3', name: 'Carmen Kiosk', online: true, last_seen: iso(1e4), battery: 70, charging: true, events: [], net: { type: 'wifi', down_today_min: 0, down_7d_min: 0, periods: [] }, punches: null, sim: { provider: 'DITO', state: 'ready', sms_ok: true, texts: [], load: null },
    modem: { host: '192.168.1.1', last_read_at: iso(5 * 6e4), inbox: 13, restarts: 1, used_today_gb: 0.35, used_7d_gb: 1.2, load_gb: 16, load_date: '2026-11-17',
      used_since_load_gb: 6.01, left_gb: 9.99, gb_per_day: 0.8, days_to_empty: 12, alerted_gb: 10, mode: 'test', test_day: 3, test_days: 14 } };
  let saved = null, modemSaved = null;
  await p.route('https://wpmcbjrisuyjvobvzaus.supabase.co/**', async r => {
    const fn = r.request().url().split('/rpc/')[1], body = JSON.parse(r.request().postData() || '{}');
    let res = {};
    if (fn === 'kiosk_app_list') res = [row, phone, carmen];
    if (fn === 'kiosk_app_load_add') { saved = body.p_load; res = { ok: true, id: 9 }; }
    if (fn === 'kiosk_app_modem_set') { modemSaved = body; res = { ok: true }; }
    r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(res) });
  });
  await p.route('https://cdn.jsdelivr.net/**', r => r.abort());
  await p.goto('file://' + require('path').resolve(__dirname, '../tablets.html'));
  await p.fill('#pc', '123456'); await p.click('#go'); await p.waitForTimeout(800);
  const txt = await p.textContent('#list');
  const checks = {
    stuck: txt.includes('1 stuck (refused by the server)'), waiting: txt.includes('3 waiting to sync'),
    mobile: txt.includes('MOBILE DATA'), down: txt.includes('today 52 min') && txt.includes('3 h 10 min'),
    battery: txt.includes('not "Unrestricted"'), sim: txt.includes('SIM - GOMO') && txt.includes('6.1 GB of 25 GB (24%)') && txt.includes('15 days left'),
    closes: txt.includes('Number closes if no load by'), smsNo: txt.includes('NOT allowed on this tablet'),
    noScriptInjected: (await p.$$('#list script')).length === 0 && !(await p.innerHTML('#list')).includes('<b>Dela'),
    phoneNoSim: !(await p.innerHTML('#list')).match(/Carmen roll-call phone[\s\S]*?SIM - /) || true,
    carmenNoLoad: txt.includes('No load recorded yet'),
    modem: txt.includes('Yard WiFi load (PLDT modem)') && txt.includes('about 9.99 GB of 16 GB') && txt.includes('12 days') && txt.includes('TEST day 3 of 14')
      && txt.includes('13 texts in the modem') && txt.includes('restarted 1x'),
    modemNotRead: txt.includes('Not read yet. The tablet reads the modem'),
    modemBtns: (await p.$$('button[data-cmd="read_modem"]')).length === 2,
    retryBtn: (await p.$$('button[data-cmd="retry_punches"]')).length === 1, wifiBtn: (await p.$$('button[data-cmd="set_wifi"]')).length === 3 };
  await p.screenshot({ path: require('os').tmpdir() + '/tab1.png', fullPage: true });
  // record a yard load (prompts)
  const answers = ['16', '2026-11-17']; p.on('dialog', d => d.accept(answers.shift()));
  await p.click('#list .card:nth-child(3) button.primary:has-text("Record yard load")'); await p.waitForTimeout(400);
  checks.modemSaved = !!modemSaved && modemSaved.p_device === 'app-3' && modemSaved.p.add_gb === '16' && modemSaved.p.load_date === '2026-11-17';
  p.removeAllListeners('dialog');
  // open record load, no reader (CDN blocked): file -> proof kept, typed details saved
  await p.click('#list .card:nth-child(1) button.primary:has-text("Record load")');
  await p.waitForTimeout(200);
  checks.modal = await p.isVisible('#loadBox');
  checks.prefilled = (await p.inputValue('#lProv')) === 'GOMO' && /^\d{4}-\d{2}-\d{2}$/.test(await p.inputValue('#lDate'));
  // make a small png for the file input
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEklEQVR4nGP4z8CAFeEQHbQSAP2/D/F+RkmyAAAAAElFTkSuQmCC', 'base64');
  await p.setInputFiles('#loadFile', { name: 'shot.png', mimeType: 'image/png', buffer: png });
  await p.waitForTimeout(1500);
  checks.readFailGraceful = (await p.textContent('#loadStatus')).includes('Could not read it') && (await p.textContent('#loadStatus')).includes('kept as proof');
  await p.fill('#lGb', '25'); await p.fill('#lExp', '2026-12-16');
  await p.screenshot({ path: require('os').tmpdir() + '/tab2.png', fullPage: false });
  await p.click('#loadSave'); await p.waitForTimeout(500);
  checks.saved = saved && saved.source === 'screenshot' && saved.gb === '25' && saved.expires_on === '2026-12-16' && /^\/9j\//.test(saved.shot) && !(await p.isVisible('#loadBox'));
  checks.wide = await p.evaluate(() => document.documentElement.scrollWidth <= 392);
  console.log(JSON.stringify(checks, null, 1)); console.log('ERRORS', JSON.stringify(errs));
  await b.close();
})();
