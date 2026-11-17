"""SQLite storage. Resumability works by presence-check: each stage's table row
existing for a file_id means that stage is already done, so a re-run just skips it."""

import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from . import config

SCHEMA = """
CREATE TABLE IF NOT EXISTS shoots (
    id INTEGER PRIMARY KEY,
    folder_path TEXT UNIQUE NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY,
    shoot_id INTEGER NOT NULL REFERENCES shoots(id),
    filename TEXT NOT NULL,
    full_path TEXT UNIQUE NOT NULL,
    file_size INTEGER,
    mtime REAL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS metadata (
    file_id INTEGER PRIMARY KEY REFERENCES files(id),
    camera_model TEXT,
    lens TEXT,
    iso INTEGER,
    aperture TEXT,
    shutter_speed TEXT,
    focal_length TEXT,
    capture_time TEXT,
    raw_json TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS technical_analysis (
    file_id INTEGER PRIMARY KEY REFERENCES files(id),
    sharpness_score REAL,
    is_blurry INTEGER,
    exposure_mean REAL,
    highlight_clip_pct REAL,
    shadow_clip_pct REAL,
    flags_json TEXT,
    phash TEXT,
    preview_path TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS ai_evaluations (
    id INTEGER PRIMARY KEY,
    file_id INTEGER NOT NULL REFERENCES files(id),
    model_version TEXT NOT NULL,
    prompt_version TEXT NOT NULL,
    overall_score REAL,
    classification TEXT,
    recommendation TEXT,
    evaluation_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(file_id, model_version, prompt_version)
);

CREATE TABLE IF NOT EXISTS similarity_groups (
    id INTEGER PRIMARY KEY,
    shoot_id INTEGER NOT NULL REFERENCES shoots(id),
    method TEXT NOT NULL,
    is_composite INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS similarity_group_members (
    group_id INTEGER NOT NULL REFERENCES similarity_groups(id),
    file_id INTEGER NOT NULL REFERENCES files(id),
    PRIMARY KEY (group_id, file_id)
);

CREATE TABLE IF NOT EXISTS looks (
    id INTEGER PRIMARY KEY,
    shoot_id INTEGER NOT NULL REFERENCES shoots(id),
    name TEXT NOT NULL,
    start_filename TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(shoot_id, start_filename)
);

CREATE TABLE IF NOT EXISTS people (
    id INTEGER PRIMARY KEY,
    shoot_id INTEGER NOT NULL REFERENCES shoots(id),
    name TEXT NOT NULL,
    start_filename TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(shoot_id, start_filename)
);

CREATE TABLE IF NOT EXISTS rankings (
    id INTEGER PRIMARY KEY,
    group_id INTEGER NOT NULL REFERENCES similarity_groups(id),
    file_id INTEGER NOT NULL REFERENCES files(id),
    rank INTEGER NOT NULL,
    role TEXT,
    model_version TEXT NOT NULL,
    prompt_version TEXT NOT NULL,
    rationale TEXT,
    raw_json TEXT,
    created_at TEXT NOT NULL,
    UNIQUE(group_id, file_id, model_version, prompt_version)
);

-- Which platform(s) a photo has been posted to, and when. A brand-new, additive table (no
-- existing data to migrate) -- see curate.py's mark-posted subcommand, the only writer.
CREATE TABLE IF NOT EXISTS posted_to (
    file_id INTEGER NOT NULL REFERENCES files(id),
    platform TEXT NOT NULL,
    posted_at TEXT NOT NULL,
    PRIMARY KEY (file_id, platform)
);
"""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


