"""Batch pipeline orchestrator. Resumable: every stage checks the database first
and skips files/groups that already have a row for the current model/prompt version."""

import concurrent.futures
import json
import shutil
import sqlite3
from datetime import datetime
from pathlib import Path

import numpy as np
from PIL import Image
from tqdm import tqdm

from . import calibration, config, db, metadata, scoring, similarity, technical_cull
from .curation import MARKER_DIRNAME
from .raw_decoder import default_decoder

RAW_EXTENSIONS = {".3fr", ".3FR"}

# A holding pen import_folder.py/CameraImportService.swift move redundant camera-roll
# copies into for the photographer to verify before deleting — never organize.py input.
DUPLICATES_DIRNAME = "Dupe"


def discover_raw_files(folder: Path) -> list[Path]:
    """Top level plus one level of subfolders — a prior multi-date run sorts
    files into `<folder>/<date>/` subfolders (see run_full_pipeline), so a
    resumed/re-run pass needs to find them there too. Never descends into
    `_Marked_for_Deletion` (files curation.py already pulled out of rotation)
    or `Dupe` (see DUPLICATES_DIRNAME), or into hidden folders — macOS keeps
    permission-restricted system ones (.DocumentRevisions-V100, .Spotlight-V100,
    .fseventsd, ...) at the root of every volume, and iterdir() on those raises
    PermissionError rather than just coming up empty."""
    found = [p for p in folder.iterdir() if p.suffix in RAW_EXTENSIONS]
    for sub in folder.iterdir():
        if not sub.is_dir() or sub.name in (MARKER_DIRNAME, DUPLICATES_DIRNAME) or sub.name.startswith("."):
            continue
        try:
            found.extend(p for p in sub.iterdir() if p.suffix in RAW_EXTENSIONS)
        except PermissionError:
            continue
    return sorted(found)


def _capture_date(path: Path, exif: dict | None) -> str:
    """EXIF capture date (YYYY-MM-DD) when readable, else the file's mtime date —
    the fallback covers RAWs exiftool can't parse rather than blocking grouping."""
    raw = exif.get("capture_time") if exif else None
    if raw:
        try:
            return datetime.strptime(raw, "%Y:%m:%d %H:%M:%S").strftime("%Y-%m-%d")
        except ValueError:
            pass
    return datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d")


def group_raw_files_by_date(paths: list[Path], exif_by_path: dict[Path, dict]) -> dict[str, list[Path]]:
    """Splits a folder's files into per-capture-date groups, each becoming its
    own shoot. A folder with a single date collapses to one group so its
    shoot keeps the plain folder path (same key existing DB rows use)."""
    groups: dict[str, list[Path]] = {}
    for path in paths:
        date = _capture_date(path, exif_by_path.get(path))
        groups.setdefault(date, []).append(path)
    return dict(sorted(groups.items()))


def _organize_into_date_folder(folder: Path, date: str, paths: list[Path]) -> list[Path]:
    """Physically moves this date-group's files (and matching .xmp sidecars)
    into a `<folder>/<date>/` subfolder — only called when a folder spans
    multiple dates, so the resulting per-date shoot folders are real,
    independently usable directories (e.g. for export_xmp.py) rather than a
    synthetic DB-only key. Idempotent: a file already sitting in its matching
    date subfolder from a prior run is left alone."""
    date_dir = folder / date
    date_dir.mkdir(exist_ok=True)
    moved = []
    for path in paths:
        if path.parent == date_dir:
            moved.append(path)
            continue
        target = date_dir / path.name
        shutil.move(str(path), str(target))
        moved.append(target)
        xmp = path.with_suffix(".xmp")
        if xmp.exists():
            shutil.move(str(xmp), str(date_dir / xmp.name))
    return moved


def preview_path_for(file_id: int) -> Path:
    """Keyed by the file's own DB id, not its path or filename stem: the camera
    restarts its filename counter across rolls (different photos routinely share
    a stem), and full_path itself isn't stable either — organize.py moves files
    into date subfolders and repoint_shoots.py rewrites it after the fact. A
    file's id is assigned once and never changes, so this can't silently orphan
    a preview the way both of those identities did."""
    return config.PREVIEWS_DIR / f"{file_id}.jpg"


