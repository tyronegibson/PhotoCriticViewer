"""CLI: delete a photo or an entire shoot from PhotoCritic, flag a similarity
group as a composite source set, or rename a shoot's folder.

Deleting never permanently erases a RAW file — it moves it (and its .xmp
sidecar, if any) into a `_Marked_for_Deletion` folder beside it, and removes
its rows from the database. Permanent cleanup of that folder is left to you,
in Finder, on your own schedule.

Usage:
    python3 curate.py delete-file --file <file_id>
    python3 curate.py delete-shoot --shoot <shoot_id>
    python3 curate.py set-composite --group <group_id> --on
    python3 curate.py set-composite --group <group_id> --off
    python3 curate.py rename-shoot --shoot <shoot_id> --name <new_folder_name>
    python3 curate.py split-group --group <group_id> --file <file_id>
    python3 curate.py mark-look --file <file_id> --name <look_name>
    python3 curate.py rename-look --look <look_id> --name <new_name>
    python3 curate.py delete-look --look <look_id>
    python3 curate.py set-separate-people --shoot <shoot_id> --on
    python3 curate.py set-separate-people --shoot <shoot_id> --off
    python3 curate.py mark-person --file <file_id> --name <person_name>
    python3 curate.py rename-person --person <person_id> --name <new_name>
    python3 curate.py delete-person --person <person_id>
    python3 curate.py mark-posted --file <file_id> --platform <name>
    python3 curate.py unmark-posted --file <file_id> --platform <name>
"""

import argparse
import sqlite3
import sys
from pathlib import Path

from photocritic import curation, db


def cmd_delete_file(args):
    with db.connect() as conn:
        db.init_schema(conn)
        row = conn.execute(
            "SELECT f.full_path, ta.preview_path FROM files f "
            "LEFT JOIN technical_analysis ta ON ta.file_id = f.id WHERE f.id = ?",
            (args.file,),
        ).fetchone()
        if row is None:
            print(f"No file with id {args.file}", file=sys.stderr)
            sys.exit(1)
        error = curation.mark_for_deletion(row["full_path"], row["preview_path"])
        db.delete_file(conn, args.file)
        if error:
            print(f"Removed from database, but couldn't move the RAW file: {error}")
        else:
            print(f"Deleted: {row['full_path']}")


def cmd_delete_shoot(args):
    with db.connect() as conn:
        db.init_schema(conn)
        shoot = conn.execute("SELECT id FROM shoots WHERE id = ?", (args.shoot,)).fetchone()
        if shoot is None:
            print(f"No shoot with id {args.shoot}", file=sys.stderr)
            sys.exit(1)
        rows = conn.execute(
            "SELECT f.id, f.full_path, ta.preview_path FROM files f "
            "LEFT JOIN technical_analysis ta ON ta.file_id = f.id WHERE f.shoot_id = ?",
            (args.shoot,),
        ).fetchall()
        errors = []
        for r in rows:
            error = curation.mark_for_deletion(r["full_path"], r["preview_path"])
            if error:
                errors.append(f"  {r['full_path']}: {error}")
        db.delete_shoot(conn, args.shoot)
        print(f"Deleted shoot {args.shoot}: {len(rows)} file(s) removed from the database.")
        if errors:
            print(f"{len(errors)} RAW file(s) couldn't be moved (still removed from the database):")
            print("\n".join(errors))


def cmd_set_composite(args):
    with db.connect() as conn:
        db.init_schema(conn)
        found = db.set_group_composite(conn, args.group, args.on)
        if not found:
            print(f"No group with id {args.group}", file=sys.stderr)
            sys.exit(1)
        print(f"Group {args.group} marked as {'composite set' if args.on else 'regular burst'}.")


def cmd_rename_shoot(args):
    name = args.name.strip()
    if not name or "/" in name or name in (".", ".."):
        print(f"Invalid folder name: {args.name!r}", file=sys.stderr)
        sys.exit(1)

    with db.connect() as conn:
        db.init_schema(conn)
        row = conn.execute("SELECT folder_path FROM shoots WHERE id = ?", (args.shoot,)).fetchone()
        if row is None:
            print(f"No shoot with id {args.shoot}", file=sys.stderr)
            sys.exit(1)

        old_path = Path(row["folder_path"])
        new_path = old_path.parent / name

        if new_path == old_path:
            print(f"Already named {name!r}.")
            return
        if new_path.exists():
            print(f"A folder already exists at {new_path}", file=sys.stderr)
            sys.exit(1)
        if not old_path.exists():
            print(f"Shoot folder not found on disk: {old_path}", file=sys.stderr)
            sys.exit(1)

        old_path.rename(new_path)
        count = db.update_shoot_paths(conn, args.shoot, str(new_path))
        print(f"Renamed shoot {args.shoot}: {old_path.name!r} -> {new_path.name!r} ({count} file(s) updated)")


