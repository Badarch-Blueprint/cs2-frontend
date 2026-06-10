#!/usr/bin/env python3
"""
Build a Postgres seed.sql for the WeaponPaints catalog tables.

Downloads a pinned Nereziel/cs2-WeaponPaints release, extracts the
``data/*_en.json`` files, and emits a single transactional SQL file that
re-seeds all seven catalog tables defined in ``schema.sql``.

Usage
-----
    python3 build_catalog.py                 # -> seed.sql next to this script
    python3 build_catalog.py --build build-414 --output seed.sql

Idempotent: the generated file TRUNCATEs each table before inserting, so it
can be re-applied safely whenever the plugin bumps.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import sys
import urllib.request
import zipfile
from pathlib import Path
from typing import Any, Iterable

DEFAULT_BUILD = "build-414"
RELEASE_URL_TEMPLATE = (
    "https://github.com/Nereziel/cs2-WeaponPaints/releases/download/{build}/WeaponPaints.zip"
)
DATA_PREFIX = "WeaponPaints/data/"
BATCH_SIZE = 500


def log(msg: str) -> None:
    print(f"[build_catalog] {msg}", file=sys.stderr)


def fetch_release(build: str) -> zipfile.ZipFile:
    url = RELEASE_URL_TEMPLATE.format(build=build)
    log(f"downloading {url}")
    with urllib.request.urlopen(url) as resp:
        raw = resp.read()
    log(f"got {len(raw):,} bytes, opening as zip")
    return zipfile.ZipFile(io.BytesIO(raw))


def load_json(zf: zipfile.ZipFile, name: str) -> Any:
    with zf.open(DATA_PREFIX + name) as f:
        return json.load(f)


def sql_quote(value: Any) -> str:
    """Render a Python value as a Postgres literal (NULL / number / E'string')."""
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)):
        return str(value)
    s = str(value)
    escaped = s.replace("\\", "\\\\").replace("'", "''")
    return f"E'{escaped}'"


def coerce_int(value: Any, field: str) -> int:
    if isinstance(value, bool):
        raise ValueError(f"{field}: unexpected bool")
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.strip():
        return int(value.strip())
    raise ValueError(f"{field}: cannot coerce {value!r} to int")


def coerce_bool(value: Any, default: bool = False) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "y"}
    return bool(value)


def emit_insert(
    out: io.StringIO,
    table: str,
    columns: list[str],
    rows: Iterable[tuple[Any, ...]],
    *,
    conflict_cols: list[str] | None = None,
) -> int:
    rows = list(rows)
    if not rows:
        return 0
    col_list = ", ".join(columns)
    conflict = ""
    if conflict_cols:
        update_assignments = ", ".join(
            f"{c} = EXCLUDED.{c}" for c in columns if c not in conflict_cols
        )
        if update_assignments:
            conflict = (
                f"\nON CONFLICT ({', '.join(conflict_cols)}) DO UPDATE SET "
                + update_assignments
            )
        else:
            conflict = f"\nON CONFLICT ({', '.join(conflict_cols)}) DO NOTHING"
    for start in range(0, len(rows), BATCH_SIZE):
        chunk = rows[start : start + BATCH_SIZE]
        out.write(f"INSERT INTO {table} ({col_list}) VALUES\n")
        value_tuples = [
            "  (" + ", ".join(sql_quote(v) for v in row) + ")" for row in chunk
        ]
        out.write(",\n".join(value_tuples))
        out.write(conflict + ";\n\n")
    return len(rows)


def build_skins_rows(data: list[dict]) -> list[tuple]:
    rows = []
    seen: set[tuple[int, int]] = set()
    for entry in data:
        try:
            defindex = coerce_int(entry.get("weapon_defindex"), "weapon_defindex")
            paint = coerce_int(entry.get("paint"), "paint")
        except (ValueError, TypeError) as exc:
            log(f"skin row skipped ({exc}): {entry!r}")
            continue
        key = (defindex, paint)
        if key in seen:
            continue
        seen.add(key)
        rows.append(
            (
                defindex,
                entry.get("weapon_name") or "",
                paint,
                entry.get("paint_name") or "",
                entry.get("image"),
                coerce_bool(entry.get("legacy_model"), default=False),
            )
        )
    return rows


def build_gloves_rows(data: list[dict]) -> list[tuple]:
    rows = []
    seen: set[tuple[int, int]] = set()
    for entry in data:
        try:
            defindex = coerce_int(entry.get("weapon_defindex"), "weapon_defindex")
            paint = coerce_int(entry.get("paint"), "paint")
        except (ValueError, TypeError) as exc:
            log(f"glove row skipped ({exc}): {entry!r}")
            continue
        key = (defindex, paint)
        if key in seen:
            continue
        seen.add(key)
        rows.append(
            (
                defindex,
                paint,
                entry.get("paint_name") or "",
                entry.get("image"),
            )
        )
    return rows


def build_agents_rows(data: list[dict]) -> list[tuple]:
    rows = []
    for entry in data:
        try:
            team = coerce_int(entry.get("team"), "team")
        except (ValueError, TypeError) as exc:
            log(f"agent row skipped ({exc}): {entry!r}")
            continue
        rows.append(
            (
                team,
                entry.get("model") if entry.get("model") not in (None, "null") else None,
                entry.get("agent_name") or "",
                entry.get("image") or None,
            )
        )
    return rows


def build_id_name_image_rows(
    data: list[dict], *, table_label: str
) -> list[tuple]:
    rows = []
    seen: set[int] = set()
    for entry in data:
        try:
            ident = coerce_int(entry.get("id"), "id")
        except (ValueError, TypeError) as exc:
            log(f"{table_label} row skipped ({exc}): {entry!r}")
            continue
        if ident in seen:
            continue
        seen.add(ident)
        rows.append(
            (
                ident,
                entry.get("name") or "",
                entry.get("image"),
            )
        )
    return rows


def build_seed_sql(zf: zipfile.ZipFile, build: str) -> tuple[str, dict[str, int]]:
    skins = build_skins_rows(load_json(zf, "skins_en.json"))
    gloves = build_gloves_rows(load_json(zf, "gloves_en.json"))
    agents = build_agents_rows(load_json(zf, "agents_en.json"))
    music = build_id_name_image_rows(
        load_json(zf, "music_en.json"), table_label="music"
    )
    keychains = build_id_name_image_rows(
        load_json(zf, "keychains_en.json"), table_label="keychain"
    )
    stickers = build_id_name_image_rows(
        load_json(zf, "stickers_en.json"), table_label="sticker"
    )
    collectibles = build_id_name_image_rows(
        load_json(zf, "collectibles_en.json"), table_label="collectible"
    )

    out = io.StringIO()
    out.write(
        "-- WeaponPaints catalog seed data (auto-generated by build_catalog.py)\n"
        f"-- Plugin build: {build}\n"
        "-- Do not edit by hand; re-run build_catalog.py to regenerate.\n"
        "-- Assumes schema.sql has been applied to the target database.\n\n"
        "BEGIN;\n\n"
        "TRUNCATE TABLE\n"
        "    wp_catalog_skins,\n"
        "    wp_catalog_gloves,\n"
        "    wp_catalog_agents,\n"
        "    wp_catalog_music,\n"
        "    wp_catalog_keychains,\n"
        "    wp_catalog_stickers,\n"
        "    wp_catalog_collectibles\n"
        "RESTART IDENTITY;\n\n"
    )

    counts: dict[str, int] = {}
    counts["skins"] = emit_insert(
        out,
        "wp_catalog_skins",
        ["weapon_defindex", "weapon_name", "paint", "paint_name", "image", "legacy_model"],
        skins,
    )
    counts["gloves"] = emit_insert(
        out,
        "wp_catalog_gloves",
        ["weapon_defindex", "paint", "paint_name", "image"],
        gloves,
    )
    counts["agents"] = emit_insert(
        out,
        "wp_catalog_agents",
        ["team", "model", "agent_name", "image"],
        agents,
    )
    counts["music"] = emit_insert(
        out, "wp_catalog_music", ["id", "name", "image"], music
    )
    counts["keychains"] = emit_insert(
        out, "wp_catalog_keychains", ["id", "name", "image"], keychains
    )
    counts["stickers"] = emit_insert(
        out, "wp_catalog_stickers", ["id", "name", "image"], stickers
    )
    counts["collectibles"] = emit_insert(
        out,
        "wp_catalog_collectibles",
        ["id", "name", "image"],
        collectibles,
    )

    out.write(
        "INSERT INTO wp_catalog_version (build, imported_at) VALUES\n"
        f"  ({sql_quote(build)}, NOW())\n"
        "ON CONFLICT (build) DO UPDATE SET imported_at = EXCLUDED.imported_at;\n\n"
        "COMMIT;\n"
    )
    return out.getvalue(), counts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--build",
        default=os.environ.get("WEAPONPAINTS_BUILD", DEFAULT_BUILD),
        help=f"Plugin release tag to pull (default: {DEFAULT_BUILD})",
    )
    parser.add_argument(
        "--output",
        default=str(Path(__file__).resolve().parent / "seed.sql"),
        help="Output path for seed.sql",
    )
    parser.add_argument(
        "--zip",
        default=None,
        help="Optional local WeaponPaints.zip path (skips the network fetch)",
    )
    args = parser.parse_args()

    if args.zip:
        log(f"using local zip {args.zip}")
        zf = zipfile.ZipFile(args.zip)
    else:
        zf = fetch_release(args.build)

    with zf:
        sql_text, counts = build_seed_sql(zf, args.build)

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(sql_text, encoding="utf-8")

    log(f"wrote {out_path}")
    log("rows: " + ", ".join(f"{k}={v}" for k, v in counts.items()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