def _make_preview(rgb, out_path: Path, long_edge: int):
    """Returns the resized (pre-compression) array alongside saving the JPEG, so
    technical cull can analyze it at a consistent, calibration-stable resolution
    instead of the full raw decode."""
    img = Image.fromarray(rgb)
    w, h = img.size
    scale = long_edge / max(w, h)
    resized = img.resize((round(w * scale), round(h * scale)), Image.LANCZOS)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    resized.save(out_path, "JPEG", quality=92)
    return np.asarray(resized)


def _decode_and_cull(file_id: int, path: Path, decoder):
    """Runs in a worker thread: pure decode/compute, no DB access — rawpy/cv2
    release the GIL during their C-extension calls, so this genuinely parallelizes
    across cores. DB writes happen back on the main thread as each future completes."""
    decoded = decoder.decode(path)
    preview_path = preview_path_for(file_id)
    preview_rgb = _make_preview(decoded.rgb, preview_path, config.ANALYSIS_LONG_EDGE)
    ta = technical_cull.analyze(preview_rgb)
    ph = str(similarity.phash(preview_path))
    return ta, ph, str(preview_path)


def run_ingest_and_cull(conn, shoot_id: int, raw_paths: list[Path], exif_by_path: dict[Path, dict]) -> list[int]:
    """Extract metadata, run stage-1 technical cull (decode step parallelized
    across INGEST_WORKERS threads) for `raw_paths`. `exif_by_path` is the batch
    EXIF read already done for date-grouping — reused here so each file isn't
    read twice; a file missing from it falls back to a per-file exiftool call.
    Returns the list of file_ids processed (including previously-completed ones)."""
    decoder = default_decoder()
    file_ids = []
    file_id_by_path = {}
    needs_cull = []

    for path in raw_paths:
        st = path.stat()
        file_id = db.get_or_create_file(
            conn, shoot_id, path.name, str(path), st.st_size, st.st_mtime
        )
        file_ids.append(file_id)
        file_id_by_path[path] = file_id

        if not db.has_metadata(conn, file_id):
            try:
                fields = exif_by_path.get(path) or metadata.read_exif(path)
                db.save_metadata(conn, file_id, fields)
            except Exception as e:
                db.save_metadata(conn, file_id, {"raw": {"error": str(e)}})

        if not db.has_technical_analysis(conn, file_id):
            needs_cull.append(path)
    conn.commit()

    if needs_cull:
        with concurrent.futures.ThreadPoolExecutor(max_workers=config.INGEST_WORKERS) as executor:
            futures = {executor.submit(_decode_and_cull, file_id_by_path[path], path, decoder): path for path in needs_cull}
            for i, future in enumerate(tqdm(concurrent.futures.as_completed(futures), total=len(futures), desc="ingest+cull"), start=1):
                path = futures[future]
                try:
                    ta, ph, preview_path = future.result()
                except Exception as e:
                    tqdm.write(f"  decode FAILED for {path.name}: {e}")
                    continue
                db.save_technical_analysis(conn, file_id_by_path[path], ta, ph, preview_path)
                # Commit every file, not just periodically: each RAW decode
                # this is interleaved with can take real time, and an open
                # transaction holds SQLite's write lock the whole time it's
                # uncommitted — a competing writer (e.g. evaluate.py running
                # concurrently) can starve past its busy_timeout waiting for a
                # multi-file batch to finish. A single-row commit is cheap.
                conn.commit()
                # Machine-readable progress line — separate from tqdm's bar
                # (which only renders sensibly on a live terminal) so the
                # Swift app's log viewer can parse a real percentage out of a
                # file-redirected, non-tty log.
                print(f"PROGRESS ingest+cull: {i}/{len(needs_cull)}", flush=True)
        conn.commit()

    return file_ids


