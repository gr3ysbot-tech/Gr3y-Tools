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
 *                              -> 401 access code unknown/turned off, 409 code already open
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
 *   POST   /admin/keys?label=Name       create a guest code
 *   POST   /admin/keys/<CODE>/disable   turn a guest code off
 *   POST   /admin/keys/<CODE>/enable    turn it back on
 *   DELETE /admin/keys/<CODE>           delete it for good
 *
 * Any uncaught storage error becomes a 503 (not an opaque runtime crash), so the clients
 * can show "try again" instead of a Cloudflare error page.
 */

const CODE_PATTERN = /^[A-Za-z0-9]{6,10}$/; // tested BEFORE toUpperCase, so U+017F etc. can't alias to A-Z
const TTL_SECONDS = 600; // 10 minutes - matches the GUI's own polling timeout
const MIN_TTL_SECONDS = 60; // Cloudflare KV's minimum expirationTtl
const MAX_BODY_BYTES = 1024 * 1024; // 1MB - generous for an installed-apps export, not open-ended
const MIN_ADMIN_KEY_LENGTH = 16;
// Same unambiguous alphabet as the GUI's pairing codes (no 0/O, 1/I/L) - guest codes get
// read over the phone and typed by hand too.
const GUEST_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const GUEST_KEY_LENGTH = 12;
const GUEST_PREFIX = 'guest:';

// Every response carries these: no-store because bodies hold exports, guest codes and
// sessions that must never be cached by a proxy; nosniff as routine hardening.
const COMMON_HEADERS = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };

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

// {label, role} for an accepted access code, or null.
async function checkAccess(request, env) {
  if (await isAdmin(request, env)) return { label: 'admin', role: 'admin' };
  const key = normalizeGuestKey(request.headers.get('X-Access-Key'));
  // Not just GUEST_KEY_LENGTH - a guest code added by hand in the KV dashboard can be
  // any reasonable length.
  if (key.length < 6 || key.length > 32) return null;
  const raw = await env.EXPORT_RELAY_KV.get(GUEST_PREFIX + key);
  const rec = raw === null ? null : parseRecord(raw);
  // Strict === true, so a hand-edited record with enabled:"false" (a string) is OFF.
  return rec && rec.enabled === true ? { label: String(rec.label || 'guest'), role: 'guest' } : null;
}

function guestView(key, rec) {
  return { key: formatGuestKey(key), label: String(rec.label ?? ''), enabled: rec.enabled === true, created: String(rec.created ?? '') };
}

async function handleAdmin(request, env, url, path) {
  // Distinguish "admin not set up" (503) from "wrong key" (401), so the owner isn't left
  // guessing when the secret is missing or too short.
  if (!adminConfigured(env)) return text('Admin access is not configured (ADMIN_KEY missing or under 16 characters)', 503);
  if (!(await isAdmin(request, env))) return text('Admin access code required', 401);
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
      const label = (url.searchParams.get('label') || '').trim().slice(0, 60);
      if (!label) return text('Give the code a label, e.g. ?label=Mike', 400);
      const key = newGuestKey();
      const rec = { label, enabled: true, created: new Date().toISOString().slice(0, 10) };
      await kv.put(GUEST_PREFIX + key, JSON.stringify(rec), { metadata: rec });
      return json(guestView(key, rec));
    }
    return text('Method not allowed', 405);
  }

  // /admin/keys/<CODE> or /admin/keys/<CODE>/enable|disable
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
    await kv.put(kvKey, JSON.stringify(rec), { metadata: rec });
    return json(guestView(key, rec));
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
    const access = await checkAccess(request, env);
    if (!access) return text('Access code not accepted', 401);
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