@contextmanager
def connect(db_path: Path | None = None):
    # Resolved inside the function body, not as the default parameter value: a default
    # parameter is evaluated once, when this function is DEFINED (i.e. whenever
    # photocritic.db is first imported in a process), which would freeze it to whatever
    # config.DATABASE_PATH happened to be at that moment -- see config.py's long comment on
    # the exact same mistake, which caused real contamination of the production database
    # from a test run before being caught. config.DATABASE_PATH itself is now safe to read at
    # any time (computed fresh via __getattr__), so this only needs to defer the read, not
    # duplicate that fix.
    db_path = db_path if db_path is not None else config.DATABASE_PATH
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    # organize.py, evaluate.py, and curate.py can now all run concurrently
    # against this same file (e.g. evaluating one shoot while an archive's
    # remaining dates are still being organized). WAL mode lets readers and
    # writers stop blocking each other entirely, which is most of what
    # concurrent access here needs; busy_timeout is the remaining safety net
    # for the genuine writer-vs-writer case (two inserts at the same instant).
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA busy_timeout = 30000")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


# Columns added after a table already existed in shipped databases. CREATE TABLE
# IF NOT EXISTS (in SCHEMA above) only helps brand-new databases — it silently
# no-ops on a table that already exists with an older shape, so new columns need
# an explicit, idempotent ALTER TABLE migration here.
_COLUMN_MIGRATIONS = [
    ("rankings", "raw_json", "TEXT"),
    ("similarity_groups", "is_composite", "INTEGER NOT NULL DEFAULT 0"),
    ("shoots", "separate_people", "INTEGER NOT NULL DEFAULT 0"),
    # Calibrated-scoring columns (2026-10): overall_score/classification/recommendation are
    # unchanged in meaning (still "the" score/grade/recommendation, see photocritic/scoring.py
    # for how they're now computed) -- these are the NEW, additional fields. All nullable: an
    # old row simply has NULL here until it's re-scored (see rescore.py), never retroactively
    # back-filled by this migration itself.
    ("ai_evaluations", "calibrated_score", "REAL"),
    ("ai_evaluations", "percentile_shoot", "REAL"),
    ("ai_evaluations", "percentile_library", "REAL"),
    ("ai_evaluations", "z_score_library", "REAL"),
    ("ai_evaluations", "temperature", "REAL"),
    ("ai_evaluations", "weights_json", "TEXT"),
    ("ai_evaluations", "sample_count", "INTEGER NOT NULL DEFAULT 1"),
]


def init_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)
    for table, column, col_type in _COLUMN_MIGRATIONS:
        existing = {row["name"] for row in conn.execute(f"PRAGMA table_info({table})")}
        if column not in existing:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {col_type}")


def get_or_create_shoot(conn, folder_path: str) -> int:
    row = conn.execute("SELECT id FROM shoots WHERE folder_path = ?", (folder_path,)).fetchone()
    if row:
        return row["id"]
    cur = conn.execute(
        "INSERT INTO shoots (folder_path, created_at) VALUES (?, ?)", (folder_path, _now())
    )
    return cur.lastrowid


def get_shoot_by_folder(conn, folder_path: str) -> int | None:
    row = conn.execute("SELECT id FROM shoots WHERE folder_path = ?", (folder_path,)).fetchone()
    return row["id"] if row else None


def get_or_create_file(conn, shoot_id: int, filename: str, full_path: str, file_size: int, mtime: float) -> int:
    row = conn.execute("SELECT id FROM files WHERE full_path = ?", (full_path,)).fetchone()
    if row:
        return row["id"]
    cur = conn.execute(
        "INSERT INTO files (shoot_id, filename, full_path, file_size, mtime, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (shoot_id, filename, full_path, file_size, mtime, _now()),
    )
    return cur.lastrowid


def known_capture_times(conn, paths: list[str]) -> dict[str, str]:
    """full_path -> stored capture_time, for just these paths that already have a usable
    metadata row. Scoped to the batch being organized, so a re-run reads only what it needs."""
    out: dict[str, str] = {}
    for i in range(0, len(paths), 500):
        chunk = paths[i:i + 500]
        for r in conn.execute(
            "SELECT f.full_path, m.capture_time FROM files f JOIN metadata m ON m.file_id = f.id "
            f"WHERE f.full_path IN ({','.join('?' * len(chunk))}) "
            "AND m.capture_time IS NOT NULL AND m.capture_time != ''", chunk
        ):
            out[r["full_path"]] = r["capture_time"]
    return out


