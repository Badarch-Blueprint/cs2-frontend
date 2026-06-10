--
-- WeaponPaints catalog — Postgres schema for the cs2tournament DB.
-- ----------------------------------------------------------------------------
-- These tables are a READ-ONLY mirror of the skin/glove/agent/music/keychain/
-- sticker/collectible JSON shipped inside the Nereziel cs2-WeaponPaints
-- plugin (data/*_en.json). They exist so the NestJS backend / frontend can
-- render and pick items without having to read the game server's filesystem.
--
-- Per-player *selections* are NOT stored here — they live in MySQL, auto-
-- created by the plugin as wp_player_skins / wp_player_knife / wp_player_gloves
-- / wp_player_agents / wp_player_music / wp_player_pins.
--
-- Apply with:
--   psql -h 192.168.10.221 -p 5432 -U <user> -d cs2tournament -f schema.sql
--   psql -h 192.168.10.221 -p 5432 -U <user> -d cs2tournament -f seed.sql
--
-- seed.sql is regenerated via build_catalog.py when the plugin version bumps.
-- ----------------------------------------------------------------------------

BEGIN;

-- Paint/finish variants for every base weapon (e.g. "AK-47 | Searing Rage").
CREATE TABLE IF NOT EXISTS wp_catalog_skins (
    weapon_defindex INTEGER     NOT NULL,
    weapon_name     TEXT        NOT NULL,
    paint           INTEGER     NOT NULL,
    paint_name      TEXT        NOT NULL,
    image           TEXT,
    legacy_model    BOOLEAN     NOT NULL DEFAULT FALSE,
    PRIMARY KEY (weapon_defindex, paint)
);
CREATE INDEX IF NOT EXISTS ix_wp_catalog_skins_weapon_name
    ON wp_catalog_skins (weapon_name);

CREATE TABLE IF NOT EXISTS wp_catalog_gloves (
    weapon_defindex INTEGER NOT NULL,
    paint           INTEGER NOT NULL,
    paint_name      TEXT    NOT NULL,
    image           TEXT,
    PRIMARY KEY (weapon_defindex, paint)
);

-- agents_en.json: one row per team (2=T, 3=CT typically); surrogate id keeps
-- the row uniquely addressable even if the plugin ever ships duplicates.
CREATE TABLE IF NOT EXISTS wp_catalog_agents (
    id          SERIAL      PRIMARY KEY,
    team        SMALLINT    NOT NULL,
    model       TEXT,
    agent_name  TEXT        NOT NULL,
    image       TEXT
);
CREATE INDEX IF NOT EXISTS ix_wp_catalog_agents_team
    ON wp_catalog_agents (team);

CREATE TABLE IF NOT EXISTS wp_catalog_music (
    id      INTEGER PRIMARY KEY,
    name    TEXT    NOT NULL,
    image   TEXT
);

CREATE TABLE IF NOT EXISTS wp_catalog_keychains (
    id      INTEGER PRIMARY KEY,
    name    TEXT    NOT NULL,
    image   TEXT
);

CREATE TABLE IF NOT EXISTS wp_catalog_stickers (
    id      INTEGER PRIMARY KEY,
    name    TEXT    NOT NULL,
    image   TEXT
);

CREATE TABLE IF NOT EXISTS wp_catalog_collectibles (
    id      INTEGER PRIMARY KEY,
    name    TEXT    NOT NULL,
    image   TEXT
);

-- Bookkeeping: tracks which plugin build generated the seed currently loaded.
CREATE TABLE IF NOT EXISTS wp_catalog_version (
    build       TEXT        PRIMARY KEY,
    imported_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMIT;
