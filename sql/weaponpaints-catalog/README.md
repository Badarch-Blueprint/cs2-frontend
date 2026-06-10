# WeaponPaints Postgres Catalog

Read-only mirror of the skin / glove / agent / music / keychain / sticker /
collectible JSON bundled with the
[Nereziel cs2-WeaponPaints](https://github.com/Nereziel/cs2-WeaponPaints)
plugin, loaded into the `cs2tournament` Postgres at
`192.168.10.221:5432` so the NestJS backend and the admin frontend can render
skin pickers without reading the game server filesystem.

> Per-player *selections* (`wp_player_skins`, `wp_player_knife`, …) live in
> the plugin's **MySQL** database (see `docker-compose.yml` →
> `weaponpaints-mysql`). This Postgres catalog is catalog data only.

## Layout

| File                | Purpose                                                                 |
|---------------------|-------------------------------------------------------------------------|
| `schema.sql`        | DDL for the 7 catalog tables + `wp_catalog_version` bookkeeping         |
| `build_catalog.py`  | Downloads the pinned plugin release and regenerates `seed.sql`          |
| `seed.sql`          | Committed output of `build_catalog.py` (re-runnable, starts with `BEGIN`/`TRUNCATE`) |

## Apply to the Postgres

```bash
# One time (DDL)
psql -h 192.168.10.221 -p 5432 -U <user> -d cs2tournament -f schema.sql

# Every time the plugin version bumps
psql -h 192.168.10.221 -p 5432 -U <user> -d cs2tournament -f seed.sql
```

`seed.sql` `TRUNCATE`s the seven data tables before re-inserting, so applying
it repeatedly leaves the database in a clean state.

## Regenerate `seed.sql`

```bash
# Fetches https://github.com/Nereziel/cs2-WeaponPaints/releases/download/<build>/WeaponPaints.zip
python3 build_catalog.py --build build-414

# ...or point it at an already-downloaded zip
python3 build_catalog.py --zip /path/to/WeaponPaints.zip --build build-414
```

When bumping the plugin version, also update `WEAPONPAINTS_BUILD` in
`install_cs2.sh` so the game servers and the Postgres catalog stay in sync.

## Row counts (build-414)

```
skins=2016, gloves=73, agents=2, music=95, keychains=78, stickers=9669, collectibles=603
```
