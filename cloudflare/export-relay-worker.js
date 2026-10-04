/**
 * Gr3y Tools - Export Pairing Relay
 *
 * A short-lived, one-time relay between Export-InstalledApps.ps1 (running on a machine
 * with no GUI access) and Gr3ysUtilities.ps1's "Pair with Old Machine" dialog (running
 * on the machine doing the comparison). Nothing is ever persisted beyond the KV entry's
 * own TTL - if the GUI isn't actively polling for a given code, the data it receives is
 * simply discarded once read (or expires unread).
 *
 * Access-gated: a pairing code only accepts an export after a GUI has "opened" it with
 * an access code - either the admin code (the ADMIN_KEY Worker secret) or a guest code
 * the admin created. Without that, anyone who read this file's URL out of the public repo
 * could write to the KV namespace. The old machine's side needs no access code; it can
 * only deliver to a code that's already open, once.
 *
 * Deploy: see cloudflare/README.md. Needs a KV namespace bound as EXPORT_RELAY_KV and a
 * secret named ADMIN_KEY (16+ characters - shorter values disable the admin routes, so a
 * weak admin code can't be set by accident).
 *
 * Pairing routes:
 *   POST /open?code=XXXXXX     header X-Access-Key: admin or guest code
 *                              -> 200 {"session","label"}, holds the code open 10 minutes
 *                              -> 401 access code unknown/turned off/expired, 409 code already
 *                                 open, 429 too many refused codes from this connection
 *   POST /submit?code=XXXXXX   body: the export JSON. No access code needed.
 *                              -> 200 OK, 404 nothing has that code open, 409 already sent,
 *                                 413 body over 1 MB, 400 body missing
 *   GET  /poll?code=XXXXXX     header X-Session: the session from /open
 *                              -> 200 the export (once, then deleted), 404 nothing yet,
 *                                 401 wrong session
 *   POST /close?code=XXXXXX    header X-Session: drops the slot+export (the GUI calls it
 *                              on Cancel/close). Always 200 (idempotent).
 *
 * Admin routes (header X-Access-Key: the ADMIN_KEY secret):
 *   GET    /admin/keys                  list guest codes
 *   POST   /admin/keys?label=Name[&hours=N][&code=TEXT]
 *                                       create a guest code; hours=N makes it expire N hours
 *                                       from now (0.02 to 8760; absent, 0 or never = no expiry).
 *                                       code=TEXT picks the code yourself (4-32 letters or
 *                                       digits, any case; spaces and dashes are ignored);
 *                                       without it a random 12-character code is made. A code
 *                                       under 8 characters is "short" and can be guessed, so it
 *                                       must expire within 24 hours.
 *   POST   /admin/keys/<CODE>/disable   turn a guest code off
 *   POST   /admin/keys/<CODE>/enable    turn it back on
 *   POST   /admin/keys/<CODE>/expiry?hours=N
 *                                       set (or, with 0 / never, remove) its expiry
 *   POST   /admin/keys/<CODE>/rename[?to=TEXT][&hours=N]
 *                                       change the code on the fly: the same guest (label,
 *                                       on/off, created) under a new code, and the old code
 *                                       stops working. to absent = a random new code; hours
 *                                       absent = keep the current expiry, given = replace it.
 *   DELETE /admin/keys/<CODE>           delete it for good
 *
 * A guest code is {label, enabled, created, expires?}: expires is epoch milliseconds, absent
 * = never. An expired code is refused by /open exactly like a switched-off one, but it stays
 * in the list as expired for a week (so the owner can see it, extend it, or delete it) and
 * then Workers KV removes it.
 *
 * Refused access codes are counted per client (its address, or its /64 for IPv6), in this
 * isolate's memory (not KV: a counter written on every wrong guess would let an attacker burn
 * the daily write quota), and a client over the limit gets 429 until the window ends. A guess
 * is counted the moment it arrives and handed back if the code turns out to be good, so a burst
 * of parallel guesses cannot slip past the limit. The admin code is never blocked. Isolates come
 * and go and are not shared, so this slows guessing rather than stopping it - which is why short
 * codes must also expire within a day. It does not protect the free plan's daily KV quotas: an
 * attacker can use those up with plain requests (Cloudflare's own rate-limiting features could cut
 * that down but not rule it out; none is set up here). And because the admin code is never
 * blocked, ADMIN_KEY must be long and random: a locked-out address can still guess it.
 *
 * Any uncaught storage error becomes a 503 (not an opaque runtime crash), so the clients
 * can show "try again" instead of a Cloudflare error page.
 */