def has_metadata(conn, file_id: int) -> bool:
    return conn.execute("SELECT 1 FROM metadata WHERE file_id = ?", (file_id,)).fetchone() is not None


def save_metadata(conn, file_id: int, fields: dict) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO metadata "
        "(file_id, camera_model, lens, iso, aperture, shutter_speed, focal_length, capture_time, raw_json, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            file_id,
            fields.get("camera_model"),
            fields.get("lens"),
            fields.get("iso"),
            fields.get("aperture"),
            fields.get("shutter_speed"),
            fields.get("focal_length"),
            fields.get("capture_time"),
            json.dumps(fields.get("raw", {})),
            _now(),
        ),
    )


def has_technical_analysis(conn, file_id: int) -> bool:
    return conn.execute(
        "SELECT 1 FROM technical_analysis WHERE file_id = ?", (file_id,)
    ).fetchone() is not None


def save_technical_analysis(conn, file_id: int, ta, phash: str, preview_path: str) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO technical_analysis "
        "(file_id, sharpness_score, is_blurry, exposure_mean, highlight_clip_pct, shadow_clip_pct, "
        "flags_json, phash, preview_path, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            file_id,
            ta.sharpness_score,
            int(ta.is_blurry),
            ta.exposure_mean,
            ta.highlight_clip_pct,
            ta.shadow_clip_pct,
            json.dumps(ta.flags),
            phash,
            preview_path,
            _now(),
        ),
    )


def has_evaluation(conn, file_id: int, model_version: str, prompt_version: str) -> bool:
    return conn.execute(
        "SELECT 1 FROM ai_evaluations WHERE file_id = ? AND model_version = ? AND prompt_version = ?",
        (file_id, model_version, prompt_version),
    ).fetchone() is not None


def save_evaluation(
    conn, file_id: int, model_version: str, prompt_version: str, parsed: dict,
    temperature: float | None = None, weights: dict | None = None, sample_count: int = 1,
) -> None:
    """`parsed` must already have overall_score/classification/recommendation computed and
    injected (see photocritic.scoring.score_in_code) -- as of evaluation_v4 the model itself no
    longer provides them, and this function just stores whatever's in `parsed` either way.
    temperature/weights/sample_count are the generation provenance for this exact row (per
    "store prompt_version, model_id, temperature, and weights with every result") -- optional
    so existing callers (and tests) that don't pass them keep working, just with NULLs there."""
    conn.execute(
        "INSERT OR REPLACE INTO ai_evaluations "
        "(file_id, model_version, prompt_version, overall_score, classification, recommendation, "
        "evaluation_json, temperature, weights_json, sample_count, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            file_id,
            model_version,
            prompt_version,
            parsed.get("overall_score"),
            parsed.get("classification"),
            parsed.get("recommendation"),
            json.dumps(parsed),
            temperature,
            json.dumps(weights) if weights is not None else None,
            sample_count,
            _now(),
        ),
    )


def create_similarity_group(conn, shoot_id: int, method: str, file_ids: list[int]) -> int:
    cur = conn.execute(
        "INSERT INTO similarity_groups (shoot_id, method, created_at) VALUES (?, ?, ?)",
        (shoot_id, method, _now()),
    )
    group_id = cur.lastrowid
    for fid in file_ids:
        conn.execute(
            "INSERT OR IGNORE INTO similarity_group_members (group_id, file_id) VALUES (?, ?)",
            (group_id, fid),
        )
    return group_id


