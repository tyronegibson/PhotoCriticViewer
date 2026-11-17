"""Carry the marks you make on a travelling laptop back to the Studio's database.

  On the laptop (its own small workspace):   python3 travel_sync.py export marks.json
  On the Studio, AFTER the photos are imported and organized there:
                                            python3 travel_sync.py apply marks.json          (dry run)
                                            python3 travel_sync.py apply marks.json --apply

Carried over: looks, people, composite-set flags on burst groups, and photos you deleted (their
RAW moves to _Marked_for_Deletion, same as deleting in the app). NOT carried: splitting a photo
out of a burst group, shoot renames, AI scores.

Safety rules (apply never guesses):
  * Photos are matched by capture date + filename (+ size for deletes), never by database id.
  * A delete only happens if exactly one studio row matches on that date. Zero matches is
    reported as already gone; more than one is refused and reported.
  * If more than one studio shoot has the same date, that date is skipped and reported.
  * Only marks.json version 1 is accepted.
  * The multiple-people switch is ONE-WAY: a laptop's "on" turns it on at the studio, but "off"
    never turns it off there.
  * A look/person/composite whose photo or group isn't on the studio is reported in "problems".
  * Apply writes everything in one commit at the very end. With --apply, the database is backed up
    first to photocritic.db.bak-pre-sync-<timestamp> in the database folder.
  * A photo's database row is only removed once its RAW has actually been moved aside.

Safe to re-run: existing looks/people/composite flags are skipped and already-deleted files are
reported as already gone.
"""

import argparse
import json
import sqlite3
import sys
from pathlib import Path

from photocritic import config, curation, db


def group_filenames_by_group(conn, shoot_id: int) -> dict[int, frozenset[str]]:
    """{group_id: {filenames}} for every similarity group in a shoot — one query,
    not one query per group, since this gets compared against every composite
    group being synced (export) or matched against (apply)."""
    out: dict[int, set[str]] = {}
    for r in conn.execute(
        "SELECT sgm.group_id, f.filename FROM similarity_group_members sgm "
        "JOIN files f ON f.id = sgm.file_id "
        "JOIN similarity_groups sg ON sg.id = sgm.group_id WHERE sg.shoot_id = ?",
        (shoot_id,),
    ):
        out.setdefault(r["group_id"], set()).add(r["filename"])
    return {gid: frozenset(names) for gid, names in out.items()}


def shoot_dates(conn) -> dict[int, str]:
    """shoot_id -> YYYY-MM-DD, the date most of its files were captured on."""
    best: dict[int, tuple[str, int]] = {}
    for r in conn.execute(
        "SELECT f.shoot_id AS sid, substr(m.capture_time, 1, 10) AS d, COUNT(*) AS n "
        "FROM files f JOIN metadata m ON m.file_id = f.id "
        "WHERE m.capture_time IS NOT NULL AND m.capture_time != '' GROUP BY f.shoot_id, d"
    ):
        if r["sid"] not in best or r["n"] > best[r["sid"]][1]:
            best[r["sid"]] = (r["d"].replace(":", "-"), r["n"])
    return {sid: d for sid, (d, _) in best.items()}


MARKS_VERSION = 1


def export_marks(conn) -> dict:
    dates = shoot_dates(conn)
    shoots = []
    deleted = []
    for s in conn.execute("SELECT id, folder_path, separate_people FROM shoots").fetchall():
        looks = [{"name": r["name"], "start_filename": r["start_filename"]}
                 for r in conn.execute("SELECT name, start_filename FROM looks WHERE shoot_id = ?", (s["id"],))]
        people = [{"name": r["name"], "start_filename": r["start_filename"]}
                  for r in conn.execute("SELECT name, start_filename FROM people WHERE shoot_id = ?", (s["id"],))]
        members_by_group = group_filenames_by_group(conn, s["id"])
        composite = [
            sorted(members_by_group.get(g["id"], ()))
            for g in conn.execute("SELECT id FROM similarity_groups WHERE shoot_id = ? AND is_composite = 1", (s["id"],))
        ]
        if (looks or people or composite or s["separate_people"]) and s["id"] in dates:
            shoots.append({"date": dates[s["id"]], "separate_people": bool(s["separate_people"]),
                           "looks": looks, "people": people, "composite_groups": composite})
        folder = Path(s["folder_path"])
        if folder.is_dir():
            for marker in folder.rglob(curation.MARKER_DIRNAME):
                for f in marker.iterdir():
                    if f.suffix.lower() == ".3fr":
                        deleted.append({"date": dates.get(s["id"]), "filename": f.name, "size": f.stat().st_size})
    seen = set()
    deleted = [d for d in deleted
               if (d["date"], d["filename"], d["size"]) not in seen
               and not seen.add((d["date"], d["filename"], d["size"]))]
    return {"version": MARKS_VERSION, "shoots": shoots, "deleted": deleted}