def run_similarity_grouping(conn, shoot_id: int, file_ids: list[int]) -> list[int]:
    """Group files by perceptual-hash similarity. Only considers files not
    already in a group for this shoot — e.g. photos added later via a fresh
    camera import into an already-organized shoot. Each such file first
    checks for a match against every *existing* group (merging in if found,
    so a new near-duplicate of an old, already-reviewed photo lands in that
    same burst instead of being stranded); whatever's left over is clustered
    among itself into brand-new groups, same as before. Existing groups'
    rows (and any composite-set flag) are never touched directly — merging
    only adds a similarity_group_members row. Returns every group_id for the
    shoot, old and newly created."""
    existing_group_ids = [
        r["id"] for r in conn.execute(
            "SELECT id FROM similarity_groups WHERE shoot_id = ? AND method = 'phash_v1'", (shoot_id,)
        ).fetchall()
    ]

    if not file_ids:
        return existing_group_ids

    already_grouped = {
        r["file_id"] for r in conn.execute(
            f"SELECT file_id FROM similarity_group_members WHERE file_id IN ({','.join('?' * len(file_ids))})",
            file_ids,
        ).fetchall()
    }
    ungrouped_file_ids = [fid for fid in file_ids if fid not in already_grouped]
    if not ungrouped_file_ids:
        return existing_group_ids

    rows = conn.execute(
        f"SELECT file_id, phash FROM technical_analysis WHERE file_id IN "
        f"({','.join('?' * len(ungrouped_file_ids))})",
        ungrouped_file_ids,
    ).fetchall()
    id_by_file = {r["file_id"]: r["phash"] for r in rows}

    import imagehash

    # Try each ungrouped file against every existing group's members first —
    # a match merges it in (add_files_to_group) rather than leaving it to
    # only ever cluster with other newly-added files.
    still_ungrouped = list(ungrouped_file_ids)
    if existing_group_ids:
        existing_hashes_by_group: dict[int, list] = {}
        for r in conn.execute(
            f"SELECT sgm.group_id, ta.phash FROM similarity_group_members sgm "
            f"JOIN technical_analysis ta ON ta.file_id = sgm.file_id "
            f"WHERE sgm.group_id IN ({','.join('?' * len(existing_group_ids))})",
            existing_group_ids,
        ).fetchall():
            if r["phash"]:
                existing_hashes_by_group.setdefault(r["group_id"], []).append(imagehash.hex_to_hash(r["phash"]))

        remaining = []
        for fid in ungrouped_file_ids:
            ph = id_by_file.get(fid)
            candidate = imagehash.hex_to_hash(ph) if ph else None
            matched_group = next(
                (gid for gid, hashes in existing_hashes_by_group.items()
                 if candidate is not None and any(candidate - h <= config.SIMILARITY_HASH_THRESHOLD for h in hashes)),
                None,
            ) if candidate is not None else None
            if matched_group is not None:
                db.add_files_to_group(conn, matched_group, [fid])
                existing_hashes_by_group[matched_group].append(candidate)
            else:
                remaining.append(fid)
        still_ungrouped = remaining

    hashes = {str(fid): imagehash.hex_to_hash(id_by_file[fid]) for fid in still_ungrouped if id_by_file.get(fid)}
    clusters = similarity.group_by_similarity(hashes)

    group_ids = list(existing_group_ids)
    for cluster in clusters:
        member_file_ids = [int(s) for s in cluster]
        group_id = db.create_similarity_group(conn, shoot_id, "phash_v1", member_file_ids)
        group_ids.append(group_id)
    return group_ids