const CODE_PATTERN = /^[A-Za-z0-9]{6,10}$/; // tested BEFORE toUpperCase, so U+017F etc. can't alias to A-Z
const TTL_SECONDS = 600; // 10 minutes - matches the GUI's own polling timeout
const MIN_TTL_SECONDS = 60; // Cloudflare KV's minimum expirationTtl
const KV_EXPIRATION_MARGIN_SECONDS = 30; // slack on top of that minimum for an absolute expiration
const MAX_BODY_BYTES = 1024 * 1024; // 1MB - generous for an installed-apps export, not open-ended
const MIN_ADMIN_KEY_LENGTH = 16;
// Same unambiguous alphabet as the GUI's pairing codes (no 0/O, 1/I/L) - guest codes get
// read over the phone and typed by hand too.
const GUEST_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const GUEST_KEY_LENGTH = 12;
const GUEST_PREFIX = 'guest:';
const MIN_EXPIRY_HOURS = 1 / 60; // one minute - anything shorter is a typo, not a plan
const MAX_EXPIRY_HOURS = 24 * 365; // a year; "never" covers anything longer
// How long an EXPIRED guest code stays listed (as expired) before Workers KV deletes it.
const EXPIRED_KEEP_SECONDS = 7 * 24 * 3600;
const MIN_CODE_LENGTH = 4; // shortest code the owner may choose
const MAX_CODE_LENGTH = 32;
const WEAK_CODE_LENGTH = 8; // under this a code is "short": guessable, so it must be short-lived
const WEAK_CODE_MAX_HOURS = 24;
const FAIL_LIMIT = 20; // refused access codes per client per window before a 429
const FAIL_WINDOW_MS = 10 * 60 * 1000;
const MAX_TRACKED_CLIENTS = 5000; // bounds the brake's memory; the oldest entries go first
const CLOCK_SLACK_MS = 5 * 60 * 1000; // tolerated clock difference between Worker machines
const INVALID_HOURS = 'Invalid hours - use a number from 0.02 (one minute) to 8760, or 0 / never for no expiry';

// Every response carries these: no-store because bodies hold exports, guest codes and
// sessions that must never be cached by a proxy; nosniff as routine hardening. X-Relay-Features
// says which generation of this Worker is deployed, so that can be checked from outside without
// a key (`curl -sI <relay>/admin/keys`); the earlier gated Worker sends no such header.
const COMMON_HEADERS = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'X-Relay-Features': 'expiry,custom-codes,rename,brake' };

function text(body, status) {
  return new Response(body, { status, headers: { 'Content-Type': 'text/plain; charset=utf-8', ...COMMON_HEADERS } });
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json; charset=utf-8', ...COMMON_HEADERS } });
}

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