def add_files_to_group(conn, group_id: int, file_ids: list[int]) -> None:
    """Merges files into an already-existing similarity group — e.g. a newly
    imported photo that turns out to be a near-duplicate of one already in a
    reviewed group. Never touches the group's own row (is_composite, etc.)."""
    for fid in file_ids:
        conn.execute(
            "INSERT OR IGNORE INTO similarity_group_members (group_id, file_id) VALUES (?, ?)",
            (group_id, fid),
        )


def group_fully_ranked(conn, group_id: int, model_version: str, prompt_version: str) -> bool:
    """True only if every current member has a ranking row — a group that
    gained a member (e.g. add_files_to_group) needs a fresh ranking pass,
    since strongest/weakest is meaningless without comparing the new member
    too. has_ranking's old any-row check couldn't tell these apart."""
    total = conn.execute(
        "SELECT COUNT(*) FROM similarity_group_members WHERE group_id = ?", (group_id,)
    ).fetchone()[0]
    if total == 0:
        return False
    ranked = conn.execute(
        "SELECT COUNT(*) FROM rankings WHERE group_id = ? AND model_version = ? AND prompt_version = ?",
        (group_id, model_version, prompt_version),
    ).fetchone()[0]
    return total == ranked


def has_ranking(conn, group_id: int, model_version: str, prompt_version: str) -> bool:
    return conn.execute(
        "SELECT 1 FROM rankings WHERE group_id = ? AND model_version = ? AND prompt_version = ?",
        (group_id, model_version, prompt_version),
    ).fetchone() is not None


def save_ranking(conn, group_id: int, model_version: str, prompt_version: str, ranked_file_ids: list[int], roles: dict, rationale: str, raw_json: str) -> None:
    for i, fid in enumerate(ranked_file_ids, start=1):
        conn.execute(
            "INSERT OR REPLACE INTO rankings "
            "(group_id, file_id, rank, role, model_version, prompt_version, rationale, raw_json, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (group_id, fid, i, roles.get(fid), model_version, prompt_version, rationale, raw_json, _now()),
        )


# --- Curation: delete + composite-set marking (called from curate.py) ---

def delete_file(conn, file_id: int) -> None:
    """Removes every row referencing file_id. Doesn't touch anything on disk —
    callers move the RAW file via curation.mark_for_deletion before/after this."""
    conn.execute("DELETE FROM rankings WHERE file_id = ?", (file_id,))
    conn.execute("DELETE FROM similarity_group_members WHERE file_id = ?", (file_id,))
    conn.execute("DELETE FROM ai_evaluations WHERE file_id = ?", (file_id,))
    conn.execute("DELETE FROM technical_analysis WHERE file_id = ?", (file_id,))
    conn.execute("DELETE FROM metadata WHERE file_id = ?", (file_id,))
    conn.execute("DELETE FROM files WHERE id = ?", (file_id,))


def delete_shoot(conn, shoot_id: int) -> None:
    """Removes the shoot, its files, and its similarity groups. Doesn't touch
    anything on disk — callers move each file via curation.mark_for_deletion
    before calling this (they need file/preview paths, which this deletes)."""
    file_ids = [r["id"] for r in conn.execute("SELECT id FROM files WHERE shoot_id = ?", (shoot_id,)).fetchall()]
    for fid in file_ids:
        delete_file(conn, fid)
    conn.execute(
        "DELETE FROM rankings WHERE group_id IN (SELECT id FROM similarity_groups WHERE shoot_id = ?)",
        (shoot_id,),
    )
    conn.execute("DELETE FROM similarity_groups WHERE shoot_id = ?", (shoot_id,))
    conn.execute("DELETE FROM looks WHERE shoot_id = ?", (shoot_id,))
    conn.execute("DELETE FROM people WHERE shoot_id = ?", (shoot_id,))
    conn.execute("DELETE FROM shoots WHERE id = ?", (shoot_id,))


