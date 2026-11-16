// load-reader.js - Tablets page "Record load > Upload screenshot" (build-6, owner 2026-11-16).
// The screenshot of the DITO / GOMO app is turned into text on the owner's phone (Tesseract.js, see tablets.html);
// this file picks the load details out of that text. Nothing is saved from here: the owner checks the boxes and taps
// Save. Same idea as kiosk_app_parse_load on the server (telco texts). Plain script, tested by test/load-reader.test.mjs.
(function (g) {
  'use strict';
  const MON = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
  const pad = n => String(n).padStart(2, '0');
  const iso = (y, m, d) => {
    const t = new Date(Date.UTC(y, m - 1, d));
    if (t.getUTCFullYear() !== y || t.getUTCMonth() !== m - 1 || t.getUTCDate() !== d) return '';   // Feb 30 etc.
    return y + '-' + pad(m) + '-' + pad(d);
  };
  const addDays = (isoDay, n) => {
    const t = new Date(isoDay + 'T00:00:00Z'); t.setUTCDate(t.getUTCDate() + n);
    return t.getUTCFullYear() + '-' + pad(t.getUTCMonth() + 1) + '-' + pad(t.getUTCDate());
  };
  const dayDiff = (a, b) => Math.round((new Date(a + 'T00:00:00Z') - new Date(b + 'T00:00:00Z')) / 86400000);

  // first date in s: 2026-12-16 / Dec 16, 2026 / 16 Dec 2026 / 12/16/2026 (PH: month first)
  function firstDate(s) {
    if (!s) return '';
    let m = s.match(/(20\d{2})-(\d{1,2})-(\d{1,2})/);
    if (m) return iso(+m[1], +m[2], +m[3]);
    const l = s.toLowerCase();
    m = l.match(/\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(20\d{2})/);
    if (m) return iso(+m[3], MON.indexOf(m[1]) + 1, +m[2]);
    m = l.match(/\b(\d{1,2})(?:st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?\s+(20\d{2})/);
    if (m) return iso(+m[3], MON.indexOf(m[2]) + 1, +m[1]);
    m = s.match(/\b(\d{1,2})\/(\d{1,2})\/(20\d{2})/);
    if (m) return iso(+m[3], +m[1], +m[2]);
    return '';
  }
  function dateAfter(text, re) {
    const m = text.match(re);
    return m ? firstDate(text.slice(m.index + m[0].length, m.index + m[0].length + 60)) : '';
  }

  // text: what the screenshot reader found; today: 'YYYY-MM-DD' (Manila); provider: the tablet's SIM provider
  function parse(text, today, provider) {
    const t = String(text || '');
    const out = { provider: '', promo: '', gb: null, load_date: today, expires_on: '' };
    const low = t.toLowerCase();
    out.provider = /\bdito\b/.test(low) ? 'DITO' : /\bgomo\b/.test(low) ? 'GOMO' : /\bglobe\b/.test(low) ? 'GLOBE'
      : /\bsmart\b/.test(low) ? 'SMART' : /\btnt\b/.test(low) ? 'TNT' : String(provider || '').toUpperCase();
    // GB: the biggest single amount (a "25GB + 5GB bonus" line counts 25); MB only when no GB is shown
    let gb = null;
    for (const m of t.matchAll(/(\d+(?:\.\d+)?)\s*GB\b/gi)) gb = Math.max(gb || 0, parseFloat(m[1]));
    if (gb == null) for (const m of t.matchAll(/(\d+(?:\.\d+)?)\s*MB\b/gi)) gb = Math.max(gb || 0, parseFloat(m[1]) / 1024);
    out.gb = gb == null || !(gb > 0) ? null : Math.round(gb * 100) / 100;
    // load day: after "purchased / loaded / registered / transaction date"; never in the future, at most 400 days back
    const ld = dateAfter(t, /(purchased|bought|loaded|registered|subscribed|transaction date|date of purchase)\s*(on|date)?\s*:?/i);
    if (ld && dayDiff(ld, today) <= 0 && dayDiff(today, ld) <= 400) out.load_date = ld;
    // expiry: after "valid until / expires on / expiry"; or load day + "N days"
    let ex = dateAfter(t, /(valid\s+until|valid\s+till|valid\s+thru|valid\s+through|expires?\s+on|expiring\s+on|expiration(\s+date)?|expiry(\s+date)?|expires|until|till)\s*:?/i);
    if (ex && (dayDiff(ex, out.load_date) < 0 || dayDiff(ex, out.load_date) > 800)) ex = '';
    if (!ex) {
      const d = t.match(/(\d{1,3})\s*-?\s*days?\b/i);
      if (d && +d[1] >= 1 && +d[1] <= 800 && /valid|for|good|expir/i.test(t)) ex = addDays(out.load_date, +d[1]);
    }
    out.expires_on = ex;
    // promo name: the first short line that looks like one
    const line = t.split(/\n+/).map(s => s.trim()).find(s => s.length >= 3 && s.length <= 60
      && /(go\+|unli|promo|magic|surf|level|giga|\bgo\s?\d+|data\s*\d|\d+\s*(gb|days?))/i.test(s) && !/(valid|expir|until|purchased)/i.test(s));
    out.promo = line ? line.replace(/[<>]/g, '') : '';
    return out;
  }

  g.RSRLoadReader = { parse, firstDate };
})(typeof window !== 'undefined' ? window : globalThis);