def run_evaluations(conn, file_ids: list[int]) -> None:
    """Batched via mlx_vlm.batch_generate (config.EVAL_BATCH_SIZE per chunk) —
    ~5x faster per-image than one-call-per-image (see config.py for the measured
    numbers and the Metal memory ceiling that sets the batch size)."""
    from .vision_model import get_shared_model

    prompt_text = config.EVALUATION_PROMPT_PATH.read_text()

    rows = conn.execute(
        f"SELECT id FROM files WHERE id IN ({','.join('?' * len(file_ids))})",
        file_ids,
    ).fetchall()
    preview_by_file = {}
    for fid in file_ids:
        pr = conn.execute(
            "SELECT preview_path FROM technical_analysis WHERE file_id = ?", (fid,)
        ).fetchone()
        if pr:
            preview_by_file[fid] = pr["preview_path"]

    candidates = [
        (row["id"], preview_by_file[row["id"]])
        for row in rows
        if row["id"] in preview_by_file
        and not db.has_evaluation(conn, row["id"], config.VLM_MODEL_VERSION, config.EVALUATION_PROMPT_VERSION)
    ]
    # A preview file missing from disk (pruned, moved, or never finished writing) used to crash
    # mlx_vlm.batch_generate for its ENTIRE chunk -- 11 other, perfectly fine files silently
    # never got evaluated in that run, with no indication why. Filtered out here instead, so
    # one missing file costs exactly itself.
    pending = []
    for file_id, preview_path in candidates:
        if Path(preview_path).exists():
            pending.append((file_id, preview_path))
        else:
            print(f"  SKIPPED file_id={file_id}: preview missing on disk: {preview_path}")
    if not pending:
        return

    model = get_shared_model()
    with tqdm(total=len(pending), desc="evaluate") as pbar:
        for start in range(0, len(pending), config.EVAL_BATCH_SIZE):
            chunk = pending[start : start + config.EVAL_BATCH_SIZE]
            results = model.evaluate_batch([p for _, p in chunk], prompt_text)
            for (file_id, _), result in zip(chunk, results):
                if result["ok"]:
                    # The model (evaluation_v4+) only returns category scores/reasons; code
                    # computes overall_score/classification/recommendation from them here,
                    # using the weights/thresholds this exact row is tagged with below.
                    scored = scoring.score_in_code(result["parsed"])
                    db.save_evaluation(
                        conn, file_id, model.version_tag, config.EVALUATION_PROMPT_VERSION, scored,
                        temperature=config.EVALUATION_TEMPERATURE, weights=config.CATEGORY_WEIGHTS,
                        sample_count=max(1, config.EVALUATION_SELF_CONSISTENCY_N),
                    )
                else:
                    tqdm.write(f"  eval FAILED for file_id={file_id}: {result['error']}")
            conn.commit()  # checkpoint after each chunk, not just at the end
            pbar.update(len(chunk))
            done = min(start + config.EVAL_BATCH_SIZE, len(pending))
            print(f"PROGRESS evaluate: {done}/{len(pending)}", flush=True)


def run_look_detection(conn, shoot_id: int) -> None:
    """Auto-creates look/outfit boundaries from each evaluation's
    outfit_description (evaluation_v2+ only — reads it straight out of the
    stored evaluation_json rather than needing its own column), in filename
    order: a new look starts wherever the description changes from the
    previous non-"unclear" one. Skipped entirely if the shoot already has
    ANY look — manual or previously auto-detected — so this never overwrites
    a photographer's own curation, and never re-runs pointlessly every time
    Evaluate Shoot is clicked again."""
    if conn.execute("SELECT 1 FROM looks WHERE shoot_id = ?", (shoot_id,)).fetchone():
        return

    rows = conn.execute(
        "SELECT f.filename, ae.evaluation_json FROM files f "
        "JOIN ai_evaluations ae ON ae.file_id = f.id "
        "WHERE f.shoot_id = ? AND ae.model_version = ? AND ae.prompt_version = ? "
        "ORDER BY f.filename ASC",
        (shoot_id, config.VLM_MODEL_VERSION, config.EVALUATION_PROMPT_VERSION),
    ).fetchall()

    previous_description = None
    for row in rows:
        description = (json.loads(row["evaluation_json"]).get("outfit_description") or "").strip()
        if not description or description.lower() == "unclear" or description == previous_description:
            continue
        try:
            db.create_look(conn, shoot_id, description, row["filename"])
        except sqlite3.IntegrityError:
            pass  # a look already starts at this exact filename — leave it alone
        previous_description = description