def set_group_composite(conn, group_id: int, is_composite: bool) -> bool:
    """Flags a similarity group as a composite source set (multiple frames
    meant to be combined, not a near-duplicate burst to cull down to one) —
    the viewer's Best Selection export then keeps every frame in the group
    instead of just the top-ranked one. Returns False if group_id doesn't exist."""
    cur = conn.execute(
        "UPDATE similarity_groups SET is_composite = ? WHERE id = ?",
        (1 if is_composite else 0, group_id),
    )
    return cur.rowcount > 0


def remove_file_from_group(conn, group_id: int, file_id: int) -> int | None:
    """Splits one file out of a similarity group — for correcting a
    perceptual-hash false positive where two visually-close but genuinely
    different photos got clustered as a "duplicate" burst. Deletes the
    file's ranking row for this group; if that leaves 0-1 members (no
    longer a burst), the whole group is dissolved too, since
    group_by_similarity never creates singleton groups in the first place.
    Returns the group's remaining member count, or None if file_id wasn't
    actually a member of group_id (no-op)."""
    exists = conn.execute(
        "SELECT 1 FROM similarity_group_members WHERE group_id = ? AND file_id = ?",
        (group_id, file_id),
    ).fetchone()
    if exists is None:
        return None
    conn.execute("DELETE FROM rankings WHERE group_id = ? AND file_id = ?", (group_id, file_id))
    conn.execute(
        "DELETE FROM similarity_group_members WHERE group_id = ? AND file_id = ?",
        (group_id, file_id),
    )
    remaining = conn.execute(
        "SELECT COUNT(*) FROM similarity_group_members WHERE group_id = ?", (group_id,)
    ).fetchone()[0]
    if remaining <= 1:
        conn.execute("DELETE FROM rankings WHERE group_id = ?", (group_id,))
        conn.execute("DELETE FROM similarity_group_members WHERE group_id = ?", (group_id,))
        conn.execute("DELETE FROM similarity_groups WHERE id = ?", (group_id,))
    return remaining


def shoots_owning_paths(conn, paths: list[str]) -> set[int]:
    """Shoot ids of every already-indexed file whose full_path is one of `paths`.
    Chunked so a large group can't exceed SQLite's bound-parameter limit."""
    owners: set[int] = set()
    for i in range(0, len(paths), 500):
        chunk = paths[i:i + 500]
        rows = conn.execute(
            f"SELECT DISTINCT shoot_id FROM files WHERE full_path IN ({','.join('?' * len(chunk))})", chunk
        ).fetchall()
        owners.update(r["shoot_id"] for r in rows)
    return owners


def repoint_shoot_files(conn, shoot_id: int, moves: list[tuple[str, str]], new_folder_path: str) -> None:
    """Moves an existing shoot to `new_folder_path` and rewrites only the file rows
    whose RAW actually moved (old_path -> new_path). Unlike update_shoot_paths, this
    leaves any of the shoot's files that didn't move untouched."""
    conn.execute("UPDATE shoots SET folder_path = ? WHERE id = ?", (new_folder_path, shoot_id))
    for old_path, new_path in moves:
        conn.execute(
            "UPDATE files SET full_path = ? WHERE shoot_id = ? AND full_path = ?",
            (new_path, shoot_id, old_path),
        )


def update_shoot_paths(conn, shoot_id: int, new_folder_path: str) -> int:
    """After a shoot's folder has been renamed/moved on disk, rewrites
    shoots.folder_path and every one of its files' full_path (same filename,
    new parent) to match. Returns the number of file rows updated."""
    conn.execute("UPDATE shoots SET folder_path = ? WHERE id = ?", (new_folder_path, shoot_id))
    rows = conn.execute("SELECT id, full_path FROM files WHERE shoot_id = ?", (shoot_id,)).fetchall()
    for r in rows:
        new_path = str(Path(new_folder_path) / Path(r["full_path"]).name)
        conn.execute("UPDATE files SET full_path = ? WHERE id = ?", (new_path, r["id"]))
    return len(rows)