def cmd_split_group(args):
    with db.connect() as conn:
        db.init_schema(conn)
        remaining = db.remove_file_from_group(conn, args.group, args.file)
        if remaining is None:
            print(f"File {args.file} is not a member of group {args.group}", file=sys.stderr)
            sys.exit(1)
        if remaining <= 1:
            print(f"Removed file {args.file} from group {args.group}; only {remaining} member(s) "
                  "left, so the group was dissolved.")
        else:
            print(f"Removed file {args.file} from group {args.group}; {remaining} member(s) remain.")


def cmd_mark_look(args):
    name = args.name.strip()
    if not name:
        print("Look name can't be empty", file=sys.stderr)
        sys.exit(1)

    with db.connect() as conn:
        db.init_schema(conn)
        row = conn.execute("SELECT shoot_id, filename FROM files WHERE id = ?", (args.file,)).fetchone()
        if row is None:
            print(f"No file with id {args.file}", file=sys.stderr)
            sys.exit(1)
        try:
            look_id = db.create_look(conn, row["shoot_id"], name, row["filename"])
        except sqlite3.IntegrityError:
            print(f"A look already starts at {row['filename']!r} — rename or delete it instead", file=sys.stderr)
            sys.exit(1)
        print(f"Created look {look_id} ({name!r}) starting at {row['filename']}")


def cmd_rename_look(args):
    name = args.name.strip()
    if not name:
        print("Look name can't be empty", file=sys.stderr)
        sys.exit(1)

    with db.connect() as conn:
        db.init_schema(conn)
        if not db.rename_look(conn, args.look, name):
            print(f"No look with id {args.look}", file=sys.stderr)
            sys.exit(1)
        print(f"Renamed look {args.look} to {name!r}")


def cmd_delete_look(args):
    with db.connect() as conn:
        db.init_schema(conn)
        if not db.delete_look(conn, args.look):
            print(f"No look with id {args.look}", file=sys.stderr)
            sys.exit(1)
        print(f"Deleted look {args.look}")


def cmd_set_separate_people(args):
    with db.connect() as conn:
        db.init_schema(conn)
        if not db.set_shoot_separate_people(conn, args.shoot, args.on):
            print(f"No shoot with id {args.shoot}", file=sys.stderr)
            sys.exit(1)
        print(f"Shoot {args.shoot}: multiple-people separation {'enabled' if args.on else 'disabled'}.")


def cmd_mark_person(args):
    name = args.name.strip()
    if not name:
        print("Person name can't be empty", file=sys.stderr)
        sys.exit(1)

    with db.connect() as conn:
        db.init_schema(conn)
        row = conn.execute("SELECT shoot_id, filename FROM files WHERE id = ?", (args.file,)).fetchone()
        if row is None:
            print(f"No file with id {args.file}", file=sys.stderr)
            sys.exit(1)
        try:
            person_id = db.create_person(conn, row["shoot_id"], name, row["filename"])
        except sqlite3.IntegrityError:
            print(f"A person already starts at {row['filename']!r} — rename or delete it instead", file=sys.stderr)
            sys.exit(1)
        print(f"Created person {person_id} ({name!r}) starting at {row['filename']}")


def cmd_rename_person(args):
    name = args.name.strip()
    if not name:
        print("Person name can't be empty", file=sys.stderr)
        sys.exit(1)

    with db.connect() as conn:
        db.init_schema(conn)
        if not db.rename_person(conn, args.person, name):
            print(f"No person with id {args.person}", file=sys.stderr)
            sys.exit(1)
        print(f"Renamed person {args.person} to {name!r}")


def cmd_delete_person(args):
    with db.connect() as conn:
        db.init_schema(conn)
        if not db.delete_person(conn, args.person):
            print(f"No person with id {args.person}", file=sys.stderr)
            sys.exit(1)
        print(f"Deleted person {args.person}")