def run_rankings(conn, group_ids: list[int]) -> None:
    from .vision_model import get_shared_model

    prompt_text = config.RANKING_PROMPT_PATH.read_text()
    model = None
    total = len(group_ids)

    for idx, group_id in enumerate(tqdm(group_ids, desc="rank groups"), start=1):
        # group_fully_ranked, not has_ranking: a group that merged in a new
        # member (run_similarity_grouping) has old rows but not one for the
        # new file, and strongest/weakest is meaningless without comparing
        # every current member — so it needs a full re-rank, not a skip.
        if db.group_fully_ranked(conn, group_id, config.VLM_MODEL_VERSION, config.RANKING_PROMPT_VERSION):
            print(f"PROGRESS rankings: {idx}/{total}", flush=True)
            continue
        members = conn.execute(
            "SELECT sgm.file_id, ta.preview_path FROM similarity_group_members sgm "
            "JOIN technical_analysis ta ON ta.file_id = sgm.file_id "
            "WHERE sgm.group_id = ?",
            (group_id,),
        ).fetchall()
        file_ids = [m["file_id"] for m in members]
        preview_paths = [m["preview_path"] for m in members]

        if model is None:
            model = get_shared_model()
        result = model.rank_group(preview_paths, prompt_text)
        if not result["ok"]:
            tqdm.write(f"  ranking FAILED for group_id={group_id}: {result['error']}")
            print(f"PROGRESS rankings: {idx}/{total}", flush=True)
            continue

        parsed = result["parsed"]
        order_1indexed = parsed.get("ranking") or []
        ranked_file_ids = [file_ids[i - 1] for i in order_1indexed if 1 <= i <= len(file_ids)]
        # anything the model omitted goes at the end, in original order
        ranked_file_ids += [fid for fid in file_ids if fid not in ranked_file_ids]

        # Roles are derived positionally from `ranking` alone, not from the separate
        # strongest/second/weakest scalar fields — those can (and did, in testing)
        # contradict the ranking array and each other. One ordered list can't self-contradict.
        roles = {}
        if ranked_file_ids:
            roles[ranked_file_ids[0]] = "strongest"
        if len(ranked_file_ids) > 2:
            roles[ranked_file_ids[1]] = "second_strongest"
        if len(ranked_file_ids) > 1:
            roles[ranked_file_ids[-1]] = "weakest"

        db.save_ranking(
            conn, group_id, config.VLM_MODEL_VERSION, config.RANKING_PROMPT_VERSION,
            ranked_file_ids, roles, parsed.get("rationale", ""), result["raw"],
        )
        # Same reasoning as run_ingest_and_cull's per-file commit: each
        # group's VLM ranking call can take real time, so commit as soon as
        # its row is written rather than leaving the whole shoot's rankings
        # in one long-held transaction a concurrent writer could stall on.
        conn.commit()
        print(f"PROGRESS rankings: {idx}/{total}", flush=True)


