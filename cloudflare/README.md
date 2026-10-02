# Cloudflare Worker: Export Pairing Relay

Backs the "Pair with Old Machine..." option in Compare Against List... - lets
`Export-InstalledApps.ps1` on a machine with no GUI access hand its export straight to a
running Gr3ysUtilities.ps1 instance via a short one-time code, with no file to save or
JSON to copy-paste by hand.

## Deploy (one-time setup)

1. [dash.cloudflare.com](https://dash.cloudflare.com) -> **Workers & Pages** -> **Create**
   -> **Create Worker**. Give it any name (e.g. `gr3y-export-relay`) -> **Deploy** (the
   default "Hello World" template is fine for now, it gets replaced next).
2. **Edit code** -> delete everything -> paste in the contents of
   [`export-relay-worker.js`](export-relay-worker.js) from this folder -> **Deploy**.
3. **Workers & Pages** -> **KV** -> **Create a namespace** -> name it anything (e.g.
   `export-relay`) -> **Add**.
4. Back on the Worker -> **Settings** -> **Variables and Secrets** -> **KV Namespace
   Bindings** -> **Add binding**: variable name `EXPORT_RELAY_KV`, value = the namespace
   you just created -> **Deploy**.
5. Copy the Worker's `*.workers.dev` URL (shown at the top of the Worker's page) and give
   it to whoever's updating `Export-InstalledApps.ps1`'s and `Gr3ysUtilities.ps1`'s
   `$RelayUrl`/`$script:ExportRelayUrl` default - no custom domain or DNS changes needed.

## How it works

- The GUI generates a short code (e.g. `7XQK2P`) and starts polling
  `GET /poll?code=7XQK2P` every few seconds.
- `Export-InstalledApps.ps1 -Code 7XQK2P` does one `POST /submit?code=7XQK2P` with the
  export JSON as the body.
- The next successful poll gets that JSON back and the KV entry is deleted immediately -
  a code can be claimed exactly once. Entries no one ever polls for expire on their own
  after 10 minutes (set via `expirationTtl` in the Worker).
- Nothing is logged or stored anywhere beyond that single short-lived KV entry.