def cmd_mark_posted(args):
    with db.connect() as conn:
        db.init_schema(conn)
        row = conn.execute("SELECT 1 FROM files WHERE id = ?", (args.file,)).fetchone()
        if row is None:
            print(f"No file with id {args.file}", file=sys.stderr)
            sys.exit(1)
        db.mark_posted(conn, args.file, args.platform)
        print(f"Marked file {args.file} as posted to {args.platform!r}")


def cmd_unmark_posted(args):
    with db.connect() as conn:
        db.init_schema(conn)
        db.unmark_posted(conn, args.file, args.platform)
        print(f"Cleared {args.platform!r} posted-mark for file {args.file} (if it was set)")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_file = sub.add_parser("delete-file")
    p_file.add_argument("--file", type=int, required=True)
    p_file.set_defaults(func=cmd_delete_file)

    p_shoot = sub.add_parser("delete-shoot")
    p_shoot.add_argument("--shoot", type=int, required=True)
    p_shoot.set_defaults(func=cmd_delete_shoot)

    p_composite = sub.add_parser("set-composite")
    p_composite.add_argument("--group", type=int, required=True)
    on_off = p_composite.add_mutually_exclusive_group(required=True)
    on_off.add_argument("--on", dest="on", action="store_true")
    on_off.add_argument("--off", dest="on", action="store_false")
    p_composite.set_defaults(func=cmd_set_composite)

    p_rename = sub.add_parser("rename-shoot")
    p_rename.add_argument("--shoot", type=int, required=True)
    p_rename.add_argument("--name", type=str, required=True)
    p_rename.set_defaults(func=cmd_rename_shoot)

    p_split = sub.add_parser("split-group")
    p_split.add_argument("--group", type=int, required=True)
    p_split.add_argument("--file", type=int, required=True)
    p_split.set_defaults(func=cmd_split_group)

    p_mark_look = sub.add_parser("mark-look")
    p_mark_look.add_argument("--file", type=int, required=True)
    p_mark_look.add_argument("--name", type=str, required=True)
    p_mark_look.set_defaults(func=cmd_mark_look)

    p_rename_look = sub.add_parser("rename-look")
    p_rename_look.add_argument("--look", type=int, required=True)
    p_rename_look.add_argument("--name", type=str, required=True)
    p_rename_look.set_defaults(func=cmd_rename_look)

    p_delete_look = sub.add_parser("delete-look")
    p_delete_look.add_argument("--look", type=int, required=True)
    p_delete_look.set_defaults(func=cmd_delete_look)

    p_separate_people = sub.add_parser("set-separate-people")
    p_separate_people.add_argument("--shoot", type=int, required=True)
    separate_on_off = p_separate_people.add_mutually_exclusive_group(required=True)
    separate_on_off.add_argument("--on", dest="on", action="store_true")
    separate_on_off.add_argument("--off", dest="on", action="store_false")
    p_separate_people.set_defaults(func=cmd_set_separate_people)

    p_mark_person = sub.add_parser("mark-person")
    p_mark_person.add_argument("--file", type=int, required=True)
    p_mark_person.add_argument("--name", type=str, required=True)
    p_mark_person.set_defaults(func=cmd_mark_person)

    p_rename_person = sub.add_parser("rename-person")
    p_rename_person.add_argument("--person", type=int, required=True)
    p_rename_person.add_argument("--name", type=str, required=True)
    p_rename_person.set_defaults(func=cmd_rename_person)

    p_mark_posted = sub.add_parser("mark-posted")
    p_mark_posted.add_argument("--file", type=int, required=True)
    p_mark_posted.add_argument("--platform", required=True, help="e.g. instagram, modelmayhem, inpose, portfolio")
    p_mark_posted.set_defaults(func=cmd_mark_posted)

    p_unmark_posted = sub.add_parser("unmark-posted")
    p_unmark_posted.add_argument("--file", type=int, required=True)
    p_unmark_posted.add_argument("--platform", required=True)
    p_unmark_posted.set_defaults(func=cmd_unmark_posted)

    p_delete_person = sub.add_parser("delete-person")
    p_delete_person.add_argument("--person", type=int, required=True)
    p_delete_person.set_defaults(func=cmd_delete_person)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
