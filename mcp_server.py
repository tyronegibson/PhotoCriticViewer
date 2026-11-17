"""MCP server exposing PhotoCritic's shoot/photo database and curation actions as
tools, so an MCP-capable AI assistant (Claude Desktop, Claude Code, or any other
MCP client) can browse and curate shoots directly instead of going through
PhotoCriticViewer. Thin wrappers around photocritic/db.py and photocritic/curation.py
— the same functions curate.py's CLI uses — so there's exactly one place curation
logic lives.

Run directly for local testing:
    .venv/bin/python3 mcp_server.py

Register with Claude Code (run once, from this directory):
    claude mcp add photocritic -- "$(pwd)/.venv/bin/python3" "$(pwd)/mcp_server.py"

Register with Claude Desktop: add to claude_desktop_config.json's "mcpServers":
    "photocritic": {
        "command": "/absolute/path/to/PhotoCritic/.venv/bin/python3",
        "args": ["/absolute/path/to/PhotoCritic/mcp_server.py"]
    }
"""

import sqlite3
from pathlib import Path

from mcp.server.mcpserver import MCPServer

from photocritic import curation, db

server = MCPServer(
    name="photocritic",
    instructions=(
        "Browse and curate PhotoCritic shoots — a local RAW photo culling database "
        "for professional photography (Hasselblad .3FR). Shoots contain files; files "
        "get AI evaluations (overall_score, classification, recommendation KEEP/MAYBE/"
        "REJECT), can be grouped into similarity/burst groups with rankings, and can "
        "be tagged with 'looks' (outfit changes within a shoot) or 'people' (for group "
        "shoots with more than one subject — off by default per shoot, see "
        "set_separate_people). Deletions never permanently erase a RAW file: they move "
        "it into a _Marked_for_Deletion folder beside it and remove its database rows."
    ),
)


# --- Read-only ---

@server.tool()
def list_shoots() -> list[dict]:
    """List every shoot with its photo counts and KEEP/MAYBE/REJECT recommendation totals."""
    with db.connect() as conn:
        db.init_schema(conn)
        return db.list_shoots(conn)


@server.tool()
def get_shoot(shoot_id: int) -> dict:
    """Get one shoot's folder path, creation date, and separate_people flag."""
    with db.connect() as conn:
        db.init_schema(conn)
        shoot = db.get_shoot(conn, shoot_id)
        if shoot is None:
            raise ValueError(f"No shoot with id {shoot_id}")
        return shoot


@server.tool()
def get_shoot_grid(shoot_id: int, sort: str = "score") -> list[dict]:
    """List every photo in a shoot with its AI score/recommendation, similarity-group
    membership, and current look/person tag (if any). sort is "score" (default,
    highest first) or "filename"."""
    with db.connect() as conn:
        db.init_schema(conn)
        return db.get_shoot_grid(conn, shoot_id, sort=sort)


@server.tool()
def get_photo_detail(file_id: int) -> dict:
    """Full detail for one photo: metadata (camera/lens/exposure), technical analysis
    (sharpness/exposure/flags), the full AI evaluation, and similarity-group membership."""
    with db.connect() as conn:
        db.init_schema(conn)
        detail = db.get_photo_detail(conn, file_id)
        if detail is None:
            raise ValueError(f"No file with id {file_id}")
        return detail


@server.tool()
def get_group_detail(group_id: int) -> dict:
    """Full detail for one similarity/burst group: every member photo with its rank,
    role (e.g. strongest/weakest), and the AI's rationale for the ranking."""
    with db.connect() as conn:
        db.init_schema(conn)
        detail = db.get_group_detail(conn, group_id)
        if detail is None:
            raise ValueError(f"No group with id {group_id}")
        return detail


@server.tool()
def list_looks(shoot_id: int) -> list[dict]:
    """List the look/outfit boundaries marked in a shoot."""
    with db.connect() as conn:
        db.init_schema(conn)
        return db.list_looks(conn, shoot_id)


@server.tool()
def list_people(shoot_id: int) -> list[dict]:
    """List the person boundaries marked in a shoot (only meaningful once the shoot's
    separate_people flag is on — see set_separate_people)."""
    with db.connect() as conn:
        db.init_schema(conn)
        return db.list_people(conn, shoot_id)