def run_organize(folder: Path) -> list[int]:
    """Phase 1 — fast, CPU-only, safe to run over an entire unsorted archive.
    Discovers RAW files, sorts a multi-date folder into per-date `<date>/`
    subfolders (see _organize_into_date_folder), then for each resulting
    shoot: decodes + technical-culls + extracts EXIF for every file, and
    clusters near-duplicate bursts by perceptual hash. No GPU/VLM work
    happens here. Returns the shoot_ids touched, so a caller can list them
    for the photographer to choose which to actually evaluate.

    A folder that's all one capture date is left exactly as dropped — same
    single-shoot behavior as before this function existed."""
    config.ensure_workspace_dirs()
    shoot_ids: list[int] = []

    with db.connect() as conn:
        db.init_schema(conn)

        raw_paths = discover_raw_files(folder)
        if not raw_paths:
            print(f"No RAW files found in {folder}")
            return shoot_ids

        # Re-running over an already-organized archive used to re-read EXIF for
        # every file (~60s for ~15k files) just to re-derive dates the DB
        # already holds. Only files with no stored capture time go to exiftool.
        known = db.known_capture_times(conn, [str(p) for p in raw_paths])
        new_paths = [p for p in raw_paths if str(p) not in known]
        exif_by_path = metadata.read_exif_batch(new_paths)
        for p in raw_paths:
            if str(p) in known:
                exif_by_path[p] = {"capture_time": known[str(p)]}
        print(f"EXIF read for {len(new_paths)} new file(s); "
              f"{len(raw_paths) - len(new_paths)} already indexed, skipped.", flush=True)
        date_groups = group_raw_files_by_date(raw_paths, exif_by_path)

        if len(date_groups) > 1:
            print(f"{len(raw_paths)} files span {len(date_groups)} capture dates — "
                  f"sorting into per-date subfolders and separate shoots:")
            for date, paths in date_groups.items():
                print(f"  {date}: {len(paths)} file(s)")

        # Validate every group before anything moves on disk, so a refusal can't leave
        # half the folder sorted. Indexed rows still hold pre-move paths at this point, so
        # this is also the only moment the owning shoot can be read reliably.
        plan: dict[str, tuple[str, int | None]] = {}
        seen_owners: dict[int, str] = {}
        for date, paths in date_groups.items():
            shoot_folder_path = str(folder) if len(date_groups) == 1 else str(folder / date)
            owners = db.shoots_owning_paths(conn, [str(p) for p in paths])
            if len(owners) > 1:
                raise RuntimeError(
                    f"{date}: these photos are already indexed under {len(owners)} different shoots "
                    f"{sorted(owners)}. Not guessing which should survive — resolve manually.")
            owner_id = next(iter(owners), None)
            if owner_id is not None:
                clash = db.get_shoot_by_folder(conn, shoot_folder_path)
                if clash is not None and clash != owner_id:
                    raise RuntimeError(
                        f"{date}: cannot repoint shoot {owner_id} to {shoot_folder_path} — shoot {clash} "
                        f"already lives there. Resolve manually.")
                if owner_id in seen_owners:
                    raise RuntimeError(
                        f"shoot {owner_id} would be repointed for both {seen_owners[owner_id]} and {date}. "
                        f"Resolve manually.")
                seen_owners[owner_id] = date
            plan[date] = (shoot_folder_path, owner_id)

        total_groups = len(date_groups)
        for group_idx, (date, paths) in enumerate(date_groups.items(), start=1):
            shoot_folder_path, owner_id = plan[date]

            if len(date_groups) == 1:
                organized_paths = paths
            else:
                organized_paths = _organize_into_date_folder(folder, date, paths)

            # exif_by_path was read against the pre-move paths; remap it 1:1
            # to wherever each file actually ended up so run_ingest_and_cull's
            # lookups still hit.
            group_exif = {
                new: exif_by_path[old] for old, new in zip(paths, organized_paths) if old in exif_by_path
            }

            if owner_id is None:
                shoot_id = db.get_or_create_shoot(conn, shoot_folder_path)
            else:
                shoot_id = owner_id
                moves = [(str(old), str(new)) for old, new in zip(paths, organized_paths) if old != new]
                if moves:
                    db.repoint_shoot_files(conn, shoot_id, moves, shoot_folder_path)
                    conn.commit()  # right after the on-disk move, so a crash in between leaves little to reconcile
                    print(f"  repointed existing shoot {shoot_id} to {shoot_folder_path} "
                          f"({len(moves)} file(s) moved)", flush=True)

            file_ids = run_ingest_and_cull(conn, shoot_id, organized_paths, group_exif)
            conn.commit()

            run_similarity_grouping(conn, shoot_id, file_ids)
            conn.commit()

            shoot_ids.append(shoot_id)
            print(f"PROGRESS organize: {group_idx}/{total_groups}", flush=True)

    return shoot_ids


def run_evaluate(shoot_id: int) -> None:
    """Phase 2 — the slow, GPU-heavy stage: VLM scoring of every photo already
    ingested into `shoot_id`, then head-to-head ranking of its similarity
    groups. Meant to be run selectively, per shoot, once run_organize has
    made an archive's date-shoots visible to choose from."""
    with db.connect() as conn:
        db.init_schema(conn)

        file_ids = [r["id"] for r in conn.execute("SELECT id FROM files WHERE shoot_id = ?", (shoot_id,)).fetchall()]
        if not file_ids:
            print(f"No files found for shoot {shoot_id}")
            return
        group_ids = [
            r["id"] for r in conn.execute(
                "SELECT id FROM similarity_groups WHERE shoot_id = ?", (shoot_id,)
            ).fetchall()
        ]

        run_evaluations(conn, file_ids)
        conn.commit()

        run_look_detection(conn, shoot_id)
        conn.commit()

        run_rankings(conn, group_ids)
        conn.commit()

        # Adding/changing any score shifts everyone's percentile slightly, so this recomputes
        # calibration library-wide, not just for shoot_id -- cheap even at a few thousand files.
        calibration.recompute_all(conn)
        conn.commit()


