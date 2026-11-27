# Bridge usage endpoint

A Cloudflare Worker with a D1 database that counts how many copies of Bridge are in use. Bridge sends one ping a day (`Sources/Shared/UsagePing.swift`) with a random install id, its version, the macOS version and the CPU architecture. Nothing else is sent or stored: no IP address, no user agent, nothing about the user's repositories. Pings older than about 13 months are deleted daily.

## Deploy (once)

```sh
cd telemetry
npx wrangler login
npx wrangler d1 create bridge-usage          # put the printed database_id in wrangler.toml
npx wrangler d1 execute bridge-usage --remote --file schema.sql
npx wrangler secret put STATS_TOKEN          # a long random string, e.g. from `openssl rand -hex 32`
npx wrangler deploy                          # prints the URL, https://bridge-usage.<account>.workers.dev
```

Then set the endpoint in `build.sh` (`USAGE_PING_URL`, ending in `/ping`) and release a new version. Copies built without it send nothing.

## Read the numbers

```sh
BRIDGE_STATS_TOKEN=… ./scripts/usage-stats.sh
```

The script also reads `BRIDGE_STATS_TOKEN` and `BRIDGE_STATS_URL` from `.env` at the repository root. It shows active installs for the day, week and month, total and new installs, and versions, macOS versions and architectures among the installs active in the last 30 days, with a line per day.
