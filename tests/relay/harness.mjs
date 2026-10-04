// Gr3yLabs Support - pairing relay test harness.
//
// Runs the REAL Worker source (../../cloudflare/export-relay-worker.js) against an
// in-memory stand-in for Workers KV, so the relay's routes can be tested without Cloudflare.
//
//   node tests/relay/harness.mjs test           -> route assertions, prints ALL WORKER TESTS PASSED
//   node tests/relay/harness.mjs serve <port>    -> local HTTP relay for PowerShell end-to-end tests
//
// "serve" prints a throwaway test admin key on start - a fixed local fixture, not a secret.
// Point Export-InstalledApps.ps1 at it with -RelayUrl http://127.0.0.1:<port>.
// "serve" also has POST /__test/advance?ms=N, which moves the Worker's clock forward (harness
// only - the Worker knows nothing about it) so guest-code expiry can be tested without waiting.
//
// WHAT THIS CANNOT TEST: a plain Map is strongly consistent with no edge cache. Real
// Workers KV is eventually consistent and caches "not found" reads, so the timing between
// /open, /submit and /poll must be confirmed against the live deployed relay. Needs Node 18+
// (global fetch/Request/Response/crypto). The Worker is an ES module with no imports, so it
// is loaded from a data: URL - no temp files are written.

import http from 'node:http';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

// A movable clock: the Worker reads Date.now(), so advancing this offset moves "now" for it.
let clockOffsetMs = 0;
const realNow = Date.now.bind(Date);
Date.now = () => realNow() + clockOffsetMs;

const WORKER_URL = new URL('../../cloudflare/export-relay-worker.js', import.meta.url);
const src = readFileSync(WORKER_URL, 'utf8');
const worker = (await import('data:text/javascript;base64,' + Buffer.from(src).toString('base64'))).default;

// Stricter than a plain Map where the real KV bites: a key written with an absolute `expiration` is
// gone once that moment has passed (on the movable clock), a PUT whose expiration is not a whole
// number of seconds at least 60 ahead (or whose expirationTtl is under 60) or whose metadata is over
// 1,024 bytes is refused, and every call is counted in `stats`. Not modelled: expirationTtl expiry
// (slots and exports - the tests never wait out a 10 minute KV TTL), the one-write-per-second limit
// on a key, edge caching and eventual consistency (see WHAT THIS CANNOT TEST above).
function makeKv() {
  const store = new Map();
  const stats = { gets: 0, puts: 0, deletes: 0, lists: 0 };
  const sweep = () => {
    const nowSec = Date.now() / 1000;
    for (const [k, e] of store) if (e.expiration !== undefined && e.expiration <= nowSec) store.delete(k);
  };
  return {
    store, stats, sweep,
    async get(k) { sweep(); stats.gets++; return store.has(k) ? store.get(k).value : null; },
    async put(k, value, opts = {}) {
      sweep(); stats.puts++;
      if (opts.expiration !== undefined && !(Number.isInteger(opts.expiration) && opts.expiration >= Date.now() / 1000 + 60)) {
        throw new Error('KV PUT failed: 400 Invalid expiration of ' + opts.expiration + ' (needs a whole number of seconds at least 60 ahead)');
      }
      if (opts.expirationTtl !== undefined && !(Number.isInteger(opts.expirationTtl) && opts.expirationTtl >= 60)) {
        throw new Error('KV PUT failed: 400 Invalid expiration_ttl of ' + opts.expirationTtl + ' (60 is the minimum)');
      }
      if (opts.metadata != null && new TextEncoder().encode(JSON.stringify(opts.metadata)).length > 1024) {
        throw new Error('KV PUT failed: 413 metadata is over 1024 bytes');
      }
      store.set(k, { value, metadata: opts.metadata ?? null, ttl: opts.expirationTtl, expiration: opts.expiration });
    },
    async delete(k) { sweep(); stats.deletes++; store.delete(k); },
    async list({ prefix = '', cursor } = {}) {
      sweep(); stats.lists++;
      const names = [...store.keys()].filter(n => n.startsWith(prefix)).sort();
      // Page size 2 so the cursor loop in the Worker actually gets exercised.
      const start = cursor ? Number(cursor) : 0;
      const page = names.slice(start, start + 2);
      const done = start + 2 >= names.length;
      return { keys: page.map(n => ({ name: n, metadata: store.get(n).metadata })), list_complete: done, cursor: done ? undefined : String(start + 2) };
    },
  };
}

const ADMIN = 'AdminCode-Long-Enough-123';
const env = { EXPORT_RELAY_KV: makeKv(), ADMIN_KEY: ADMIN };
// Every call gets its own client address (CF-Connecting-IP, which Cloudflare sets in
// production) unless the test names one, so the wrong-code brake only ever sees the
// addresses a test chooses to hammer. Same header spelling in both places on purpose.
let ipSeq = 0;
const call = (method, path, headers = {}, body) =>
  worker.fetch(new Request('https://relay.test' + path, {
    method,
    headers: { 'CF-Connecting-IP': '10.0.' + (Math.floor(ipSeq / 250) % 250) + '.' + ((ipSeq++ % 250) + 1), ...headers },
    body,
  }), env);

