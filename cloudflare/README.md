# Cloudflare Worker: Export Pairing Relay

Backs Compare Against List... -> **Generate a Pairing Code...** (which opens the "Pair with
Old Machine" dialog). It lets `Export-InstalledApps.ps1` on a machine with no GUI access hand
its installed-apps export straight to a running Gr3ysUtilities.ps1 instance through a short
one-time code, with no file to save or JSON to copy-paste by hand.

The relay is **access-gated**: a pairing code only accepts an export after the GUI has opened
it with an access code - either the admin code (the `ADMIN_KEY` Worker secret) or a guest code
the admin created. The old machine's side needs no access code; it can only deliver to a code
that is already open, once. Without the gate, anyone who read the Worker URL out of the public
repo could write to the KV namespace.

Only a single short-lived entry per pairing is ever stored (the export: machine hostname plus
installed-software names), and it is deleted the moment it is read or after 10 minutes.

## Deploy (one-time setup)

1. [dash.cloudflare.com](https://dash.cloudflare.com) -> **Workers & Pages** -> **Create**
   -> **Create Worker**. Give it any name (e.g. `gr3y-export-relay`) -> **Deploy** (the
   default "Hello World" template is fine for now, it gets replaced next).
2. **Edit code** -> delete everything -> paste in the contents of
   [`export-relay-worker.js`](export-relay-worker.js) from this folder -> **Deploy**.
   (Check the pasted code ends correctly and the editor shows 0 errors before Deploy - a
   truncated paste shows "1 error".)
3. **Workers & Pages** -> **KV** -> **Create a namespace** -> name it anything (e.g.
   `export-relay`) -> **Add**.
4. Back on the Worker -> **Settings** -> **Variables and Secrets** -> **KV Namespace
   Bindings** -> **Add binding**: variable name `EXPORT_RELAY_KV`, value = the namespace
   you just created -> **Deploy**.
5. Same page -> **Variables and Secrets** -> **Add** -> Type **Secret** -> Variable name
   `ADMIN_KEY` -> Value = a strong random string of **16 characters or more** -> **Deploy**.
   A secret shorter than 16 characters disables the admin routes (so a weak admin code can't
   be set by accident). Generate one without displaying it, for example in PowerShell:
   ```
   $b = New-Object byte[] 24
   [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
   Set-Clipboard ([Convert]::ToBase64String($b))
   ```
   Paste it into the secret field and your password manager; never paste it into a chat or
   a log.
6. The Worker's `*.workers.dev` URL (shown at the top of its page) must match the
   `$RelayUrl` default in `Export-InstalledApps.ps1` and `$script:ExportRelayUrl` in
   `Gr3ysUtilities.ps1` - keep both in sync. No custom domain or DNS change is needed.

## Updating an already-deployed Worker

Edit code -> replace everything with the new `export-relay-worker.js` -> **Deploy**. If you
are moving from the old (ungated) Worker to this one, **add the `ADMIN_KEY` secret first**
(step 5), then paste the new code: with the secret already present the gate works immediately,
and the old code simply ignores the secret in the meantime. The reverse order fails closed -
every `/open` is `401` until the secret exists.

Deploy order relative to the app: ship the updated **GUI and export script first**, then this
Worker. A new GUI against the old Worker degrades cleanly (it detects the old Worker and says
so); the old GUI against the new Worker would just sit waiting. See the project handoff for
the full rollout.

**Checking which Worker is live (no key needed):** `curl -sI https://<your-worker>/admin/keys`
answers `401` on both gated generations, but only this one adds the header
`X-Relay-Features: expiry,custom-codes,rename,brake`.

**Moving from the gated Worker that has no expiry to this one:** nothing to configure - no new
secret or binding. Existing random guest codes keep working and never expire until you give
them an expiry. One thing to check afterwards: a guest code you added by hand in the KV
dashboard that is **under 8 characters** (the old instructions allowed 6-7) is refused from now
on unless it carries an `expires` within a day; the Manage list shows it as Expired - fix it
with **Edit Code...** (give it an expiry) or replace it with a code of 8 or more characters.
A new GUI against the older Worker makes **New Code** say the relay is too old and creates
nothing (it removes the random code the older Worker made); rolling the Worker back re-enables
expired and short codes, because the older code ignores `expires`.

**Rollback:** Worker page -> **Deployments** -> three-dot menu on a previous version ->
**Rollback** (the last 100 versions are available). A rollback can be refused if a binding was
added or changed between versions - adding the `ADMIN_KEY` secret / KV binding may block a
rollback to a version from before it. The dependable fallback is to paste the previous code
(the old ungated Worker source is in git history) back into Edit code.

## Routes

Pairing:

| Route | Header | Result |
| --- | --- | --- |
| `POST /open?code=XXXXXX` | `X-Access-Key`: admin or guest code | `200 {"session","label"}` and holds the code open 10 min; `401` code unknown, switched off or expired; `409` code already open; `429` too many refused codes from this connection (see *Wrong-code brake*; the admin code is never blocked) |
| `POST /submit?code=XXXXXX` | none (the old machine needs no key) | `200` stored; `404` nothing is waiting for that code; `409` already sent; `413` body over 1 MB; `400` body missing |
| `GET /poll?code=XXXXXX` | `X-Session` from `/open` | `200` the export (once, then deleted); `404` nothing yet; `401` wrong/missing session once an export exists |
| `POST /close?code=XXXXXX` | `X-Session` | drops the slot and export (the GUI calls it on Cancel/close). Always `200`. |
| any `?code=` not 6-10 chars A-Z0-9 | - | `400` |

Admin (header `X-Access-Key` = the `ADMIN_KEY` secret):

| Route | Result |
| --- | --- |
| `GET /admin/keys` | list guest codes as JSON `[{key,custom,label,enabled,created,expires,expired}]` (`expires` is epoch milliseconds or `null`; `expired` is decided on the server's clock) |
| `POST /admin/keys?label=Name[&hours=N][&code=TEXT]` | create a guest code. Without `code` a random one is made, shown as `XXXX-XXXX-XXXX`. `code=TEXT` picks it yourself: 4-32 letters or digits, any case, spaces and dashes ignored. `hours=N` makes it expire N hours from now (0.02 to 8760; absent, `0` or `never` = no expiry). `409` if the code is taken |
| `POST /admin/keys/<CODE>/expiry?hours=N` | set a new expiry, counted from now (`0` / `never` removes it; `hours` is required) |
| `POST /admin/keys/<CODE>/rename[?to=TEXT][&hours=N]` | change the code on the fly: the same guest (label, on/off, created) under a new code, and the old code stops working. No `to` = a random new code; no `hours` = keep the current expiry. `503` with "BOTH work" means the new code was saved but the old one could not be removed - delete the old one |
| `POST /admin/keys/<CODE>/disable` or `/enable` | switch a guest code off / on |
| `DELETE /admin/keys/<CODE>` | delete a guest code for good |

Admin routes return `503` when `ADMIN_KEY` is unset or shorter than 16 characters, and `401`
when a key is supplied but wrong. A hand-added guest key (created directly in the KV dashboard)
must be stored under `guest:<CODE>` where `<CODE>` is upper-case letters and digits, 4-32
characters, with a value like `{"label":"Name","enabled":true}`. A code under 8 characters must
also carry `"expires"` (epoch milliseconds) at most a day ahead, or the relay refuses it and the
list shows it as Expired (see *Short codes* below). A guest code cannot be the same as the admin
code - the relay refuses to create or rename one to it.

The app manages guest codes for you: Compare Against List... -> **Manage Access Codes...**
(create, copy, edit, switch off/on, delete). You only touch the dashboard for the one-time
setup and the `ADMIN_KEY` secret.

**Expiry and codes you choose.** A guest code can expire on its own: pick how long when you
create it, or change it later with **Edit Code...** (which can also change the code text, so a
throwaway code like `9989` can be rotated every day). The relay refuses an expired code exactly
like a switched-off one, but keeps it listed as *Expired* for a week so you can extend or delete
it, then Workers KV removes it. Codes that existed before this feature never expire until you
give them an expiry.

**Short codes must be short-lived.** A code under 8 characters can be guessed (a 4-digit code has
10,000 possibilities and the relay's address is public), so the relay only accepts one with an
expiry of at most 24 hours. Use 8 or more characters for anything longer-lived. The two numbers
are `WEAK_CODE_LENGTH` and `WEAK_CODE_MAX_HOURS` at the top of the Worker. The rule is checked
when a code is saved **and** when it is used, so a short code added by hand with no expiry (or
one a month away) is simply not accepted.

**Wrong-code brake.** The relay counts the access codes it refuses, per connection - an unknown,
a switched-off and an expired code are refused and counted alike, so a caller cannot tell them
apart. After 20 in 10 minutes that connection gets `429` (with `Retry-After`) until the window
ends, and a locked-out connection costs no KV reads. A guess is counted the moment it arrives
and handed back when the code turns out to be good, so a burst of parallel guesses cannot get
past the limit (the price: more than 20 simultaneous requests from one address are limited too,
even with a good code). An IPv6 connection is counted by its /64. **The admin code is never
blocked**, so the owner can always manage codes - even from a shared address (hotel Wi-Fi, an
office, a phone carrier) where someone else's wrong guesses count against everyone. The price:
a locked-out address can still keep guessing the admin code (it only costs the attacker a 429
per wrong try), so `ADMIN_KEY` must be long and random - 32 characters from the helper, not a
phrase (the Worker only insists on 16). A request
with no key at all (the app's version probe) is never counted. The count is kept in the Worker's
memory, not KV (a counter written on every guess would let an attacker burn the daily write
quota), and Cloudflare runs several copies of a Worker, so this slows guessing rather than
stopping it - which is why short codes must expire.

**What the relay cannot do.** On the free plan anyone who knows the relay's address can use up
the daily KV quotas with plain requests (each wrong guess is a read; a valid code opens a slot,
which is a write). Cloudflare's own rate-limiting features could cut that down but not rule it
out (WAF rate-limiting rules need a domain you own; the Workers Rate Limiting binding counts
per location and only approximately), and none is set up here. The 8-character rule looks at length only, so `12345678` may
never expire: choose codes that are not guessable. A short code that is extended 24 hours at a
time stays alive - the rule is per setting, not a lifetime cap. KV has no compare-and-set, so two
admin requests made at the same instant (a script - the app does one thing at a time) can
overwrite each other. Rolling the Worker back to an older version re-enables expired and short
codes, because the old code ignores `expires`.

## Admin usage from PowerShell (optional)

If you ever want to manage codes without the GUI, keep the admin key in an environment
variable so it is not typed on screen:

```
$h = @{ 'X-Access-Key' = $env:GR3Y_RELAY_ADMIN_KEY }
$base = 'https://gr3y-export-relay.gr3y-b8f.workers.dev'
Invoke-RestMethod "$base/admin/keys" -Headers $h                                  # list
Invoke-RestMethod "$base/admin/keys?label=Mike" -Method Post -Headers $h          # create (random code, never expires)
Invoke-RestMethod "$base/admin/keys?label=Test&hours=1&code=9989" -Method Post -Headers $h   # a 4-digit code that lasts 1 hour
Invoke-RestMethod "$base/admin/keys/9989/rename?to=77AB3&hours=1" -Method Post -Headers $h   # change the code, restart the hour
Invoke-RestMethod "$base/admin/keys/ABCD1234EFGH/expiry?hours=24" -Method Post -Headers $h   # expire in a day
Invoke-RestMethod "$base/admin/keys/ABCD1234EFGH/disable" -Method Post -Headers $h # switch off
Invoke-RestMethod "$base/admin/keys/ABCD1234EFGH" -Method Delete -Headers $h       # delete
```

## How it works

- The GUI probes the relay (a no-key `GET /admin/keys`: `401`/`503` means this gated Worker,
  `400` means the old ungated one), asks for the access code, then `POST /open?code=` with
  `X-Access-Key`. The relay stores `slot:<code>` = `{session,label}` and returns the session.
- `Export-InstalledApps.ps1 -Code <code>` does `POST /submit?code=` (no key). The relay
  accepts it only if a slot is open, stores `export:<code>` = `{session,data}`, and refuses a
  second submit.
- The GUI polls `GET /poll?code=` with the `X-Session`. The first match returns the export and
  deletes both KV entries - a code is claimed exactly once. Entries no one claims expire on
  their own (the export is given the slot's remaining lifetime, never more).
- Guest codes live in KV as `guest:<CODE>` = `{label,enabled,created,expires?,custom?}` and are
  checked on every `/open`. Switching one off, deleting it or letting it expire blocks new
  pairings with it (a pairing that is already open finishes normally).

## Limits and timing (Cloudflare KV, free plan)

- Writes are **eventually consistent**: a just-opened code, a new guest code, or a switched-off
  code can take up to ~60 seconds (or more) to be visible at other Cloudflare locations, and
  "not found" reads are cached too. That is why the export script retries, the GUI says data
  "can take up to a minute to appear", and the Manage dialog says changes take up to a minute.
- Free-plan budget: 100,000 reads, 1,000 writes, 1,000 deletes and 1,000 list requests per
  day. Each `/open` is one write; a 3-5 second poll is ~120-200 reads per pairing. If writes
  are ever exhausted, `/open` and creating/switching codes fail until the daily reset, but
  **DELETE still works** (a separate quota) - so deleting a code is the emergency revoke.
- `ADMIN_KEY` is a Worker secret, never in the repo. The relay URL is public by design.