def create_look(conn, shoot_id: int, name: str, start_filename: str) -> int:
    """Marks a look/outfit change starting at start_filename — every file in
    the shoot from there (in filename order) up to the next look's
    start_filename belongs to this one. No per-file column to maintain:
    membership is a live query (see PhotoCriticDatabase.shootGrid's join),
    so inserting/renaming/deleting a look never needs to touch `files`.
    Raises sqlite3.IntegrityError if a look already starts at this exact
    filename (ambiguous ordering)."""
    cur = conn.execute(
        "INSERT INTO looks (shoot_id, name, start_filename, created_at) VALUES (?, ?, ?, ?)",
        (shoot_id, name, start_filename, _now()),
    )
    return cur.lastrowid


def rename_look(conn, look_id: int, new_name: str) -> bool:
    cur = conn.execute("UPDATE looks SET name = ? WHERE id = ?", (new_name, look_id))
    return cur.rowcount > 0


def delete_look(conn, look_id: int) -> bool:
    """Removes a look boundary. Files that were in it fall back to whichever
    look (if any) starts earliest before them — or to no look at all."""
    cur = conn.execute("DELETE FROM looks WHERE id = ?", (look_id,))
    return cur.rowcount > 0


def set_shoot_separate_people(conn, shoot_id: int, enabled: bool) -> bool:
    """Toggles the "Multiple People" feature for a shoot — most shoots are one
    subject or an event with no need to split by person, so this stays off
    (and the person-marking UI hidden) unless explicitly turned on."""
    cur = conn.execute("UPDATE shoots SET separate_people = ? WHERE id = ?", (1 if enabled else 0, shoot_id))
    return cur.rowcount > 0


def create_person(conn, shoot_id: int, name: str, start_filename: str) -> int:
    """Marks a person boundary starting at start_filename — same live-query
    membership model as create_look (see its docstring). Raises
    sqlite3.IntegrityError if a person already starts at this exact filename."""
    cur = conn.execute(
        "INSERT INTO people (shoot_id, name, start_filename, created_at) VALUES (?, ?, ?, ?)",
        (shoot_id, name, start_filename, _now()),
    )
    return cur.lastrowid


def rename_person(conn, person_id: int, new_name: str) -> bool:
    cur = conn.execute("UPDATE people SET name = ? WHERE id = ?", (new_name, person_id))
    return cur.rowcount > 0


def delete_person(conn, person_id: int) -> bool:
    """Removes a person boundary. Files that were in it fall back to whichever
    person (if any) starts earliest before them — or to no person at all."""
    cur = conn.execute("DELETE FROM people WHERE id = ?", (person_id,))
    return cur.rowcount > 0


# --- Read-side queries for the web UI ---

# A file can carry more than one ai_evaluations row (one per model/prompt
# version, e.g. after a re-evaluation with a tuned prompt); this CTE keeps
# only the most recent row per file so joins against it don't fan out.
_LATEST_AE_CTE = """
    latest_ae AS (
        SELECT * FROM (
            SELECT *, ROW_NUMBER() OVER (
                PARTITION BY file_id ORDER BY created_at DESC, id DESC
            ) AS rn
            FROM ai_evaluations
        ) WHERE rn = 1
    )
"""


def list_shoots(conn) -> list[dict]:
    rows = conn.execute(f"""
        WITH {_LATEST_AE_CTE}
        SELECT s.id, s.folder_path, s.created_at,
               COUNT(DISTINCT f.id) AS total_files,
               COUNT(DISTINCT ae.file_id) AS evaluated_count,
               SUM(CASE WHEN ae.recommendation = 'KEEP' THEN 1 ELSE 0 END) AS keep_count,
               SUM(CASE WHEN ae.recommendation = 'MAYBE' THEN 1 ELSE 0 END) AS maybe_count,
               SUM(CASE WHEN ae.recommendation = 'REJECT' THEN 1 ELSE 0 END) AS reject_count
        FROM shoots s
        LEFT JOIN files f ON f.shoot_id = s.id
        LEFT JOIN latest_ae ae ON ae.file_id = f.id
        GROUP BY s.id
        ORDER BY s.created_at DESC
    """).fetchall()
    return [dict(r) for r in rows]