async function runTests() {
  let r;
  // --- admin auth ---
  r = await call('GET', '/admin/keys'); assert.equal(r.status, 401, 'no key');
  assert.equal(r.headers.get('X-Relay-Features'), 'expiry,custom-codes,rename,brake', 'the deployed generation can be told from outside');
  r = await call('GET', '/admin/keys', { 'X-Access-Key': 'wrong' }); assert.equal(r.status, 401, 'wrong admin');
  r = await call('GET', '/admin/keys', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 200);
  assert.match(r.headers.get('Content-Type'), /charset=utf-8/, 'json has charset');
  assert.equal(r.headers.get('Cache-Control'), 'no-store', 'no-store header');
  assert.equal(r.headers.get('X-Content-Type-Options'), 'nosniff', 'nosniff header');
  assert.deepEqual(await r.json(), []);
  r = await call('POST', '/admin/keys', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 400, 'label required');
  r = await call('POST', '/admin/keys?label=Mike', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 200);
  const mike = await r.json();
  assert.match(mike.key, /^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/);
  assert.equal(mike.enabled, true); assert.equal(mike.label, 'Mike');
  r = await call('POST', '/admin/keys?label=Zed', { 'X-Access-Key': ADMIN }); const zed = await r.json();
  r = await call('POST', '/admin/keys?label=Amy', { 'X-Access-Key': ADMIN }); await r.json();
  // hand-added dashboard entry: no metadata, custom code, enabled stored as a boolean
  await env.EXPORT_RELAY_KV.put('guest:HANDMADE1', JSON.stringify({ label: 'Dash', enabled: true }));
  r = await call('GET', '/admin/keys', { 'X-Access-Key': ADMIN });
  const list = await r.json();
  assert.deepEqual(list.map(k => k.label), ['Amy', 'Dash', 'Mike', 'Zed'], 'sorted + paged + hand-added');
  assert.equal(list.find(k => k.label === 'Dash').key, 'HAND-MADE-1');

  // --- pairing with a guest code (lowercase, no dashes still matches) ---
  const guestLoose = mike.key.replace(/-/g, '').toLowerCase();
  r = await call('POST', '/open?code=ABC234', { 'X-Access-Key': guestLoose }); assert.equal(r.status, 200);
  const open = await r.json(); assert.equal(open.label, 'Mike'); assert.ok(open.session);
  r = await call('POST', '/open?code=ABC234', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 409, 'code in use');
  r = await call('GET', '/poll?code=ABC234', { 'X-Session': open.session }); assert.equal(r.status, 404, 'nothing yet');
  r = await call('POST', '/submit?code=ZZZ999'); assert.equal(r.status, 404, 'submit to unopened code');
  r = await call('POST', '/submit?code=ABC234', {}, ''); assert.equal(r.status, 400, 'empty body');
  r = await call('POST', '/submit?code=ABC234', {}, '{"hostname":"OLD"}'); assert.equal(r.status, 200);
  r = await call('POST', '/submit?code=ABC234', {}, '{"hostname":"EVIL"}'); assert.equal(r.status, 409, 'one-time submit');
  r = await call('GET', '/poll?code=ABC234'); assert.equal(r.status, 401, 'no session');
  r = await call('GET', '/poll?code=ABC234', { 'X-Session': 'nope' }); assert.equal(r.status, 401, 'wrong session');
  r = await call('GET', '/poll?code=ABC234', { 'X-Session': open.session }); assert.equal(r.status, 200);
  assert.match(r.headers.get('Content-Type'), /application\/json; charset=utf-8/, 'poll body has charset');
  assert.equal(await r.text(), '{"hostname":"OLD"}');
  r = await call('GET', '/poll?code=ABC234', { 'X-Session': open.session }); assert.equal(r.status, 404, 'claimed once');
  assert.equal(env.EXPORT_RELAY_KV.store.has('slot:ABC234'), false, 'slot cleaned up');

  // --- non-ASCII round-trips intact (byte-for-byte) ---
  r = await call('POST', '/open?code=UTF234', { 'X-Access-Key': ADMIN }); const u = await r.json();
  const unicodeBody = JSON.stringify({ installedProgramNames: ['Café ™ 日本 – x'] });
  r = await call('POST', '/submit?code=UTF234', {}, unicodeBody); assert.equal(r.status, 200);
  r = await call('GET', '/poll?code=UTF234', { 'X-Session': u.session });
  assert.equal(await r.text(), unicodeBody, 'unicode export round-trips intact');

  // --- /close drops the slot (idempotent) ---
  r = await call('POST', '/open?code=CLS234', { 'X-Access-Key': ADMIN }); const cl = await r.json();
  r = await call('POST', '/close?code=CLS234', { 'X-Session': 'wrong' }); assert.equal(r.status, 200, 'close is always 200');
  assert.equal(env.EXPORT_RELAY_KV.store.has('slot:CLS234'), true, 'wrong session does not close');
  r = await call('POST', '/close?code=CLS234', { 'X-Session': cl.session }); assert.equal(r.status, 200);
  assert.equal(env.EXPORT_RELAY_KV.store.has('slot:CLS234'), false, 'right session closes');
  r = await call('POST', '/submit?code=CLS234', {}, '{"x":1}'); assert.equal(r.status, 404, 'submit after close -> 404');

  // --- disable / enable / delete ---
  r = await call('POST', `/admin/keys/${mike.key}/disable`, { 'X-Access-Key': ADMIN }); assert.equal(r.status, 200);
  assert.equal((await r.json()).enabled, false);
  r = await call('POST', '/open?code=DEF345', { 'X-Access-Key': mike.key }); assert.equal(r.status, 401, 'disabled guest');
  r = await call('GET', '/admin/keys', { 'X-Access-Key': mike.key }); assert.equal(r.status, 401, 'guest is not admin');
  r = await call('POST', `/admin/keys/${mike.key}/enable`, { 'X-Access-Key': ADMIN }); assert.equal((await r.json()).enabled, true);
  r = await call('POST', '/open?code=DEF345', { 'X-Access-Key': mike.key }); assert.equal(r.status, 200, 're-enabled guest');
  r = await call('DELETE', `/admin/keys/${zed.key}`, { 'X-Access-Key': ADMIN }); assert.equal(r.status, 200);
  r = await call('POST', '/open?code=GHJ456', { 'X-Access-Key': zed.key }); assert.equal(r.status, 401, 'deleted guest');
  r = await call('DELETE', `/admin/keys/${zed.key}`, { 'X-Access-Key': ADMIN }); assert.equal(r.status, 404, 'already deleted');
  r = await call('POST', '/open?code=HAND22', { 'X-Access-Key': 'handmade1' }); assert.equal(r.status, 200, 'hand-added guest works');

  // --- enabled:"false" (a string) counts as OFF ---
  await env.EXPORT_RELAY_KV.put('guest:STRFALSE1', JSON.stringify({ label: 'Str', enabled: 'false' }));
  r = await call('POST', '/open?code=STR234', { 'X-Access-Key': 'strfalse1' }); assert.equal(r.status, 401, 'enabled string false is off');
  r = await call('GET', '/admin/keys', { 'X-Access-Key': ADMIN });
  assert.equal((await r.json()).find(k => k.label === 'Str').enabled, false, 'list shows string-false as off');

  // --- admin code can pair; a short/whitespace ADMIN_KEY disables admin (503) ---
  r = await call('POST', '/open?code=KMN567', { 'X-Access-Key': ADMIN }); assert.equal((await r.json()).label, 'admin');
  const weakEnv = { EXPORT_RELAY_KV: makeKv(), ADMIN_KEY: 'short' };
  r = await worker.fetch(new Request('https://relay.test/admin/keys', { headers: { 'X-Access-Key': 'short' } }), weakEnv);
  assert.equal(r.status, 503, 'short admin key -> admin not configured');
  // A correct key saved with a trailing newline still matches (trimmed both sides).
  const trimEnv = { EXPORT_RELAY_KV: makeKv(), ADMIN_KEY: ADMIN + '\n' };
  r = await worker.fetch(new Request('https://relay.test/admin/keys', { headers: { 'X-Access-Key': ADMIN } }), trimEnv);
  assert.equal(r.status, 200, 'trailing-newline ADMIN_KEY still matches');

  // --- code pattern: reject 4-5 chars and non-ASCII before upper-casing ---
  r = await call('POST', '/open?code=ABCD', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 400, '4-char code rejected');
  r = await call('POST', '/open?code=ABCDE', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 400, '5-char code rejected');
  r = await call('POST', '/open?code=ſſſſſſ', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 400, 'U+017F code rejected');

  // --- body-size: 413 not 400, and Content-Length short-circuit ---
  r = await call('POST', '/open?code=BIG234', { 'X-Access-Key': ADMIN }); await r.json();
  r = await call('POST', '/submit?code=BIG234', {}, 'x'.repeat(1024 * 1024 + 1)); assert.equal(r.status, 413, 'oversize -> 413');
  r = await call('POST', '/submit?code=BIG234', { 'Content-Length': String(1024 * 1024 + 5) }, 'xxxxx'); assert.equal(r.status, 413, 'declared oversize -> 413');

  // --- malformed %-escape in an admin path -> 400, not a crash ---
  r = await call('DELETE', '/admin/keys/ABC%', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 400, 'bad percent-escape -> 400');

  // --- misc ---
  r = await call('GET', '/poll'); assert.equal(r.status, 400);
  r = await call('GET', '/whatever?code=ABC234'); assert.equal(r.status, 404);
  r = await call('PUT', '/admin/keys', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 405);

  // --- guest-code expiry: optional ?hours=, /expiry route, fail-closed, KV expiration ---
  {
    const HOUR = 3600 * 1000;
    const adm = { 'X-Access-Key': ADMIN };
    const openStatus = async (code, key) => (await call('POST', '/open?code=' + code, { 'X-Access-Key': key })).status;
    const kvKeyOf = (k) => 'guest:' + k.replace(/-/g, '');
    const stored = (k) => { env.EXPORT_RELAY_KV.sweep(); return env.EXPORT_RELAY_KV.store.get(kvKeyOf(k)); };
    const keepSecs = 7 * 24 * 3600;
    const createdAtStart = clockOffsetMs;

    r = await call('POST', '/admin/keys?label=NoExpiry', adm); const noExp = await r.json();
    assert.equal(noExp.expires, null, 'no hours -> no expiry'); assert.equal(noExp.expired, false);
    assert.equal(JSON.parse(stored(noExp.key).value).expires, undefined, 'no expires field stored for never');
    assert.equal(stored(noExp.key).expiration, undefined, 'no KV expiration for never');

    r = await call('POST', '/admin/keys?label=Day&hours=24', adm); assert.equal(r.status, 200); const day = await r.json();
    assert.ok(Math.abs(day.expires - (Date.now() + 24 * HOUR)) < 5000, 'expires is ~24 h ahead');
    assert.equal(day.expired, false);
    assert.equal(stored(day.key).expiration, Math.floor(day.expires / 1000) + keepSecs, 'KV expiration = expiry + 7 days');
    assert.deepEqual(stored(day.key).metadata, JSON.parse(stored(day.key).value), 'metadata carries the record');
    assert.equal(await openStatus('EXP111', day.key), 200, 'unexpired code opens');
    clockOffsetMs += 23 * HOUR;
    assert.equal(await openStatus('EXP112', day.key), 200, 'still valid at 23 h');
    clockOffsetMs += 2 * HOUR; // 25 h in
    assert.equal(await openStatus('EXP113', day.key), 401, 'expired code is refused like an off one');
    r = await call('GET', '/admin/keys', adm); const listed = (await r.json()).find(k => k.label === 'Day');
    assert.equal(listed.expired, true, 'list says expired');
    assert.equal(listed.enabled, true, 'expired is not the same as switched off');
    assert.equal(listed.expires, day.expires);
    assert.equal(await openStatus('EXP114', ADMIN), 200, 'the admin code never expires');

    // extend an expired code; disable/enable keep both the expiry and the KV expiration
    r = await call('POST', '/admin/keys/' + day.key + '/expiry?hours=48', adm); assert.equal(r.status, 200); const ext = await r.json();
    assert.ok(Math.abs(ext.expires - (Date.now() + 48 * HOUR)) < 5000, 'expiry restarts from now');
    assert.equal(ext.expired, false);
    assert.equal(await openStatus('EXP115', day.key), 200, 'extended code opens again');
    assert.equal(stored(day.key).expiration, Math.floor(ext.expires / 1000) + keepSecs, 'KV expiration follows the new expiry');
    r = await call('POST', '/admin/keys/' + day.key + '/disable', adm); const dis = await r.json();
    assert.equal(dis.expires, ext.expires, 'disable keeps expires');
    assert.equal(stored(day.key).expiration, Math.floor(ext.expires / 1000) + keepSecs, 'disable keeps the KV expiration');
    r = await call('POST', '/admin/keys/' + day.key + '/enable', adm); assert.equal((await r.json()).expires, ext.expires, 'enable keeps expires');
    assert.equal(stored(day.key).expiration, Math.floor(ext.expires / 1000) + keepSecs, 'enable keeps the KV expiration');

    // remove the expiry: 0 / never / none, any case; the record and the KV expiration go too
    for (const never of ['0', 'never', 'NEVER', 'none']) {
      r = await call('POST', '/admin/keys/' + day.key + '/expiry?hours=5', adm); assert.equal((await r.json()).expired, false);
      r = await call('POST', '/admin/keys/' + day.key + '/expiry?hours=' + never, adm); assert.equal(r.status, 200, 'never = ' + never);
      assert.equal((await r.json()).expires, null);
      assert.equal(JSON.parse(stored(day.key).value).expires, undefined, 'expires field removed');
      assert.equal(stored(day.key).expiration, undefined, 'KV expiration removed with it');
    }

    // invalid values are refused on both routes and change nothing
    for (const bad of ['abc', '-1', '9000', '8760.5', '0.001', '0.016', 'NaN', 'Infinity', '1e9']) {
      r = await call('POST', '/admin/keys/' + day.key + '/expiry?hours=' + bad, adm); assert.equal(r.status, 400, 'expiry hours=' + bad);
      r = await call('POST', '/admin/keys?label=Bad&hours=' + bad, adm); assert.equal(r.status, 400, 'create hours=' + bad);
    }
    r = await call('POST', '/admin/keys/' + day.key + '/expiry', adm); assert.equal(r.status, 400, 'expiry needs hours');
    r = await call('POST', '/admin/keys/' + day.key + '/expiry?hours=', adm); assert.equal(r.status, 400, 'empty hours is not "never"');
    r = await call('POST', '/admin/keys/ZZZZZZZZZZZZ/expiry?hours=5', adm); assert.equal(r.status, 404, 'unknown code');
    r = await call('GET', '/admin/keys/' + day.key + '/expiry', adm); assert.equal(r.status, 404, 'expiry is POST only');
    r = await call('POST', '/admin/keys/' + day.key + '/expiry?hours=5', { 'X-Access-Key': noExp.key }); assert.equal(r.status, 401, 'a guest cannot set expiry');
    assert.equal(JSON.parse(stored(day.key).value).expires, undefined, 'refused calls left the record alone');
    assert.ok(!(await (await call('GET', '/admin/keys', adm)).json()).some(k => k.label === 'Bad'), 'no code created for a bad hours');
    // boundaries accepted
    for (const ok of ['0.02', '8760', '0.5', ' 3 ']) {
      r = await call('POST', '/admin/keys/' + day.key + '/expiry?hours=' + encodeURIComponent(ok), adm); assert.equal(r.status, 200, 'boundary ' + ok);
    }
    r = await call('POST', '/admin/keys?label=Zero&hours=0', adm); assert.equal((await r.json()).expires, null, 'create hours=0 -> never');
    r = await call('POST', '/admin/keys?label=NeverWord&hours=never', adm); assert.equal((await r.json()).expires, null, 'create hours=never -> never');

    // a hand-edited, unusable expires fails closed, and an admin can repair it
    await env.EXPORT_RELAY_KV.put('guest:BADEXPIRY1', JSON.stringify({ label: 'Hand', enabled: true, expires: 'tomorrow' }));
    assert.equal(await openStatus('EXP116', 'badexpiry1'), 401, 'unusable expires fails closed');
    r = await call('GET', '/admin/keys', adm); const hand = (await r.json()).find(k => k.label === 'Hand');
    assert.equal(hand.expired, true); assert.equal(hand.expires, null);
    r = await call('POST', '/admin/keys/BADEXPIRY1/expiry?hours=1', adm); assert.equal((await r.json()).expired, false);
    assert.equal(await openStatus('EXP117', 'badexpiry1'), 200, 'repaired code opens');

    // A lapsed code stays listed (as expired) for the week KV keeps it, and can be re-saved ...
    r = await call('POST', '/admin/keys?label=Old&hours=1', adm); const old = await r.json();
    clockOffsetMs += 3 * 24 * HOUR;
    r = await call('POST', '/admin/keys/' + old.key + '/enable', adm); assert.equal(r.status, 200, 'a code that expired 3 days ago can still be re-saved');
    assert.ok(stored(old.key).expiration >= Math.floor(Date.now() / 1000) + 60, 'expiration is at least 60 s ahead');
    assert.equal((await (await call('GET', '/admin/keys', adm)).json()).find(k => k.label === 'Old').expired, true);
    r = await call('DELETE', '/admin/keys/' + old.key, adm); assert.equal(r.status, 200, 'an expired code can be deleted');
    // ... and after that week KV has removed it by itself.
    r = await call('POST', '/admin/keys?label=Gone&hours=1', adm); const gone = await r.json();
    clockOffsetMs += 8 * 24 * HOUR;
    r = await call('POST', '/admin/keys/' + gone.key + '/enable', adm); assert.equal(r.status, 404, 'a week after it expired the code is gone');
    assert.ok(!(await (await call('GET', '/admin/keys', adm)).json()).some(k => k.label === 'Gone'), 'and no longer listed');
    // KV's 60 s floor still applies to a record with a long-past expires but no KV expiration
    // (added by hand): the re-save must not ask for an expiration that has already passed.
    await env.EXPORT_RELAY_KV.put('guest:LONGGONE001', JSON.stringify({ label: 'LongGone', enabled: false, expires: Date.now() - 30 * 24 * HOUR }));
    r = await call('POST', '/admin/keys/LONGGONE001/enable', adm); assert.equal(r.status, 200, 're-saving a long-past expiry works');
    assert.ok(stored('LONGGONE001').expiration >= Math.floor(Date.now() / 1000) + 60, 'the 60 s floor holds');
    r = await call('DELETE', '/admin/keys/LONGGONE001', adm); assert.equal(r.status, 200);

    clockOffsetMs = createdAtStart; // later tests run on the real clock
  }

  // --- owner-chosen ("throwaway") codes, /rename, the short-code policy, the wrong-code brake ---
  {
    const HOUR = 3600 * 1000;
    const adm = { 'X-Access-Key': ADMIN };
    const base = clockOffsetMs;
    const openStatus = async (code, key, ip) =>
      (await call('POST', '/open?code=' + code, { 'X-Access-Key': key, ...(ip ? { 'CF-Connecting-IP': ip } : {}) })).status;
    const stored = (k) => { env.EXPORT_RELAY_KV.sweep(); return env.EXPORT_RELAY_KV.store.get('guest:' + k.replace(/[^A-Za-z0-9]/g, '')); };
    const create = async (qs) => call('POST', '/admin/keys?' + qs, adm);
    const keepSecs = 7 * 24 * 3600;

    // a 4-digit code with a 1 hour life: shown as typed, pairs, expires
    r = await create('label=Throwaway&hours=1&code=9989'); assert.equal(r.status, 200); const tw = await r.json();
    assert.equal(tw.key, '9989', 'custom code is shown as typed (normalised), not regrouped');
    assert.equal(tw.custom, true); assert.equal(tw.expired, false);
    assert.ok(Math.abs(tw.expires - (Date.now() + HOUR)) < 5000, 'throwaway expires in ~1 h');
    assert.equal(JSON.parse(stored('9989').value).custom, true, 'custom flag stored');
    assert.equal(await openStatus('TWY111', '9989'), 200, 'the chosen code pairs');
    assert.equal(await openStatus('TWY112', '9-9-8-9'), 200, 'dashes ignored when it is typed');
    assert.equal((await (await call('GET', '/admin/keys', adm)).json()).find(k => k.label === 'Throwaway').key, '9989');
    clockOffsetMs = base + HOUR + 1000;
    assert.equal(await openStatus('TWY113', '9989'), 401, 'expired throwaway code is refused');
    assert.equal((await (await call('GET', '/admin/keys', adm)).json()).find(k => k.label === 'Throwaway').expired, true);
    // still expired here (the clock has NOT been rolled back): an expired code keeps its name
    r = await create('label=Dup&hours=1&code=9989'); assert.equal(r.status, 409, 'an expired code still holds its name');
    // renaming with no hours keeps the lapsed expiry (still expired); with hours the code is revived
    r = await call('POST', '/admin/keys/9989/rename?to=6543', adm); assert.equal(r.status, 200);
    assert.equal((await r.json()).expired, true, 'rename without hours keeps the lapsed expiry');
    r = await call('POST', '/admin/keys/6543/rename?to=9989&hours=1', adm); assert.equal(r.status, 200);
    assert.equal((await r.json()).expired, false, 'rename with hours revives it');
    clockOffsetMs = base;

    // normalisation, collisions, and what is refused
    r = await create('label=Mixed&hours=2&code=ab12cd'); const mixed = await r.json();
    assert.equal(mixed.key, 'AB12CD', 'upper-cased'); assert.equal(await openStatus('MIX111', 'ab12cd'), 200, 'case-insensitive');
    r = await create('label=Dup&hours=2&code=ab-12 CD'); assert.equal(r.status, 409, 'same code after normalising -> 409');
    for (const bad of ['abc', '12', 'ab%C3%A9d', 'a_b_c_d', 'a.b.c.d', 'x'.repeat(33), '%F0%9F%98%80%F0%9F%98%80']) {
      r = await create('label=Bad&hours=1&code=' + bad); assert.equal(r.status, 400, 'bad code ' + bad);
    }
    for (const blank of ['', '%20%20']) {
      r = await create('label=Random&code=' + blank); assert.equal(r.status, 200, 'blank code = random');
      const rnd = await r.json(); assert.equal(rnd.custom, false); assert.match(rnd.key, /^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/);
    }
    r = await create('label=Max32&code=' + 'Z'.repeat(32)); assert.equal(r.status, 200, '32 characters is fine'); assert.equal((await r.json()).expires, null);
    assert.ok(!(await (await call('GET', '/admin/keys', adm)).json()).some(k => k.label === 'Bad'), 'nothing created for a bad code');

    // short-code policy: under 8 characters must expire within 24 hours
    for (const qs of ['code=4829', 'code=4829&hours=0', 'code=4829&hours=never', 'code=4829&hours=25', 'code=4829&hours=24.5', 'code=ABCDEFG&hours=48']) {
      r = await create('label=Short&' + qs); assert.equal(r.status, 400, 'short code refused: ' + qs);
    }
    for (const qs of ['code=4829&hours=24', 'code=4830&hours=0.02', 'code=4831&hours=1', 'code=ABCDEFG1&hours=48', 'code=ABCDEFG2', 'code=ABCDEFG3&hours=never']) {
      r = await create('label=Short&' + qs); assert.equal(r.status, 200, 'accepted: ' + qs);
    }
    r = await call('POST', '/admin/keys/4829/expiry?hours=48', adm); assert.equal(r.status, 400, 'expiry route enforces the policy: 48 h');
    r = await call('POST', '/admin/keys/4829/expiry?hours=never', adm); assert.equal(r.status, 400, 'expiry route enforces the policy: never');
    r = await call('POST', '/admin/keys/4829/expiry?hours=12', adm); assert.equal(r.status, 200, 'expiry route: 12 h is fine');
    r = await call('POST', '/admin/keys/ABCDEFG2/expiry?hours=never', adm); assert.equal(r.status, 200, 'an 8-character code may never expire');

    // rename: the same guest under a new code; the old one stops working at once
    r = await create('label=Rotate&hours=1&code=5551'); await r.json();
    // Give it an old creation date, so a rename that regenerated `created` (as today) is noticed.
    const createdWas = '2020-01-02';
    { const s = stored('5551'); const old = { ...JSON.parse(s.value), created: createdWas };
      await env.EXPORT_RELAY_KV.put('guest:5551', JSON.stringify(old), { metadata: old, expiration: s.expiration }); }
    r = await call('POST', '/admin/keys/5551/disable', adm); assert.equal(r.status, 200);
    clockOffsetMs = base + 30 * 60 * 1000; // half way through
    r = await call('POST', '/admin/keys/5551/rename?to=77ab3&hours=1', adm); assert.equal(r.status, 200); const ren = await r.json();
    assert.equal(ren.key, '77AB3'); assert.equal(ren.label, 'Rotate'); assert.equal(ren.enabled, false, 'on/off carries over'); assert.equal(ren.created, createdWas);
    assert.equal(ren.custom, true);
    assert.ok(Math.abs(ren.expires - (Date.now() + HOUR)) < 5000, 'rename with hours restarts the clock');
    assert.equal(stored('5551'), undefined, 'old record removed');
    assert.equal(stored('77AB3').expiration, Math.floor(ren.expires / 1000) + keepSecs, 'KV expiration follows');
    r = await call('POST', '/admin/keys/77AB3/enable', adm); assert.equal(r.status, 200);
    assert.equal(await openStatus('REN111', '77ab3'), 200, 'new code works');
    assert.equal(await openStatus('REN112', '5551'), 401, 'old code refused');
    r = await call('POST', '/admin/keys/5551/enable', adm); assert.equal(r.status, 404, 'old code no longer exists');
    clockOffsetMs = base;

    // rename keeps the expiry unless hours is given; the policy applies to the result
    r = await create('label=Keep&hours=100&code=KEEPLONG01'); const keep = await r.json();
    r = await call('POST', '/admin/keys/KEEPLONG01/rename?to=KEEPLONG02', adm); assert.equal(r.status, 200);
    const kept = await r.json(); assert.equal(kept.expires, keep.expires, 'no hours = expiry kept as is');
    r = await call('POST', '/admin/keys/KEEPLONG02/rename?to=ABCD', adm); assert.equal(r.status, 400, 'short code cannot inherit a long expiry');
    r = await call('POST', '/admin/keys/KEEPLONG02/rename?to=ABCD&hours=2', adm); assert.equal(r.status, 200, 'short code with a short expiry is fine');
    r = await call('POST', '/admin/keys/ABCD/rename?to=KEEPLONG03&hours=never', adm); assert.equal((await r.json()).expires, null, 'hours=never removes the expiry');
    r = await call('POST', '/admin/keys/KEEPLONG03/rename', adm); assert.equal(r.status, 200, 'no to = a random new code');
    const randomized = await r.json(); assert.equal(randomized.custom, false); assert.match(randomized.key, /^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/);
    assert.equal(stored('KEEPLONG03'), undefined, 'the old one is gone');

    // rename refusals
    r = await call('POST', '/admin/keys/ABCDEFG2/rename?to=ABCDEFG1', adm); assert.equal(r.status, 409, 'target in use');
    r = await call('POST', '/admin/keys/ABCDEFG2/rename?to=abcd-efg2', adm); assert.equal(r.status, 400, 'same code');
    r = await call('POST', '/admin/keys/NOSUCHCODE9/rename?to=ZZZZZZZZZ', adm); assert.equal(r.status, 404, 'unknown code');
    r = await call('POST', '/admin/keys/ABCDEFG2/rename?to=xx', adm); assert.equal(r.status, 400, 'too short');
    r = await call('POST', '/admin/keys/ABCDEFG2/rename?to=ZZZZZZZZ&hours=', adm); assert.equal(r.status, 400, 'empty hours');
    r = await call('POST', '/admin/keys/ABCDEFG2/rename?to=ZZZZZZZZ&hours=abc', adm); assert.equal(r.status, 400, 'bad hours');
    r = await call('GET', '/admin/keys/ABCDEFG2/rename?to=ZZZZZZZZ', adm); assert.equal(r.status, 404, 'rename is POST only');
    r = await call('POST', '/admin/keys/ABCDEFG2/rename?to=ZZZZZZZZ', { 'X-Access-Key': 'ABCDEFG2' }); assert.equal(r.status, 401, 'a guest cannot rename');
    assert.ok(stored('ABCDEFG2'), 'refused calls changed nothing');
    await env.EXPORT_RELAY_KV.put('guest:BADEXP00001', JSON.stringify({ label: 'BadExp', enabled: true, expires: 'soon' }));
    r = await call('POST', '/admin/keys/BADEXP00001/rename?to=BADEXP00002', adm); assert.equal(r.status, 400, 'unusable expiry must be replaced explicitly');
    r = await call('POST', '/admin/keys/BADEXP00001/rename?to=BADEXP00002&hours=5', adm); assert.equal(r.status, 200, 'with hours it is repaired');

    // ---- the wrong-code brake ------------------------------------------------------------------
    // 20 refused codes per client per 10 minutes, then 429. A guess is counted when the request
    // ARRIVES (so a parallel burst cannot slip past) and handed back if the code turns out to be
    // good; the admin code is never blocked; an unknown, a switched-off and an expired code are
    // refused - and counted - alike.
    const kv = env.EXPORT_RELAY_KV;
    const bad = '198.51.100.7';
    for (let i = 0; i < 20; i++) assert.equal(await openStatus('LIM' + String(100 + i), 'guess-' + i, bad), 401, 'wrong guess ' + i);
    assert.equal(await openStatus('LIM200', 'guess-x', bad), 429, 'over the limit');
    assert.equal(await openStatus('LIM201', mike.key, bad), 429, 'a correct GUEST code is held back too while locked out');
    assert.equal(await openStatus('LIM205', ADMIN, bad), 200, 'the admin code is never blocked');
    r = await call('GET', '/admin/keys', { 'X-Access-Key': ADMIN, 'CF-Connecting-IP': bad }); assert.equal(r.status, 200, 'not on the admin routes either');
    r = await call('GET', '/admin/keys', { 'CF-Connecting-IP': bad }); assert.equal(r.status, 401, 'a key-less version probe is never blocked');
    assert.equal(await openStatus('LIM202', ADMIN, '198.51.100.8'), 200, 'another client is unaffected');
    const readsLocked = kv.stats.gets;
    for (let i = 0; i < 10; i++) assert.equal(await openStatus('LIM3' + String(10 + i), 'more-' + i, bad), 429, 'still locked ' + i);
    assert.equal(kv.stats.gets, readsLocked, 'a locked-out client costs no KV reads');
    r = await call('POST', '/open?code=LIM203', { 'X-Access-Key': 'x', 'CF-Connecting-IP': bad });
    assert.ok(r.status === 429 && Number(r.headers.get('Retry-After')) >= 590 && Number(r.headers.get('Retry-After')) <= 600, 'Retry-After says how long is left');
    clockOffsetMs = base + 5 * 60 * 1000;
    r = await call('POST', '/open?code=LIM206', { 'X-Access-Key': 'x', 'CF-Connecting-IP': bad });
    assert.ok(r.status === 429 && Number(r.headers.get('Retry-After')) >= 290 && Number(r.headers.get('Retry-After')) <= 300, 'and it counts down');
    clockOffsetMs = base + 11 * 60 * 1000;
    for (let i = 0; i < 20; i++) assert.equal(await openStatus('LIM4' + String(10 + i), 'again-' + i, bad), 401, 'a new window starts clean: guess ' + i);
    assert.equal(await openStatus('LIM430', 'again-x', bad), 429, 'and locks again after another 20');
    clockOffsetMs = base;

    // a good code is not a wrong guess: the slot taken on arrival is handed back
    const mix = '198.51.100.9';
    for (let i = 0; i < 19; i++) assert.equal(await openStatus('MXD' + String(100 + i), 'mix-' + i, mix), 401, 'wrong guess ' + i);
    assert.equal(await openStatus('MXD200', mike.key, mix), 200, 'a good code gets in');
    assert.equal(await openStatus('MXD201', 'mix-x', mix), 401, 'the 20th refused code still gets its 401');
    assert.equal(await openStatus('MXD202', 'mix-y', mix), 429, 'the 21st is blocked: exactly 20 refused codes were counted');
    for (let i = 0; i < 40; i++) assert.equal(await openStatus('SEQ' + String(100 + i), mike.key, '198.51.100.10'), 200, 'good codes never lock a client out: open ' + i);

    // parallel bursts are counted as they arrive, not after the first KV read comes back
    const burstReads = kv.stats.gets;
    const burst = await Promise.all(Array.from({ length: 60 }, (_, i) =>
      call('POST', '/open?code=BRS' + String(100 + i), { 'X-Access-Key': 'burst-' + i, 'CF-Connecting-IP': '198.51.100.40' })));
    const tally = {};
    for (const b of burst) tally[b.status] = (tally[b.status] || 0) + 1;
    assert.deepEqual(tally, { 401: 20, 429: 40 }, 'only 20 of 60 parallel guesses are evaluated');
    assert.equal(kv.stats.gets - burstReads, 20, 'and only those 20 reach KV');
    const adminBurst = await Promise.all(Array.from({ length: 40 }, (_, i) =>
      call('GET', '/admin/keys', { 'X-Access-Key': 'abur-' + i, 'CF-Connecting-IP': '198.51.100.42' })));
    const tally2 = {};
    for (const b of adminBurst) tally2[b.status] = (tally2[b.status] || 0) + 1;
    assert.deepEqual(tally2, { 401: 20, 429: 20 }, 'the same on the admin routes');
    // Counting on arrival has a price: more than 20 simultaneous requests from one address are
    // limited even when the code is good. Every slot is handed back, so nobody stays locked out.
    const goodBurst = await Promise.all(Array.from({ length: 25 }, (_, i) =>
      call('POST', '/open?code=VBR' + String(100 + i), { 'X-Access-Key': mike.key, 'CF-Connecting-IP': '198.51.100.41' })));
    assert.equal(goodBurst.filter(g => g.status === 200).length, 20, '20 of 25 simultaneous good codes get in');
    assert.ok(goodBurst.every(g => g.status === 200 || g.status === 429), 'the rest are told to wait, not refused');
    assert.equal(await openStatus('VBR200', mike.key, '198.51.100.41'), 200, 'and the client is not locked out afterwards');

    // a storage error is not a wrong guess: 30 requests that fail with a 503 leave the client unlocked
    const realGet = kv.get;
    kv.get = async () => { throw new Error('KV down'); };
    for (let i = 0; i < 30; i++) assert.equal(await openStatus('KVD' + String(100 + i), mike.key, '198.51.100.43'), 503, 'storage down: request ' + i);
    kv.get = realGet;
    assert.equal(await openStatus('KVD200', mike.key, '198.51.100.43'), 200, 'and the client is not locked out once storage is back');

    // an IPv6 client owns its whole /64, so the /64 is what is counted; IPv4-mapped = the IPv4 address
    const sameNet = ['2001:db8:5:5::1', '2001:DB8:5:5:0:0:0:2', '2001:db8:5:5:aaaa:bbbb:cccc:dddd', '2001:db8:5:5::'];
    for (let i = 0; i < 20; i++) assert.equal(await openStatus('V6A' + String(100 + i), 'v6-' + i, sameNet[i % sameNet.length]), 401, 'v6 guess ' + i);
    assert.equal(await openStatus('V6A200', 'v6-x', '2001:db8:5:5:1234:5678:9abc:def0'), 429, 'one /64 shares one budget');
    assert.equal(await openStatus('V6A201', mike.key, '2001:db8:5:6::1'), 200, 'a different /64 is unaffected');
    for (let i = 0; i < 20; i++) assert.equal(await openStatus('MAP' + String(100 + i), 'map-' + i, i % 2 ? '::ffff:203.0.113.9' : '203.0.113.9'), 401, 'mapped guess ' + i);
    assert.equal(await openStatus('MAP200', 'map-x', '::FFFF:203.0.113.9'), 429, 'an IPv4-mapped address counts as its IPv4 address');
    for (const odd of ['garbage', ':::', '1:2:3', '::', '::1', '1::2::3', 'fe80::1%eth0', '1:2:3:4:5:6:7:8:9']) {
      assert.equal(await openStatus('ODD234', 'oddity', odd), 401, 'an unusual address does not break the brake: ' + odd);
    }

    // an unknown, a switched-off and an expired code are refused - and counted - the same way
    r = await create('label=Stale&hours=1&code=STALE0001'); await r.json();
    r = await call('POST', '/admin/keys/STALE0001/disable', adm); assert.equal(r.status, 200);
    await kv.put('guest:LAPSED0001', JSON.stringify({ label: 'Lapsed', enabled: true, expires: Date.now() - 1000 }));
    const lockBodies = [];
    for (const [kind, ip] of [['STALE0001', '198.51.100.20'], ['LAPSED0001', '198.51.100.21'], ['NOSUCH0001', '198.51.100.22']]) {
      for (let i = 0; i < 20; i++) assert.equal(await openStatus('STL' + String(100 + i), kind, ip), 401, kind + ' attempt ' + i);
      r = await call('POST', '/open?code=STL200', { 'X-Access-Key': kind, 'CF-Connecting-IP': ip });
      assert.equal(r.status, 429, kind + ': the 21st refused code is blocked');
      lockBodies.push(await r.text());
    }
    assert.ok(lockBodies.every(b => b === lockBodies[0]), 'a stale code cannot be told from a missing one');
    assert.equal(await openStatus('STL201', ADMIN, '198.51.100.20'), 200, 'the owner is not locked out by a tester retrying a stale code');
    // no key at all is not a guess either
    for (let i = 0; i < 30; i++) { r = await call('POST', '/open?code=NOK' + String(100 + i), { 'CF-Connecting-IP': '198.51.100.23' }); assert.equal(r.status, 401); }
    assert.equal(await openStatus('NOK200', mike.key, '198.51.100.23'), 200, 'key-less requests are not counted');
    // wrong admin codes and wrong pairing codes share one budget; the admin code still works
    for (let i = 0; i < 10; i++) assert.equal(await openStatus('ADM' + String(100 + i), 'adm-' + i, '198.51.100.30'), 401);
    for (let i = 0; i < 10; i++) { r = await call('GET', '/admin/keys', { 'X-Access-Key': 'wrong-' + i, 'CF-Connecting-IP': '198.51.100.30' }); assert.equal(r.status, 401); }
    r = await call('GET', '/admin/keys', { 'X-Access-Key': 'wrong-x', 'CF-Connecting-IP': '198.51.100.30' }); assert.equal(r.status, 429, 'wrong admin and wrong pairing codes share one budget');
    r = await call('GET', '/admin/keys', { 'X-Access-Key': ADMIN, 'CF-Connecting-IP': '198.51.100.30' }); assert.equal(r.status, 200, 'the admin code still works');
    r = await call('POST', '/admin/keys?label=FromLocked&hours=1', { 'X-Access-Key': ADMIN, 'CF-Connecting-IP': '198.51.100.30' }); assert.equal(r.status, 200, 'and can still manage codes');

    // the brake's memory is bounded: past 5000 tracked clients the oldest are forgotten, newer ones keep their lock
    const evictee = '203.0.113.50';
    const keeper = '203.0.113.51';
    const spray = async (from, to) => { for (let i = from; i < to; i++) await openStatus('SPR100', 'spray-' + i, '172.16.' + (i >> 8) + '.' + (i & 255)); };
    assert.equal(await openStatus('EVI100', 'evict-0', evictee), 401);
    await spray(0, 4000);
    for (let i = 0; i < 20; i++) assert.equal(await openStatus('EVI101', 'keep-' + i, keeper), 401);
    await spray(4000, 6000);
    assert.equal(await openStatus('EVI102', 'keep-x', keeper), 429, 'a newer client keeps its lock');
    let evicteeWrong = 0;
    while (evicteeWrong < 30 && (await openStatus('EVI103', 'evict-' + (evicteeWrong + 1), evictee)) === 401) evicteeWrong++;
    assert.equal(evicteeWrong, 20, 'the oldest client was forgotten, so it gets a fresh 20');

    // the short-code rule is also checked when a code is USED: a short code added by hand, with no
    // expiry or one a month away, is not accepted
    await kv.put('guest:HAND5', JSON.stringify({ label: 'Hand5', enabled: true }));
    await kv.put('guest:HAND6', JSON.stringify({ label: 'Hand6', enabled: true, expires: Date.now() + 2 * HOUR }));
    await kv.put('guest:HAND7', JSON.stringify({ label: 'Hand7', enabled: true, expires: Date.now() + 30 * 24 * HOUR }));
    await kv.put('guest:HAND8CHR', JSON.stringify({ label: 'Hand8', enabled: true }));
    await kv.put('guest:HANDMD7', JSON.stringify({ label: 'Hand7chars', enabled: true })); // 7 characters; listed as HAND-MD7 (8)
    assert.equal(await openStatus('WKU111', 'hand5'), 401, 'a short code with no expiry is refused');
    assert.equal(await openStatus('WKU112', 'hand6'), 200, 'a short code that expires within a day works');
    assert.equal(await openStatus('WKU113', 'hand7'), 401, 'a short code that expires in a month is refused');
    assert.equal(await openStatus('WKU114', 'hand8chr'), 200, 'an 8 character code needs no expiry');
    const handList = await (await call('GET', '/admin/keys', adm)).json();
    assert.equal(handList.find(k => k.label === 'Hand5').expired, true, 'and the list says so');
    assert.equal(handList.find(k => k.label === 'Hand6').expired, false);
    assert.equal(handList.find(k => k.label === 'Hand8').expired, false);
    assert.equal(handList.find(k => k.label === 'Hand7chars').expired, true, 'a 7 character code is judged by its real length, not the dashed form it is listed in');
    assert.equal(await openStatus('WKU116', 'handmd7'), 401);
    r = await call('POST', '/admin/keys/HAND5/expiry?hours=3', adm); assert.equal(r.status, 200);
    assert.equal(await openStatus('WKU115', 'hand5'), 200, 'giving it a short expiry makes it usable');

    // a chosen code cannot be the admin code (a mistake that would hand the secret out as a "guest")
    for (const clash of ['AdminCode-Long-Enough-123', 'admincode long enough 123', 'ADMINCODELONGENOUGH123']) {
      r = await create('label=Clash&hours=1&code=' + encodeURIComponent(clash)); assert.equal(r.status, 400, 'not as a new code: ' + clash);
      r = await call('POST', '/admin/keys/ABCDEFG2/rename?to=' + encodeURIComponent(clash), adm); assert.equal(r.status, 400, 'nor as a rename target: ' + clash);
    }
    r = await create('label=Near&hours=1&code=AdminCode-Long-Enough-1234'); assert.equal(r.status, 200, 'a code that merely starts the same is fine');

    // storage failures in the middle of a rename
    r = await create('label=Fail&hours=5&code=FAILCODE01'); assert.equal(r.status, 200);
    const realDelete = kv.delete;
    const realPut = kv.put;
    kv.put = async () => { throw new Error('KV down'); };
    r = await call('POST', '/admin/keys/FAILCODE01/rename?to=FAILCODE02', adm); assert.equal(r.status, 503, 'a rename fails cleanly when the new code cannot be saved');
    kv.put = realPut;
    assert.equal(await openStatus('FLR111', 'FAILCODE01'), 200, 'the old code is untouched');
    assert.equal(await openStatus('FLR112', 'FAILCODE02'), 401, 'and the new one does not exist');
    kv.delete = async () => { throw new Error('KV down'); };
    r = await call('POST', '/admin/keys/FAILCODE01/rename?to=FAILCODE02', adm);
    assert.equal(r.status, 503); assert.match(await r.text(), /BOTH work/, 'a failed delete says that both codes work');
    kv.delete = realDelete;
    assert.equal(await openStatus('FLR113', 'FAILCODE01'), 200); assert.equal(await openStatus('FLR114', 'FAILCODE02'), 200, 'both codes really do work');
    r = await call('DELETE', '/admin/keys/FAILCODE01', adm); assert.equal(r.status, 200, 'the old one can be deleted by hand');

    // a label is cut at 60 characters, not in the middle of an emoji
    r = await create('label=' + encodeURIComponent('A'.repeat(59) + '\u{1F600}B') + '&hours=1&code=EMOJI0001'); const emo = await r.json();
    assert.equal(Array.from(emo.label).length, 60, '60 characters');
    assert.ok(emo.label.endsWith('\u{1F600}'), 'ending in the whole emoji');
    assert.ok(!/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(emo.label), 'no half an emoji');

    // the short-code rule at use time: a few minutes of clock difference is tolerated, a day and more is not
    const skew = (key, aheadMs) => kv.put('guest:' + key, JSON.stringify({ label: 'Skew' + key, enabled: true, expires: Date.now() + aheadMs }));
    await skew('SKW4A', 24 * HOUR + 4 * 60 * 1000);
    await skew('SKW6B', 24 * HOUR + 6 * 60 * 1000);
    await skew('SKW3D', 3 * 24 * HOUR);
    await skew('SKWOK', 24 * HOUR);
    assert.equal(await openStatus('SKW111', 'skw4a'), 200, '4 minutes over a day is inside the clock slack');
    assert.equal(await openStatus('SKW112', 'skw6b'), 401, '6 minutes over a day is not');
    assert.equal(await openStatus('SKW113', 'skw3d'), 401, 'three days is not');
    assert.equal(await openStatus('SKW114', 'skwok'), 200, 'exactly a day is fine');

    // more spellings of one IPv6 /64, and of IPv4-mapped addresses: each pair is ONE client
    const spellings = [
      ['2001:0db8:0006:0006::1', '2001:db8:6:6:ffff:ffff:ffff:ffff'], // leading zeros; '::' at the end
      ['2001:db8::6:7:8:9', '2001:db8:0:0:1:2:3:4'], // '::' inside the first four groups
      ['0:0:0:0:0:ffff:203.0.113.77', '203.0.113.77'], // mapped, full form with a dotted tail
      ['::ffff:cb00:714e', '203.0.113.78'], // mapped, written in hex groups (cb00:714e = 203.0.113.78)
      ['0:0:0:0:0:ffff:cb00:714f', '::ffff:203.0.113.79'], // hex full form against the dotted short form
    ];
    for (const [a, b] of spellings) {
      for (let i = 0; i < 20; i++) assert.equal(await openStatus('SPL' + String(100 + i), 'spell-' + i, a), 401, 'guess ' + i + ' from ' + a);
      assert.equal(await openStatus('SPL200', 'spell-x', b), 429, a + ' and ' + b + ' are one client');
    }

    // a refund goes to the window the slot was taken from: a request that finishes after its window
    // ended must not credit the new window
    {
      const rid = '198.51.100.44';
      const mikeKv = 'guest:' + mike.key.replace(/-/g, '');
      let release;
      const gate = new Promise((res) => { release = res; });
      const realGetGate = kv.get;
      kv.get = async (k) => { if (k === mikeKv) await gate; return realGetGate(k); };
      const slow = Array.from({ length: 20 }, (_, i) =>
        call('POST', '/open?code=RFD' + String(100 + i), { 'X-Access-Key': mike.key, 'CF-Connecting-IP': rid })); // window 1, waiting on KV
      clockOffsetMs = base + 11 * 60 * 1000; // window 1 ends
      for (let i = 0; i < 19; i++) assert.equal(await openStatus('RFE' + String(100 + i), 'late-' + i, rid), 401, 'window 2 guess ' + i);
      kv.get = realGetGate;
      release();
      await Promise.all(slow); // their refunds arrive now
      assert.equal(await openStatus('RFE200', 'late-x', rid), 401, 'the 20th refused code of window 2 is still evaluated');
      assert.equal(await openStatus('RFE201', 'late-y', rid), 429, 'the 21st is blocked: the late refunds did not credit window 2');
      clockOffsetMs = base;
    }

    // a renewed window goes to the back of the queue: when the table overflows the oldest are dropped, not it
    {
      const renew = '203.0.113.60';
      const spray2 = async (from, to) => { for (let i = from; i < to; i++) await openStatus('RNW101', 'rspray-' + i, '172.17.' + (i >> 8) + '.' + (i & 255)); };
      assert.equal(await openStatus('RNW100', 'renew-0', renew), 401); // the first window
      clockOffsetMs = base + 60 * 1000;
      await spray2(0, 4000); // windows that outlast the first
      clockOffsetMs = base + 10 * 60 * 1000 + 30 * 1000; // the first window has ended, the spray's has not
      assert.equal(await openStatus('RNW102', 'renew-1', renew), 401); // renewed: count 1, now the newest entry
      await spray2(4000, 5500); // the table overflows
      let more = 0;
      while (more < 30 && (await openStatus('RNW103', 'renew-' + (more + 2), renew)) === 401) more++;
      assert.equal(more, 19, 'the renewed client kept its count of 1, so 19 more guesses fit');
      clockOffsetMs = base;
    }

    // an admin route on a Worker with no ADMIN_KEY is a 503 for everybody and is not counted as a wrong guess
    {
      const noAdminEnv = { EXPORT_RELAY_KV: makeKv(), ADMIN_KEY: '' };
      const probeIp = '198.51.100.45';
      for (let i = 0; i < 25; i++) {
        const x = await worker.fetch(new Request('https://relay.test/admin/keys', { headers: { 'X-Access-Key': 'try-' + i, 'CF-Connecting-IP': probeIp } }), noAdminEnv);
        assert.equal(x.status, 503, 'admin not configured: ' + i);
      }
      assert.equal(await openStatus('NAC111', 'try-x', probeIp), 401, 'none of that counted against the client');
      for (let i = 0; i < 19; i++) assert.equal(await openStatus('NAC' + String(120 + i), 'try-' + i, probeIp), 401);
      assert.equal(await openStatus('NAC150', 'try-y', probeIp), 429, 'the budget is a full 20 refused codes');
    }
  }

  // guest codes: only alphabet characters, no duplicates across 2000 generated
  const seen = new Set();
  for (let i = 0; i < 2000; i++) {
    const g = await (await call('POST', '/admin/keys?label=x' + i, { 'X-Access-Key': ADMIN })).json();
    assert.match(g.key, /^[A-HJ-NP-Z2-9-]{14}$/); assert.ok(!seen.has(g.key)); seen.add(g.key);
  }
  console.log('ALL WORKER TESTS PASSED');
}