def apply_marks(conn, data: dict, apply: bool) -> None:
    dates = shoot_dates(conn)
    by_date: dict[str, list[int]] = {}
    for sid, d in dates.items():
        by_date.setdefault(d, []).append(sid)

    def studio_shoots_on(date: str | None) -> list[int]:
        return by_date.get(date, []) if date else []

    tally = {"looks": 0, "people": 0, "composite": 0, "deleted": 0, "skipped_existing": 0, "already_gone": 0, "problems": 0}
    for sh in data["shoots"]:
        candidates = studio_shoots_on(sh["date"])
        if not candidates:
            print(f"  ! {sh['date']}: no shoot for this date on the Studio yet — import/organize the photos first")
            tally["problems"] += 1
            continue
        if len(candidates) > 1:
            print(f"  ! {sh['date']}: {len(candidates)} studio shoots share this date ({candidates}); "
                  f"not guessing which one — sync this date by hand")
            tally["problems"] += 1
            continue
        sid = candidates[0]
        print(f"{sh['date']} -> Studio shoot {sid}")
        filenames = {r["filename"] for r in conn.execute("SELECT filename FROM files WHERE shoot_id = ?", (sid,))}
        if sh["separate_people"] and apply:
            db.set_shoot_separate_people(conn, sid, True)
        for kind, label, creator, table in (("looks", "look", db.create_look, "looks"), ("people", "person", db.create_person, "people")):
            # Existing start_filenames for this shoot/table, fetched once rather than
            # one "does this already exist" query per look/person being synced.
            existing = {r["start_filename"] for r in conn.execute(f"SELECT start_filename FROM {table} WHERE shoot_id = ?", (sid,))}
            for item in sh[kind]:
                if item["start_filename"] not in filenames:
                    print(f"  ! {label} {item['name']!r}: photo {item['start_filename']} not on the Studio")
                    tally["problems"] += 1
                    continue
                if item["start_filename"] in existing:
                    tally["skipped_existing"] += 1
                    continue
                print(f"  + {label} {item['name']!r} starting at {item['start_filename']}")
                if apply:
                    try:
                        creator(conn, sid, item["name"], item["start_filename"])
                    except sqlite3.IntegrityError:
                        tally["skipped_existing"] += 1
                        continue
                existing.add(item["start_filename"])
                tally[kind] += 1
        if sh["composite_groups"]:
            members_by_group = group_filenames_by_group(conn, sid)
            composite_flags = {r["id"]: r["is_composite"] for r in conn.execute(
                "SELECT id, is_composite FROM similarity_groups WHERE shoot_id = ?", (sid,))}
            for names in sh["composite_groups"]:
                wanted = frozenset(names)
                match = next((gid for gid, members in members_by_group.items() if members == wanted), None)
                if match is None:
                    print(f"  ! composite group {names[:3]}... has no identical group on the Studio")
                    tally["problems"] += 1
                    continue
                if composite_flags.get(match):
                    tally["skipped_existing"] += 1
                    continue
                print(f"  + composite set: group {match} ({len(names)} photos)")
                if apply:
                    db.set_group_composite(conn, match, True)
                tally["composite"] += 1

    for d in data["deleted"]:
        scope = studio_shoots_on(d.get("date"))
        if not scope:
            print(f"  ! deleted {d['filename']}: no studio shoot for date {d.get('date')} — not touched")
            tally["problems"] += 1
            continue
        rows = conn.execute(
            f"SELECT f.id, f.full_path, ta.preview_path FROM files f "
            f"LEFT JOIN technical_analysis ta ON ta.file_id = f.id "
            f"WHERE f.filename = ? AND f.file_size = ? AND f.shoot_id IN ({','.join('?' * len(scope))})",
            (d["filename"], d["size"], *scope)).fetchall()
        if not rows:
            print(f"  . {d['filename']}: not in the Studio database (already removed, or never imported there)")
            tally["already_gone"] += 1
            continue
        if len(rows) > 1:
            print(f"  ! deleted {d['filename']}: {len(rows)} studio photos match name+size on {d.get('date')} — "
                  f"refusing to pick one; not touched")
            tally["problems"] += 1
            continue
        row = rows[0]
        print(f"  - delete {d['filename']}")
        if apply:
            error = curation.mark_for_deletion(row["full_path"], row["preview_path"])
            if error:
                # Keep the database row when the RAW didn't move: otherwise the app and the disk disagree.
                print(f"    NOT deleted — couldn't move the RAW, database row kept: {error}")
                tally["problems"] += 1
                continue
            db.delete_file(conn, row["id"])
        tally["deleted"] += 1

    print("\n" + ("Applied: " if apply else "Would apply: ") + ", ".join(f"{v} {k}" for k, v in tally.items()))
    if not apply:
        print("Dry run — nothing changed. Re-run with --apply (take a database backup first).")
    if tally["problems"]:
        print(f"{tally['problems']} item(s) need a manual look — see the '!' lines above.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export")
    e.add_argument("out", type=Path)
    a = sub.add_parser("apply")
    a.add_argument("marks", type=Path)
    a.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    with db.connect() as conn:
        db.init_schema(conn)
        if args.cmd == "export":
            data = export_marks(conn)
            args.out.write_text(json.dumps(data, indent=2))
            print(f"Wrote {args.out}: {len(data['shoots'])} shoot(s) with marks, {len(data['deleted'])} deleted photo(s).")
        else:
            data = json.loads(args.marks.read_text())
            if data.get("version") != MARKS_VERSION:
                sys.exit(f"Unsupported marks version {data.get('version')!r}; this script reads version {MARKS_VERSION}.")
            if args.apply:
                from datetime import datetime
                backup = config.DATABASE_DIR / f"photocritic.db.bak-pre-sync-{datetime.now():%Y%m%d-%H%M%S}"
                dst = sqlite3.connect(backup)
                conn.backup(dst)
                dst.close()
                print("backup written:", backup)
            apply_marks(conn, data, args.apply)
            if args.apply:
                conn.commit()


if __name__ == "__main__":
    main()