def get_shoot(conn, shoot_id: int) -> dict | None:
    row = conn.execute("SELECT * FROM shoots WHERE id = ?", (shoot_id,)).fetchone()
    return dict(row) if row else None


def get_shoot_grid(conn, shoot_id: int, sort: str = "score") -> list[dict]:
    # Keep the look/person join logic here in sync with PhotoCriticDatabase.swift's
    # shootGrid — same live-query membership model, two independent readers.
    order_by = {
        "score": "ae.overall_score DESC",
        "filename": "f.filename ASC",
    }.get(sort, "ae.overall_score DESC")

    rows = conn.execute(f"""
        WITH {_LATEST_AE_CTE}
        SELECT f.id AS file_id, f.filename, ta.preview_path,
               ae.overall_score, ae.classification, ae.recommendation,
               sgm.group_id, r.rank AS group_rank, r.role AS group_role, sg.is_composite,
               lk.id AS look_id, lk.name AS look_name,
               pp.id AS person_id, pp.name AS person_name
        FROM files f
        LEFT JOIN technical_analysis ta ON ta.file_id = f.id
        LEFT JOIN latest_ae ae ON ae.file_id = f.id
        LEFT JOIN similarity_group_members sgm ON sgm.file_id = f.id
        LEFT JOIN similarity_groups sg ON sg.id = sgm.group_id
        LEFT JOIN rankings r ON r.file_id = f.id AND r.group_id = sgm.group_id
        LEFT JOIN looks lk ON lk.id = (
            SELECT id FROM looks
            WHERE shoot_id = f.shoot_id AND start_filename <= f.filename
            ORDER BY start_filename DESC LIMIT 1
        )
        LEFT JOIN people pp ON pp.id = (
            SELECT id FROM people
            WHERE shoot_id = f.shoot_id AND start_filename <= f.filename
            ORDER BY start_filename DESC LIMIT 1
        )
        WHERE f.shoot_id = ?
        ORDER BY {order_by}
    """, (shoot_id,)).fetchall()
    return [dict(r) for r in rows]


def list_looks(conn, shoot_id: int) -> list[dict]:
    rows = conn.execute(
        "SELECT id, name, start_filename FROM looks WHERE shoot_id = ? ORDER BY start_filename ASC",
        (shoot_id,),
    ).fetchall()
    return [dict(r) for r in rows]


def list_people(conn, shoot_id: int) -> list[dict]:
    rows = conn.execute(
        "SELECT id, name, start_filename FROM people WHERE shoot_id = ? ORDER BY start_filename ASC",
        (shoot_id,),
    ).fetchall()
    return [dict(r) for r in rows]


def get_photo_detail(conn, file_id: int) -> dict | None:
    file_row = conn.execute(
        "SELECT f.*, s.folder_path AS shoot_folder FROM files f JOIN shoots s ON s.id = f.shoot_id WHERE f.id = ?",
        (file_id,),
    ).fetchone()
    if not file_row:
        return None
    result = dict(file_row)

    meta = conn.execute("SELECT * FROM metadata WHERE file_id = ?", (file_id,)).fetchone()
    result["metadata"] = dict(meta) if meta else None

    ta = conn.execute("SELECT * FROM technical_analysis WHERE file_id = ?", (file_id,)).fetchone()
    result["technical"] = dict(ta) if ta else None
    if result["technical"] and result["technical"].get("flags_json"):
        result["technical"]["flags"] = json.loads(result["technical"]["flags_json"])

    ev = conn.execute(
        "SELECT * FROM ai_evaluations WHERE file_id = ? ORDER BY created_at DESC, id DESC LIMIT 1",
        (file_id,),
    ).fetchone()
    if ev:
        result["evaluation"] = json.loads(ev["evaluation_json"])
    else:
        result["evaluation"] = None

    group = conn.execute("""
        SELECT sgm.group_id, r.rank, r.role, r.rationale
        FROM similarity_group_members sgm
        LEFT JOIN rankings r ON r.group_id = sgm.group_id AND r.file_id = sgm.file_id
        WHERE sgm.file_id = ?
    """, (file_id,)).fetchone()
    result["group"] = dict(group) if group else None

    return result


