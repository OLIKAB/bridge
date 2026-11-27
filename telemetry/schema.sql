-- One row per install per day it pinged. No IP address, no user data: the id is a random UUID
-- the app made on first launch.
CREATE TABLE IF NOT EXISTS pings (
    day TEXT NOT NULL,        -- yyyy-mm-dd, UTC
    id TEXT NOT NULL,         -- random install id
    version TEXT NOT NULL,    -- app version, e.g. 0.3.0
    os TEXT NOT NULL,         -- macOS major.minor, e.g. 26.1
    arch TEXT NOT NULL,       -- arm64 or x86_64
    PRIMARY KEY (day, id)
);

CREATE INDEX IF NOT EXISTS pings_id ON pings (id, day);

-- Downloads through bridge.olikab.com/download, counted per day. Nothing about who downloaded.
CREATE TABLE IF NOT EXISTS downloads (
    day TEXT NOT NULL PRIMARY KEY,  -- yyyy-mm-dd, UTC
    count INTEGER NOT NULL DEFAULT 0
);