// Guest codes are stored uppercase with no separators, so "abcd-efgh-jkmn",
// "ABCD EFGH JKMN" and "ABCDEFGHJKMN" all match the same code.
function normalizeGuestKey(raw) {
  return (raw || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
}

function formatGuestKey(key) {
  return (key.match(/.{1,4}/g) || []).join('-');
}

function newGuestKey() {
  // Rejection sampling: 256 isn't a multiple of 31, so a plain modulo would make the
  // first few letters slightly more likely. 248 = 31 * 8.
  const out = [];
  while (out.length < GUEST_KEY_LENGTH) {
    for (const b of crypto.getRandomValues(new Uint8Array(GUEST_KEY_LENGTH * 2))) {
      if (b < 248 && out.length < GUEST_KEY_LENGTH) out.push(GUEST_ALPHABET[b % 31]);
    }
  }
  return out.join('');
}

// Constant-time comparison via fixed-length digests, so response timing can't reveal how
// much of a guessed admin code or session was right.
async function sameSecret(a, b) {
  const enc = new TextEncoder();
  const [da, db] = await Promise.all([
    crypto.subtle.digest('SHA-256', enc.encode(a)),
    crypto.subtle.digest('SHA-256', enc.encode(b)),
  ]);
  const x = new Uint8Array(da);
  const y = new Uint8Array(db);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

function adminKey(env) {
  // Trim here, not just on the supplied side: a secret saved through the dashboard with a
  // trailing newline/space would otherwise never match and lock admin out silently.
  return (env.ADMIN_KEY || '').trim();
}

function adminConfigured(env) {
  return adminKey(env).length >= MIN_ADMIN_KEY_LENGTH;
}

// A chosen guest code must not be the admin code (typed in the Code box by mistake): /open and the
// admin routes compare the raw header with the secret, so such a "guest" would be the admin, and
// the list shows a code in capitals, i.e. most of the secret.
const ADMIN_CODE_CLASH = 'A guest code cannot be the same as the admin code';
function isAdminCodeText(normalizedCode, env) {
  return adminConfigured(env) && normalizedCode === normalizeGuestKey(adminKey(env));
}

async function isAdmin(request, env) {
  const supplied = (request.headers.get('X-Access-Key') || '').trim();
  const admin = adminKey(env);
  if (admin.length < MIN_ADMIN_KEY_LENGTH || !supplied) return false;
  return sameSecret(supplied, admin);
}

function parseRecord(raw) {
  try {
    const rec = JSON.parse(raw);
    return rec && typeof rec === 'object' ? rec : null;
  } catch {
    return null;
  }
}

// Best-effort brake on guessing: refused access codes per client, counted in memory (see the
// header comment). A request that carries no key at all (the GUI's version probe) is never
// counted or blocked, and neither is the admin code.
//
// Order matters. takeAttempt() runs BEFORE the first await of a request, so a burst of parallel
// guesses is counted as it arrives (counting after the KV read would let thousands of them
// through while the first one is still waiting); giveBackAttempt() returns the slot when the
// code turns out to be good, so only refused codes use the budget up.
const failures = new Map(); // client -> { count, windowEnd }; oldest entry first

// Who a request counts against: its source address. A client controls its whole IPv6 /64 (2^64
// addresses), so an IPv6 address is reduced to its /64 prefix; an IPv4-mapped IPv6 address counts
// as the IPv4 address it carries. Anything unrecognised is used as it is.
function clientId(request) {
  const ip = (request.headers.get('CF-Connecting-IP') || '').trim().toLowerCase();
  if (!ip) return 'unknown';
  if (!ip.includes(':')) return ip;
  const mapped = /^(?:0{0,4}:){2,5}ffff:(\d{1,3}(?:\.\d{1,3}){3})$/.exec(ip);
  if (mapped) return mapped[1];
  const halves = ip.split('::');
  if (halves.length > 2) return ip;
  const head = halves[0] ? halves[0].split(':') : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const fill = 8 - head.length - tail.length;
  if (halves.length === 1 ? head.length !== 8 : fill < 1) return ip;
  const groups = head.concat(new Array(halves.length === 2 ? fill : 0).fill('0'), tail);
  // An IPv4-mapped address written in hex groups (::ffff:cb00:7109) is its IPv4 address too.
  if (groups.slice(0, 5).every((g) => /^0+$/.test(g)) && groups[5] === 'ffff') {
    const hi = parseInt(groups[6], 16);
    const lo = parseInt(groups[7], 16);
    if (hi >= 0 && hi <= 0xffff && lo >= 0 && lo <= 0xffff) return (hi >> 8) + '.' + (hi & 255) + '.' + (lo >> 8) + '.' + (lo & 255);
  }
  return groups.slice(0, 4).map((g) => g.replace(/^0+(?=.)/, '')).join(':') + '::/64';
}

// Forget windows that have ended; if that is not enough, the oldest clients go.
function pruneClients(nowMs) {
  for (const [k, v] of failures) if (nowMs >= v.windowEnd) failures.delete(k);
  while (failures.size > MAX_TRACKED_CLIENTS) failures.delete(failures.keys().next().value);
}

// Reserve one attempt for a client: { ok: true }, or { ok: false, retryAfter } (seconds) when it
// is already over the limit for this window.
function takeAttempt(id, nowMs) {
  let f = failures.get(id);
  if (!f || nowMs >= f.windowEnd) {
    f = { count: 0, windowEnd: nowMs + FAIL_WINDOW_MS };
    failures.delete(id); // re-insert at the end, so the Map stays ordered oldest-first
    failures.set(id, f);
    if (failures.size > MAX_TRACKED_CLIENTS) pruneClients(nowMs);
  }
  if (f.count >= FAIL_LIMIT) return { ok: false, retryAfter: Math.max(1, Math.ceil((f.windowEnd - nowMs) / 1000)) };
  f.count++;
  return { ok: true, f };
}

// Hand a reserved attempt back - to the window entry it was taken from. A request that finishes
// after its window has ended (and been replaced, or the client forgotten) refunds the old entry,
// which changes nothing: the new window must not be credited for a slot it never gave out.
function giveBackAttempt(attempt) {
  if (attempt.f.count > 0) attempt.f.count--;
}

function tooMany(retryAfter) {
  return new Response('Too many wrong access codes from this connection - try again in a few minutes', {
    status: 429,
    headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Retry-After': String(retryAfter), ...COMMON_HEADERS },
  });
}

// Validates a code the owner typed: { code } (normalised) or { error }.
function parseCustomCode(raw) {
  const typed = (raw || '').trim();
  if (!/^[A-Za-z0-9 -]+$/.test(typed)) return { error: 'A code may contain only letters and digits (spaces and dashes are ignored)' };
  const code = normalizeGuestKey(typed);
  if (code.length < MIN_CODE_LENGTH) return { error: 'A code needs at least ' + MIN_CODE_LENGTH + ' letters or digits' };
  if (code.length > MAX_CODE_LENGTH) return { error: 'A code can be at most ' + MAX_CODE_LENGTH + ' letters or digits' };
  return { code };
}

// A short code can be guessed, so it must expire within a day. expiresAt is epoch ms or null
// (never). Returns an error message, or null when the pair is acceptable.
function weakCodeProblem(code, expiresAt, nowMs) {
  if (code.length >= WEAK_CODE_LENGTH) return null;
  if (expiresAt === null || expiresAt === undefined || expiresAt - nowMs > WEAK_CODE_MAX_HOURS * 3600 * 1000) {
    return 'A code under ' + WEAK_CODE_LENGTH + ' characters must expire within ' + WEAK_CODE_MAX_HOURS + ' hours (hours 0.02 to ' + WEAK_CODE_MAX_HOURS + ') - use a longer code for anything longer-lived';
  }
  return null;
}

// The same short-code rule, checked when a code is USED rather than when it is saved (weakCodeProblem
// does that): a short code with no usable expiry, or one more than a day away, is not accepted. So
// a short code added by hand in the KV dashboard cannot sidestep the rule. The slack covers a small
// clock difference between the machine that saved the code and the one that checks it.
function weakCodeUnbounded(code, rec, nowMs) {
  if (code.length >= WEAK_CODE_LENGTH) return false;
  const e = rec.expires;
  return !(typeof e === 'number' && Number.isFinite(e) && e - nowMs <= WEAK_CODE_MAX_HOURS * 3600 * 1000 + CLOCK_SLACK_MS);
}

// Epoch-ms expiry for a ?hours= value: null = never expires, a number = that moment,
// undefined = not a valid value. Blank, 0, "never" and "none" all mean no expiry.
function parseExpiry(raw, nowMs) {
  const s = (raw || '').trim().toLowerCase();
  if (s === '' || s === '0' || s === 'never' || s === 'none') return null;
  const hours = Number(s);
  if (!Number.isFinite(hours) || hours < MIN_EXPIRY_HOURS || hours > MAX_EXPIRY_HOURS) return undefined;
  return Math.round(nowMs + hours * 3600 * 1000);
}

// A guest record has expired when it carries an `expires` (epoch ms) that has passed. No
// field = never. A present-but-unusable value (a hand edit) counts as expired, the same way
// enabled:"false" counts as off: fail closed.
function guestExpired(rec, nowMs) {
  if (rec.expires === undefined || rec.expires === null) return false;
  return !(typeof rec.expires === 'number' && Number.isFinite(rec.expires) && nowMs < rec.expires);
}

// Writes a guest record (value + metadata). A record with an expiry also gets an absolute KV
// expiration a week after it, so a lapsed code stays listed as expired for a while and then
// removes itself. Every write of a guest record must come through here: a put without
// `expiration` silently clears the one already on the key.
async function putGuest(kv, kvKey, rec) {
  const opts = { metadata: rec };
  if (typeof rec.expires === 'number' && Number.isFinite(rec.expires)) {
    // KV needs an expiration at least 60 s ahead, even when re-saving a long-expired record. The
    // floor is taken from whole seconds, so it gets a margin: exactly "now + 60" can land just
    // under the minimum by the time KV checks it.
    opts.expiration = Math.max(nowSeconds() + MIN_TTL_SECONDS + KV_EXPIRATION_MARGIN_SECONDS, Math.floor(rec.expires / 1000) + EXPIRED_KEEP_SECONDS);
  }
  await kv.put(kvKey, JSON.stringify(rec), opts);
}

// { label, role } for an accepted access code, or { denied: true }. Unknown, switched-off and
// expired codes are all refused the same way - the caller must not be able to tell them apart.
async function checkAccess(request, env) {
  if (await isAdmin(request, env)) return { label: 'admin', role: 'admin' };
  const key = normalizeGuestKey(request.headers.get('X-Access-Key'));
  // Not just GUEST_KEY_LENGTH - a code chosen by the owner or added by hand in the KV
  // dashboard can be any reasonable length.
  if (key.length < MIN_CODE_LENGTH || key.length > MAX_CODE_LENGTH) return { denied: true };
  const raw = await env.EXPORT_RELAY_KV.get(GUEST_PREFIX + key);
  const rec = raw === null ? null : parseRecord(raw);
  const now = Date.now();
  // Strict === true, so a hand-edited record with enabled:"false" (a string) is OFF; and an
  // expired code is refused exactly like a switched-off one.
  return rec && rec.enabled === true && !guestExpired(rec, now) && !weakCodeUnbounded(key, rec, now)
    ? { label: String(rec.label || 'guest'), role: 'guest' }
    : { denied: true };
}

function guestView(key, rec) {
  const hasExpiry = typeof rec.expires === 'number' && Number.isFinite(rec.expires);
  const now = Date.now();
  return {
    // A code the owner chose is shown as typed (normalised), not regrouped into 4-letter blocks.
    key: rec.custom === true ? key : formatGuestKey(key),
    custom: rec.custom === true,
    label: String(rec.label ?? ''),
    enabled: rec.enabled === true,
    created: String(rec.created ?? ''),
    expires: hasExpiry ? rec.expires : null, // epoch ms, or null = never
    // Decided here, on the server's clock. A short code with no usable expiry (only possible when
    // it was added by hand) is listed as expired too, because /open refuses it - see weakCodeUnbounded.
    expired: guestExpired(rec, now) || weakCodeUnbounded(key, rec, now),
  };
}

async function handleAdmin(request, env, url, path) {
  // Distinguish "admin not set up" (503) from "wrong key" (401), so the owner isn't left
  // guessing when the secret is missing or too short. (With no secret there is nothing to
  // guess, so that case is not counted.)
  if (!adminConfigured(env)) return text('Admin access is not configured (ADMIN_KEY missing or under 16 characters)', 503);
  // Reserve the attempt before the first await (see the brake above). A request with no key -
  // the GUI's version probe - is not an attempt, and the admin code is never blocked.
  const supplied = (request.headers.get('X-Access-Key') || '').trim();
  const id = clientId(request);
  const attempt = supplied ? takeAttempt(id, Date.now()) : null;
  if (!(await isAdmin(request, env))) {
    if (attempt && !attempt.ok) return tooMany(attempt.retryAfter);
    return text('Admin access code required', 401);
  }
  if (attempt && attempt.ok) giveBackAttempt(attempt);
  const kv = env.EXPORT_RELAY_KV;

  if (path === '/admin/keys') {
    if (request.method === 'GET') {
      const keys = [];
      let cursor;
      do {
        const page = await kv.list({ prefix: GUEST_PREFIX, cursor });
        for (const k of page.keys) {
          const key = k.name.slice(GUEST_PREFIX.length);
          // Codes created here carry their record as metadata, so listing costs no extra
          // reads. One added by hand in the dashboard won't - read its value instead.
          let rec = k.metadata;
          if (!rec) rec = parseRecord(await kv.get(k.name)) || {};
          keys.push(guestView(key, rec));
        }
        cursor = page.list_complete ? undefined : page.cursor;
      } while (cursor);
      keys.sort((a, b) => a.label.localeCompare(b.label));
      return json(keys);
    }
    if (request.method === 'POST') {
      // 60 characters, counted as characters (not UTF-16 units, which could cut an emoji in half).
      const label = Array.from((url.searchParams.get('label') || '').trim()).slice(0, 60).join('');
      if (!label) return text('Give the code a label, e.g. ?label=Mike', 400);
      const now = Date.now();
      const expiresAt = parseExpiry(url.searchParams.get('hours'), now);
      if (expiresAt === undefined) return text(INVALID_HOURS, 400);
      const customRaw = url.searchParams.get('code');
      const custom = customRaw !== null && customRaw.trim() !== '';
      let key;
      if (custom) {
        const parsed = parseCustomCode(customRaw);
        if (parsed.error) return text(parsed.error, 400);
        key = parsed.code;
        if (isAdminCodeText(key, env)) return text(ADMIN_CODE_CLASH, 400);
        const problem = weakCodeProblem(key, expiresAt, now);
        if (problem) return text(problem, 400);
        if ((await kv.get(GUEST_PREFIX + key)) !== null) return text('That code is already in use', 409);
      } else {
        key = newGuestKey();
      }
      const rec = { label, enabled: true, created: new Date().toISOString().slice(0, 10) };
      if (custom) rec.custom = true;
      if (expiresAt !== null) rec.expires = expiresAt;
      await putGuest(kv, GUEST_PREFIX + key, rec);
      return json(guestView(key, rec));
    }
    return text('Method not allowed', 405);
  }

  // /admin/keys/<CODE> or /admin/keys/<CODE>/enable|disable|expiry|rename
  const [rawKey, action] = path.split('/').slice(3);
  let decoded;
  try {
    decoded = decodeURIComponent(rawKey || '');
  } catch {
    // A malformed %-sequence in the path would otherwise throw a URIError and 500.
    return text('Bad guest code', 400);
  }
  const key = normalizeGuestKey(decoded);
  if (!key) return text('Missing guest code', 400);
  if (key.length > 32) return text('Bad guest code', 400);
  const kvKey = GUEST_PREFIX + key;
  const raw = await kv.get(kvKey);
  if (raw === null) return text('No such guest code', 404);
  const rec = parseRecord(raw) || {};

  if (!action && request.method === 'DELETE') {
    await kv.delete(kvKey);
    return json({ ...guestView(key, rec), deleted: true });
  }
  if ((action === 'enable' || action === 'disable') && request.method === 'POST') {
    rec.enabled = action === 'enable';
    await putGuest(kv, kvKey, rec);
    return json(guestView(key, rec));
  }
  if (action === 'expiry' && request.method === 'POST') {
    // hours is required here, and must not be empty (unlike on create, where absent means
    // never): a forgotten parameter must not silently remove an expiry.
    const rawHours = url.searchParams.get('hours');
    if (rawHours === null || rawHours.trim() === '') return text('Give hours, e.g. ?hours=24 (0 or never = no expiry)', 400);
    const now = Date.now();
    const expiresAt = parseExpiry(rawHours, now);
    if (expiresAt === undefined) return text(INVALID_HOURS, 400);
    const problem = weakCodeProblem(key, expiresAt, now);
    if (problem) return text(problem, 400);
    if (expiresAt === null) delete rec.expires;
    else rec.expires = expiresAt;
    await putGuest(kv, kvKey, rec);
    return json(guestView(key, rec));
  }
  if (action === 'rename' && request.method === 'POST') {
    const now = Date.now();
    const toRaw = url.searchParams.get('to');
    const custom = toRaw !== null && toRaw.trim() !== '';
    let newKey;
    if (custom) {
      const parsed = parseCustomCode(toRaw);
      if (parsed.error) return text(parsed.error, 400);
      newKey = parsed.code;
      if (newKey === key) return text('That is already this code', 400);
      if (isAdminCodeText(newKey, env)) return text(ADMIN_CODE_CLASH, 400);
    } else {
      newKey = newGuestKey();
    }
    // Expiry: absent = keep what the code has (a record whose expires is unusable must be
    // given hours, rather than silently becoming never-expires); given = replace it.
    let expiresAt;
    if (url.searchParams.has('hours')) {
      const rawHours = url.searchParams.get('hours');
      if (rawHours.trim() === '') return text('Give hours, e.g. ?hours=24 (0 or never = no expiry)', 400);
      expiresAt = parseExpiry(rawHours, now);
      if (expiresAt === undefined) return text(INVALID_HOURS, 400);
    } else if (rec.expires === undefined || rec.expires === null) {
      expiresAt = null;
    } else if (typeof rec.expires === 'number' && Number.isFinite(rec.expires)) {
      expiresAt = rec.expires;
    } else {
      return text('This code has an unusable expiry - give hours', 400);
    }
    const problem = weakCodeProblem(newKey, expiresAt, now);
    if (problem) return text(problem, 400);
    if ((await kv.get(GUEST_PREFIX + newKey)) !== null) return text('That code is already in use', 409);
    // Same guest under the new code: label, on/off and created carry over. New first, then
    // the old one goes - a failure in between leaves both working, never neither.
    const next = { ...rec };
    if (custom) next.custom = true;
    else delete next.custom;
    if (expiresAt === null) delete next.expires;
    else next.expires = expiresAt;
    await putGuest(kv, GUEST_PREFIX + newKey, next);
    try {
      await kv.delete(kvKey);
    } catch {
      // The new code is saved; only the old one could not be removed. Say so plainly: the generic
      // "try again later" would end in a 409 on the retry (the new code now exists), with the code
      // being rotated away - maybe a leaked one - still working.
      return text('The new code was saved but the old one could not be removed, so BOTH work for now - refresh the list and delete the old code', 503);
    }
    return json(guestView(newKey, next));
  }
  return text('Not found', 404);
}

async function handle(request, env) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, '') || '/';

  if (path === '/admin/keys' || path.startsWith('/admin/keys/')) {
    return handleAdmin(request, env, url, path);
  }

  const rawCode = url.searchParams.get('code') || '';
  // Validate as ASCII before upper-casing: toUpperCase() folds some Unicode (U+017F -> S,
  // U+00DF -> SS), which would let a non-ASCII "code" pass and alias onto a real one.
  if (!CODE_PATTERN.test(rawCode)) {
    return text('Invalid or missing code', 400);
  }
  const code = rawCode.toUpperCase();
  const kv = env.EXPORT_RELAY_KV;
  const slotKey = `slot:${code}`;
  const exportKey = `export:${code}`;

  if (path === '/open' && request.method === 'POST') {
    const supplied = (request.headers.get('X-Access-Key') || '').trim();
    const id = clientId(request);
    // Reserve the attempt before the first await, and hand it back if the code is good (see the
    // brake above). A client already over the limit is turned away without a KV read - except
    // with the admin code, which is never blocked. Every refused code counts the same, whether
    // it is unknown, switched off or expired, so the 429 gives nothing away about which it was.
    const attempt = supplied ? takeAttempt(id, Date.now()) : null;
    if (attempt && !attempt.ok && !(await isAdmin(request, env))) return tooMany(attempt.retryAfter);
    let access;
    try {
      access = await checkAccess(request, env);
    } catch (err) {
      // A storage error says nothing about the code: hand the slot back, or an outage would lock
      // out people whose codes are fine.
      if (attempt && attempt.ok) giveBackAttempt(attempt);
      throw err;
    }
    if (access.denied) return text('Access code not accepted', 401);
    if (attempt && attempt.ok) giveBackAttempt(attempt);
    // Another app instance already has this exact code open - the GUI picks a new one
    // and retries rather than taking over someone else's session.
    if ((await kv.get(slotKey)) !== null) return text('Code already in use', 409);
    const session = crypto.randomUUID();
    const expiresAt = nowSeconds() + TTL_SECONDS;
    await kv.put(slotKey, JSON.stringify({ session, label: access.label, expiresAt }), { expirationTtl: TTL_SECONDS });
    return json({ session, label: access.label });
  }

  if (path === '/submit' && request.method === 'POST') {
    const slot = parseRecord((await kv.get(slotKey)) ?? '');
    if (!slot) return text('No app is waiting for this code', 404);
    if ((await kv.get(exportKey)) !== null) return text('Something was already sent for this code', 409);
    // Reject an oversize body before reading it, when the length is declared.
    const declared = Number(request.headers.get('Content-Length') || '0');
    if (declared > MAX_BODY_BYTES) return text('Body too large', 413);
    const buf = await request.arrayBuffer();
    if (buf.byteLength === 0) return text('Body missing', 400);
    // Count real bytes, not UTF-16 units, so multi-byte content can't slip past the cap.
    if (buf.byteLength > MAX_BODY_BYTES) return text('Body too large', 413);
    const body = new TextDecoder().decode(buf);
    // Tie the export's lifetime to the slot's, so it can't outlive the dialog that opened
    // the code. Clamp to KV's 60 s minimum.
    const remaining = (slot.expiresAt || 0) - nowSeconds();
    const ttl = Math.max(MIN_TTL_SECONDS, remaining);
    // The session rides along with the export, so a poll only needs one read to both
    // find the data and check it's asking on behalf of the app that opened the code.
    await kv.put(exportKey, JSON.stringify({ session: slot.session, data: body }), { expirationTtl: ttl });
    return text('OK', 200);
  }

  if (path === '/poll' && request.method === 'GET') {
    const raw = await kv.get(exportKey);
    if (raw === null) return text('Not found', 404);
    const entry = parseRecord(raw);
    const session = request.headers.get('X-Session') || '';
    if (!entry || !session || !(await sameSecret(session, entry.session || ''))) {
      return text('Wrong session', 401);
    }
    // Claim it - a poll that successfully reads data also consumes it, so a second
    // poll for the same code (a retry after a slow response) gets 404 instead of
    // silently handing out the same export twice.
    await Promise.all([kv.delete(exportKey), kv.delete(slotKey)]);
    return new Response(entry.data, { status: 200, headers: { 'Content-Type': 'application/json; charset=utf-8', ...COMMON_HEADERS } });
  }

  if (path === '/close' && request.method === 'POST') {
    // The GUI calls this on Cancel/close so the old machine can't submit into a dialog
    // that is gone, and so the export doesn't linger. Idempotent: only the holder of the
    // session can drop the slot, but a miss is still a 200 so Cancel never shows an error.
    const slot = parseRecord((await kv.get(slotKey)) ?? '');
    const session = request.headers.get('X-Session') || '';
    if (slot && session && (await sameSecret(session, slot.session || ''))) {
      await Promise.all([kv.delete(slotKey), kv.delete(exportKey)]);
    }
    return text('OK', 200);
  }

  return text('Not found', 404);
}

export default {
  async fetch(request, env) {
    try {
      return await handle(request, env);
    } catch (err) {
      // KV quota exhaustion, a 429 same-key write, or any transient storage error lands
      // here instead of as an opaque Cloudflare 1101 page, so the clients can say "try
      // again later" and the owner knows it's the relay, not their input.
      return new Response('Relay storage is temporarily unavailable - try again later', {
        status: 503,
        headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Retry-After': '30', ...COMMON_HEADERS },
      });
    }
  },
};