def get_group_detail(conn, group_id: int) -> dict | None:
    group_row = conn.execute("SELECT * FROM similarity_groups WHERE id = ?", (group_id,)).fetchone()
    if not group_row:
        return None
    result = dict(group_row)

    members = conn.execute(f"""
        WITH {_LATEST_AE_CTE}
        SELECT f.id AS file_id, f.filename, ta.preview_path,
               ae.overall_score, ae.classification, ae.evaluation_json,
               r.rank, r.role, r.rationale
        FROM similarity_group_members sgm
        JOIN files f ON f.id = sgm.file_id
        LEFT JOIN technical_analysis ta ON ta.file_id = f.id
        LEFT JOIN latest_ae ae ON ae.file_id = f.id
        LEFT JOIN rankings r ON r.group_id = sgm.group_id AND r.file_id = f.id
        WHERE sgm.group_id = ?
        ORDER BY r.rank ASC
    """, (group_id,)).fetchall()

    result["members"] = []
    for m in members:
        md = dict(m)
        md["evaluation"] = json.loads(md.pop("evaluation_json")) if md.get("evaluation_json") else None
        result["members"].append(md)

    result["rationale"] = result["members"][0]["rationale"] if result["members"] else None
    return result


# MARK: - Calibration (percentile/z-score, see photocritic/calibration.py for the computation)

def latest_evaluated_files(conn) -> list[dict]:
    """Every file's MOST RECENT evaluation (by created_at/id, matching the `latest_ae` CTE used
    everywhere else) that has a non-null overall_score, with its shoot_id -- the raw input
    calibration.py needs to compute percentile-within-shoot and percentile/z-within-library.
    Returns the ai_evaluations row id too, since that's the specific row calibration values get
    written back onto (a file can have several historical rows; only the latest one matters)."""
    rows = conn.execute(f"""
        WITH {_LATEST_AE_CTE}
        SELECT ae.id AS evaluation_id, ae.file_id, f.shoot_id, ae.overall_score
        FROM latest_ae ae
        JOIN files f ON f.id = ae.file_id
        WHERE ae.overall_score IS NOT NULL
    """).fetchall()
    return [dict(r) for r in rows]


def update_calibration(
    conn, evaluation_id: int, percentile_shoot: float, percentile_library: float,
    z_score_library: float, calibrated_score: float,
) -> None:
    conn.execute(
        "UPDATE ai_evaluations SET percentile_shoot = ?, percentile_library = ?, "
        "z_score_library = ?, calibrated_score = ? WHERE id = ?",
        (percentile_shoot, percentile_library, z_score_library, calibrated_score, evaluation_id),
    )


# MARK: - Posted-to (posting workflow)

def mark_posted(conn, file_id: int, platform: str) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO posted_to (file_id, platform, posted_at) VALUES (?, ?, ?)",
        (file_id, platform, _now()),
    )


def unmark_posted(conn, file_id: int, platform: str) -> None:
    conn.execute("DELETE FROM posted_to WHERE file_id = ? AND platform = ?", (file_id, platform))


def posted_platforms(conn, file_id: int) -> list[dict]:
    rows = conn.execute(
        "SELECT platform, posted_at FROM posted_to WHERE file_id = ? ORDER BY posted_at ASC",
        (file_id,),
    ).fetchall()
    return [dict(r) for r in rows]
