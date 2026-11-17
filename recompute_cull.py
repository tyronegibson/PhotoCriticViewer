"""One-off: recompute stage-1 technical cull for already-processed files using the
recalibrated center-crop metric, reading existing preview JPEGs (no raw re-decode)."""

import cv2

from photocritic import db, similarity, technical_cull

with db.connect() as conn:
    rows = conn.execute(
        "SELECT ta.file_id, ta.preview_path, ta.sharpness_score AS old_sharp, ta.flags_json AS old_flags, f.filename "
        "FROM technical_analysis ta JOIN files f ON f.id = ta.file_id ORDER BY f.filename"
    ).fetchall()

    for r in rows:
        img_bgr = cv2.imread(r["preview_path"])
        rgb = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)
        ta = technical_cull.analyze(rgb)
        ph = str(similarity.phash(r["preview_path"]))
        db.save_technical_analysis(conn, r["file_id"], ta, ph, r["preview_path"])
        changed = "" if r["old_flags"] == __import__("json").dumps(ta.flags) else "  <- flags changed"
        print(f"{r['filename']:20s} sharp {r['old_sharp']:7.1f} -> {ta.sharpness_score:7.1f}  flags={ta.flags}{changed}")