def recompute_overall_scores(conn, prompt_version_prefix: str = "evaluation_v4") -> int:
    """Re-derives overall_score/classification/recommendation from each row's ALREADY-STORED
    category scores, using the CURRENT config.CATEGORY_WEIGHTS/OVERALL_SCORE_CENTER/
    OVERALL_SCORE_CONTRAST/GRADE_THRESHOLDS/RECOMMENDATION_THRESHOLDS -- no model call, so this
    is cheap and instant, meant for exactly one situation: you tuned a weight or the contrast
    stretch and want existing rows to reflect it without re-running evaluate.py.

    Scoped to prompt_version_prefix (default "evaluation_v4", i.e. "any v4-family row") rather
    than every row ever written: v1-v3 rows had the model pick its own overall_score/
    classification/recommendation directly, so there's no code-computed formula to re-apply to
    them, and retroactively replacing a model's own historical judgment with a code formula it
    never used would misrepresent what that old row actually recorded. Also recomputes
    calibration afterward, since changing any overall_score shifts everyone's percentile."""
    rows = conn.execute(
        "SELECT id, file_id, evaluation_json FROM ai_evaluations WHERE prompt_version LIKE ?",
        (f"{prompt_version_prefix}%",),
    ).fetchall()
    updated = 0
    for row in rows:
        parsed = json.loads(row["evaluation_json"])
        scored = scoring.score_in_code(parsed)
        conn.execute(
            "UPDATE ai_evaluations SET overall_score = ?, classification = ?, recommendation = ?, "
            "evaluation_json = ? WHERE id = ?",
            (scored["overall_score"], scored["classification"], scored["recommendation"],
             json.dumps(scored), row["id"]),
        )
        updated += 1
    calibration.recompute_all(conn)
    return updated


def evaluate_specific_files(file_ids: list[int]) -> dict:
    """The /critique-by-ids path: evaluates ONLY these files, not their whole shoot(s). Skips
    look detection entirely (it's a whole-shoot derived feature keyed off filename order across
    every evaluated file, not something that makes sense to force for a handful of ad hoc ids),
    but still refreshes ranking for any similarity group one of these files belongs to -- a
    re-scored burst member should still get its burst re-ranked. Returns a small summary dict
    for the API's job result."""
    with db.connect() as conn:
        db.init_schema(conn)

        existing = {
            r["id"] for r in conn.execute(
                f"SELECT id FROM files WHERE id IN ({','.join('?' * len(file_ids))})", file_ids
            ).fetchall()
        }
        missing = [fid for fid in file_ids if fid not in existing]

        run_evaluations(conn, file_ids)
        conn.commit()

        group_ids = sorted({
            r["group_id"] for r in conn.execute(
                f"SELECT DISTINCT group_id FROM similarity_group_members WHERE file_id IN "
                f"({','.join('?' * len(file_ids))})", file_ids
            ).fetchall()
        })
        if group_ids:
            run_rankings(conn, group_ids)
            conn.commit()

        calibration.recompute_all(conn)
        conn.commit()

    return {"evaluated": sorted(existing), "missing": missing, "groups_reranked": group_ids}


def run_full_pipeline(folder: Path) -> None:
    """Convenience: organize + evaluate everything in one call — the original
    all-in-one behavior, appropriate for a folder that's already known to be
    one (or a few) real shoot(s). For an unsorted archive, call run_organize
    first and evaluate specific shoot_ids afterward instead."""
    for shoot_id in run_organize(folder):
        run_evaluate(shoot_id)
