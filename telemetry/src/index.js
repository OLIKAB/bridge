// Bridge's usage endpoint: counts installs from one anonymous ping a day (Sources/Shared/UsagePing.swift).
//
//   POST /ping   {"id": "<uuid>", "version": "0.3.0", "os": "26.1", "arch": "arm64"}  -> 204
//   GET  /stats  Authorization: Bearer <STATS_TOKEN>                                 -> JSON overview
//   GET  /download  -> 302 to the newest release's .dmg, counted per day (the website's Download button)
//   GET  /latest    -> {"version": "0.3.0"} for the website
//
// Nothing but the body is stored: not the IP address, the user agent or the time of day.

const REPOSITORY = "OLIKAB/bridge";
const RELEASES_PAGE = `https://github.com/${REPOSITORY}/releases/latest`;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const VERSION = /^[0-9][0-9A-Za-z.\-]{0,19}$/;
const OS = /^[0-9]{1,3}\.[0-9]{1,3}$/;
const ARCHES = new Set(["arm64", "x86_64"]);

const today = () => new Date().toISOString().slice(0, 10);
const daysAgo = (n) => new Date(Date.now() - n * 86400000).toISOString().slice(0, 10);

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/ping" && request.method === "POST") return ping(request, env);
    if (url.pathname === "/stats" && request.method === "GET") return stats(request, env);
    if (url.pathname === "/download" && request.method === "GET") return download(env, ctx);
    if (url.pathname === "/latest" && request.method === "GET") return latestVersion(ctx);
    return new Response("Not found", { status: 404 });
  },

  async scheduled(_event, env) {
    await env.DB.prepare("DELETE FROM pings WHERE day < ?").bind(daysAgo(400)).run();
  },
};

async function ping(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return new Response("Bad JSON", { status: 400 });
  }
  const { id, version, os, arch } = body ?? {};
  if (!UUID.test(id) || !VERSION.test(version) || !OS.test(os) || !ARCHES.has(arch)) {
    return new Response("Bad ping", { status: 400 });
  }
  // A second ping the same day (a reinstall, a cleared default) updates the version rather than counting twice.
  await env.DB.prepare(
    "INSERT INTO pings (day, id, version, os, arch) VALUES (?, ?, ?, ?, ?) " +
      "ON CONFLICT (day, id) DO UPDATE SET version = excluded.version, os = excluded.os, arch = excluded.arch"
  )
    .bind(today(), id, version, os, arch)
    .run();
  return new Response(null, { status: 204 });
}

// The newest Bridge release, looked up on GitHub at most every ten minutes per Cloudflare location:
// the unauthenticated API allows 60 requests an hour per IP, and Workers share their outgoing IPs.
async function latestRelease(ctx) {
  const cache = caches.default;
  const key = new Request("https://cache.bridge-usage/latest-release");
  const cached = await cache.match(key);
  if (cached) return cached.json();
  let release = null;
  try {
    const response = await fetch(`https://api.github.com/repos/${REPOSITORY}/releases?per_page=20`, {
      headers: { Accept: "application/vnd.github+json", "User-Agent": "bridge-website" },
    });
    if (response.ok) {
      for (const r of await response.json()) {
        if (r.draft || r.prerelease) continue;
        const match = /^(?:bridge-)?v(\d.*)$/.exec(r.tag_name ?? "");
        if (!match) continue;
        const dmg = (r.assets ?? []).find((a) => a.name === `Bridge-${match[1]}.dmg`);
        release = { version: match[1], dmg: dmg?.browser_download_url ?? null };
        break;
      }
    }
  } catch {}
  if (release) {
    const toCache = Response.json(release, { headers: { "Cache-Control": "max-age=600" } });
    ctx.waitUntil(cache.put(key, toCache));
  }
  return release;
}

async function download(env, ctx) {
  const release = await latestRelease(ctx);
  ctx.waitUntil(
    env.DB.prepare("INSERT INTO downloads (day, count) VALUES (?, 1) ON CONFLICT (day) DO UPDATE SET count = count + 1")
      .bind(today())
      .run()
  );
  return Response.redirect(release?.dmg ?? RELEASES_PAGE, 302);
}

async function latestVersion(ctx) {
  const release = await latestRelease(ctx);
  return Response.json(
    { version: release?.version ?? null },
    { headers: { "Access-Control-Allow-Origin": "*", "Cache-Control": "public, max-age=600" } }
  );
}

async function stats(request, env) {
  const token = env.STATS_TOKEN;
  if (!token || request.headers.get("Authorization") !== `Bearer ${token}`) {
    return new Response("Unauthorized", { status: 401 });
  }
  const db = env.DB;
  const one = async (sql, ...args) => (await db.prepare(sql).bind(...args).first("n")) ?? 0;
  const all = async (sql, ...args) => (await db.prepare(sql).bind(...args).all()).results;

  const activeSince = (day) => one("SELECT COUNT(DISTINCT id) AS n FROM pings WHERE day >= ?", day);
  const latestPerInstall = (since) =>
    `SELECT p.* FROM pings p JOIN (SELECT id, MAX(day) AS day FROM pings WHERE day >= '${since}' GROUP BY id) l
       ON p.id = l.id AND p.day = l.day`;
  const since30 = daysAgo(29);

  const result = {
    today: today(),
    active: {
      day: await activeSince(today()),
      week: await activeSince(daysAgo(6)),
      month: await activeSince(since30),
    },
    installs: {
      total: await one("SELECT COUNT(DISTINCT id) AS n FROM pings"),
      newThisWeek: await one(
        "SELECT COUNT(*) AS n FROM (SELECT id, MIN(day) AS first FROM pings GROUP BY id) WHERE first >= ?",
        daysAgo(6)
      ),
    },
    downloads: {
      total: await one("SELECT COALESCE(SUM(count), 0) AS n FROM downloads"),
      week: await one("SELECT COALESCE(SUM(count), 0) AS n FROM downloads WHERE day >= ?", daysAgo(6)),
    },
    // Each install counted once, at the version it last reported, among those active in the last 30 days.
    versions: await all(
      `SELECT version, COUNT(*) AS installs FROM (${latestPerInstall(since30)}) GROUP BY version ORDER BY installs DESC`
    ),
    macOS: await all(
      `SELECT os, COUNT(*) AS installs FROM (${latestPerInstall(since30)}) GROUP BY os ORDER BY installs DESC`
    ),
    arch: await all(
      `SELECT arch, COUNT(*) AS installs FROM (${latestPerInstall(since30)}) GROUP BY arch ORDER BY installs DESC`
    ),
    daily: await all(
      `SELECT d.day, d.active, COALESCE(n.new, 0) AS new FROM
         (SELECT day, COUNT(*) AS active FROM pings WHERE day >= ? GROUP BY day) d
       LEFT JOIN
         (SELECT first AS day, COUNT(*) AS new FROM (SELECT id, MIN(day) AS first FROM pings GROUP BY id) GROUP BY first) n
       ON d.day = n.day
       ORDER BY d.day`,
      since30
    ),
  };
  return Response.json(result, { headers: { "Cache-Control": "no-store" } });
}