# --- Curation (mutating) ---

@server.tool()
def delete_file(file_id: int) -> str:
    """Remove one photo from PhotoCritic. Moves its RAW file (and .xmp sidecar, if
    any) into a _Marked_for_Deletion folder beside it — never permanently erases it —
    and removes its database rows."""
    with db.connect() as conn:
        db.init_schema(conn)
        row = conn.execute(
            "SELECT f.full_path, ta.preview_path FROM files f "
            "LEFT JOIN technical_analysis ta ON ta.file_id = f.id WHERE f.id = ?",
            (file_id,),
        ).fetchone()
        if row is None:
            raise ValueError(f"No file with id {file_id}")
        error = curation.mark_for_deletion(row["full_path"], row["preview_path"])
        db.delete_file(conn, file_id)
        if error:
            return f"Removed from database, but couldn't move the RAW file: {error}"
        return f"Deleted: {row['full_path']}"


@server.tool()
def delete_shoot(shoot_id: int) -> str:
    """Remove an entire shoot from PhotoCritic. Moves every RAW file into a
    _Marked_for_Deletion folder — never permanently erases anything — and removes
    all of the shoot's database rows."""
    with db.connect() as conn:
        db.init_schema(conn)
        shoot = conn.execute("SELECT id FROM shoots WHERE id = ?", (shoot_id,)).fetchone()
        if shoot is None:
            raise ValueError(f"No shoot with id {shoot_id}")
        rows = conn.execute(
            "SELECT f.id, f.full_path, ta.preview_path FROM files f "
            "LEFT JOIN technical_analysis ta ON ta.file_id = f.id WHERE f.shoot_id = ?",
            (shoot_id,),
        ).fetchall()
        errors = []
        for r in rows:
            error = curation.mark_for_deletion(r["full_path"], r["preview_path"])
            if error:
                errors.append(f"{r['full_path']}: {error}")
        db.delete_shoot(conn, shoot_id)
        summary = f"Deleted shoot {shoot_id}: {len(rows)} file(s) removed from the database."
        if errors:
            summary += (
                f" {len(errors)} RAW file(s) couldn't be moved (still removed from the database): "
                + "; ".join(errors)
            )
        return summary


@server.tool()
def rename_shoot(shoot_id: int, new_folder_name: str) -> str:
    """Rename a shoot's folder on disk and update PhotoCritic to match. new_folder_name
    is just the folder name, not a full path, and can't contain '/'."""
    name = new_folder_name.strip()
    if not name or "/" in name or name in (".", ".."):
        raise ValueError(f"Invalid folder name: {new_folder_name!r}")
    with db.connect() as conn:
        db.init_schema(conn)
        row = conn.execute("SELECT folder_path FROM shoots WHERE id = ?", (shoot_id,)).fetchone()
        if row is None:
            raise ValueError(f"No shoot with id {shoot_id}")
        old_path = Path(row["folder_path"])
        new_path = old_path.parent / name
        if new_path == old_path:
            return f"Already named {name!r}."
        if new_path.exists():
            raise ValueError(f"A folder already exists at {new_path}")
        if not old_path.exists():
            raise ValueError(f"Shoot folder not found on disk: {old_path}")
        old_path.rename(new_path)
        count = db.update_shoot_paths(conn, shoot_id, str(new_path))
        return f"Renamed shoot {shoot_id}: {old_path.name!r} -> {new_path.name!r} ({count} file(s) updated)"


@server.tool()
def set_composite(group_id: int, is_composite: bool) -> str:
    """Flag a similarity/burst group as a composite source set (multiple shots meant
    to be blended, e.g. for a jump/action composite) rather than a regular burst of
    near-duplicates."""
    with db.connect() as conn:
        db.init_schema(conn)
        if not db.set_group_composite(conn, group_id, is_composite):
            raise ValueError(f"No group with id {group_id}")
        return f"Group {group_id} marked as {'composite set' if is_composite else 'regular burst'}."