const mode = process.argv[2];
if (mode === 'test') {
  await runTests();
} else if (mode === 'serve') {
  const port = Number(process.argv[3] || 8787);
  // --no-admin-key starts the relay with ADMIN_KEY unset, to exercise the 503 "admin not
  // configured" path the way a freshly deployed Worker without the secret behaves.
  const noAdminKey = process.argv.includes('--no-admin-key');
  if (noAdminKey) env.ADMIN_KEY = '';
  http.createServer(async (req, res) => {
    if (req.url.startsWith('/__test/advance')) {
      clockOffsetMs += Number(new URL(req.url, 'http://x').searchParams.get('ms') || 0);
      console.log(`${req.method} ${req.url} -> 200 (clock offset now ${clockOffsetMs} ms)`);
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('clock offset ' + clockOffsetMs);
      return;
    }
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = chunks.length ? Buffer.concat(chunks) : undefined;
    const request = new Request(`http://127.0.0.1:${port}${req.url}`, {
      method: req.method, headers: req.headers,
      body: ['GET', 'HEAD'].includes(req.method) ? undefined : body,
    });
    const response = await worker.fetch(request, env);
    console.log(`${req.method} ${req.url} -> ${response.status}`);
    res.writeHead(response.status, Object.fromEntries(response.headers));
    res.end(Buffer.from(await response.arrayBuffer()));
  }).listen(port, '127.0.0.1', () => console.log(`relay on ${port}, admin=${noAdminKey ? '(none)' : ADMIN}`));
} else {
  console.error('Usage: node tests/relay/harness.mjs test | serve <port> [--no-admin-key]');
  process.exit(2);
}
