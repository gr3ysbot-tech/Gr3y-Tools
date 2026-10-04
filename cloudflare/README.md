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

**Rollback:** Worker page -> **Deployments** -> three-dot menu on a previous version ->
**Rollback** (the last 100 versions are available). A rollback can be refused if a binding was
added or changed between versions - adding the `ADMIN_KEY` secret / KV binding may block a
rollback to a version from before it. The dependable fallback is to paste the previous code
(the old ungated Worker source is in git history) back into Edit code.

## Routes

Pairing:

| Route | Header | Result |
| --- | --- | --- |
| `POST /open?code=XXXXXX` | `X-Access-Key`: admin or guest code | `200 {"session","label"}` and holds the code open 10 min; `401` code unknown/off; `409` code already open |
| `POST /submit?code=XXXXXX` | none (the old machine needs no key) | `200` stored; `404` nothing is waiting for that code; `409` already sent; `413` body over 1 MB; `400` body missing |
| `GET /poll?code=XXXXXX` | `X-Session` from `/open` | `200` the export (once, then deleted); `404` nothing yet; `401` wrong/missing session once an export exists |
| `POST /close?code=XXXXXX` | `X-Session` | drops the slot and export (the GUI calls it on Cancel/close). Always `200`. |
| any `?code=` not 6-10 chars A-Z0-9 | - | `400` |

Admin (header `X-Access-Key` = the `ADMIN_KEY` secret):

| Route | Result |
| --- | --- |
| `GET /admin/keys` | list guest codes as JSON `[{key,label,enabled,created}]` |
| `POST /admin/keys?label=Name` | create a guest code, returns it as `XXXX-XXXX-XXXX` |
| `POST /admin/keys/<CODE>/disable` or `/enable` | switch a guest code off / on |
| `DELETE /admin/keys/<CODE>` | delete a guest code for good |

Admin routes return `503` when `ADMIN_KEY` is unset or shorter than 16 characters, and `401`
when a key is supplied but wrong. A hand-added guest key (created directly in the KV dashboard)
must be stored under `guest:<CODE>` where `<CODE>` is upper-case letters and digits, 6-32
characters, with a value like `{"label":"Name","enabled":true}`.

The app manages guest codes for you: Compare Against List... -> **Manage Access Codes...**
(create, copy, switch off/on, delete). You only touch the dashboard for the one-time setup
and the `ADMIN_KEY` secret.

## Admin usage from PowerShell (optional)

If you ever want to manage codes without the GUI, keep the admin key in an environment
variable so it is not typed on screen:

```
$h = @{ 'X-Access-Key' = $env:GR3Y_RELAY_ADMIN_KEY }
$base = 'https://gr3y-export-relay.gr3y-b8f.workers.dev'
Invoke-RestMethod "$base/admin/keys" -Headers $h                                  # list
Invoke-RestMethod "$base/admin/keys?label=Mike" -Method Post -Headers $h          # create
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
- Guest codes live in KV as `guest:<CODE>` and are checked on every `/open`. Switching one off
  or deleting it blocks new pairings with it.

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