@server.tool()
def split_group(group_id: int, file_id: int) -> str:
    """Remove one photo from a similarity/burst group, splitting it out on its own."""
    with db.connect() as conn:
        db.init_schema(conn)
        remaining = db.remove_file_from_group(conn, group_id, file_id)
        if remaining is None:
            raise ValueError(f"File {file_id} is not a member of group {group_id}")
        if remaining <= 1:
            return (
                f"Removed file {file_id} from group {group_id}; only {remaining} member(s) "
                "left, so the group was dissolved."
            )
        return f"Removed file {file_id} from group {group_id}; {remaining} member(s) remain."


@server.tool()
def mark_look(file_id: int, name: str) -> str:
    """Mark a new look/outfit boundary starting at this photo. Every photo from here
    onward (in filename order), up to the next look, is grouped under this look."""
    name = name.strip()
    if not name:
        raise ValueError("Look name can't be empty")
    with db.connect() as conn:
        db.init_schema(conn)
        row = conn.execute("SELECT shoot_id, filename FROM files WHERE id = ?", (file_id,)).fetchone()
        if row is None:
            raise ValueError(f"No file with id {file_id}")
        try:
            look_id = db.create_look(conn, row["shoot_id"], name, row["filename"])
        except sqlite3.IntegrityError:
            raise ValueError(f"A look already starts at {row['filename']!r} — rename or delete it instead")
        return f"Created look {look_id} ({name!r}) starting at {row['filename']}"


@server.tool()
def rename_look(look_id: int, new_name: str) -> str:
    """Rename an existing look boundary."""
    new_name = new_name.strip()
    if not new_name:
        raise ValueError("Look name can't be empty")
    with db.connect() as conn:
        db.init_schema(conn)
        if not db.rename_look(conn, look_id, new_name):
            raise ValueError(f"No look with id {look_id}")
        return f"Renamed look {look_id} to {new_name!r}"


@server.tool()
def delete_look(look_id: int) -> str:
    """Remove a look boundary. Photos after it fall back to the previous look, if any."""
    with db.connect() as conn:
        db.init_schema(conn)
        if not db.delete_look(conn, look_id):
            raise ValueError(f"No look with id {look_id}")
        return f"Deleted look {look_id}"


@server.tool()
def set_separate_people(shoot_id: int, enabled: bool) -> str:
    """Turn the "multiple people" feature on/off for a shoot. Turn it on for group
    shoots with more than one subject, so photos can be tagged and filtered by
    person; leave it off (the default) for single-subject shoots and events."""
    with db.connect() as conn:
        db.init_schema(conn)
        if not db.set_shoot_separate_people(conn, shoot_id, enabled):
            raise ValueError(f"No shoot with id {shoot_id}")
        return f"Shoot {shoot_id}: multiple-people separation {'enabled' if enabled else 'disabled'}."


@server.tool()
def mark_person(file_id: int, name: str) -> str:
    """Mark a new person boundary starting at this photo (the shoot must have
    separate_people enabled — see set_separate_people). Every photo from here
    onward (in filename order), up to the next person, is grouped under this person."""
    name = name.strip()
    if not name:
        raise ValueError("Person name can't be empty")
    with db.connect() as conn:
        db.init_schema(conn)
        row = conn.execute("SELECT shoot_id, filename FROM files WHERE id = ?", (file_id,)).fetchone()
        if row is None:
            raise ValueError(f"No file with id {file_id}")
        try:
            person_id = db.create_person(conn, row["shoot_id"], name, row["filename"])
        except sqlite3.IntegrityError:
            raise ValueError(f"A person already starts at {row['filename']!r} — rename or delete it instead")
        return f"Created person {person_id} ({name!r}) starting at {row['filename']}"


@server.tool()
def rename_person(person_id: int, new_name: str) -> str:
    """Rename an existing person boundary."""
    new_name = new_name.strip()
    if not new_name:
        raise ValueError("Person name can't be empty")
    with db.connect() as conn:
        db.init_schema(conn)
        if not db.rename_person(conn, person_id, new_name):
            raise ValueError(f"No person with id {person_id}")
        return f"Renamed person {person_id} to {new_name!r}"


@server.tool()
def delete_person(person_id: int) -> str:
    """Remove a person boundary. Photos after it fall back to the previous person, if any."""
    with db.connect() as conn:
        db.init_schema(conn)
        if not db.delete_person(conn, person_id):
            raise ValueError(f"No person with id {person_id}")
        return f"Deleted person {person_id}"


if __name__ == "__main__":
    server.run(transport="stdio")
