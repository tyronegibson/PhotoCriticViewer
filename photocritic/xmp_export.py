"""XMP sidecar export — the interoperability path into Lightroom Classic,
Capture One, Adobe Bridge, and Photo Mechanic (all read xmp:Rating and
xmp:Label from a sidecar next to the RAW file).

Deliberately conservative: a sidecar is only ever CREATED, never modified.
If a .xmp already exists next to a RAW file (from Capture One, Lightroom,
or any other tool), it may hold real edits — crop, white balance, color
grade — that a naive XML merge could corrupt. Rather than attempt that
merge, files with an existing sidecar are skipped and reported, not touched.
This never touches the original RAW file itself either way.
"""

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape

from . import config

CLASSIFICATION_TO_RATING = {"A": 5, "B": 4, "C": 3, "D": 2, "F": 1}
RECOMMENDATION_TO_LABEL = {"KEEP": "Green", "MAYBE": "Yellow", "REJECT": "Red"}


@dataclass
class ExportPlan:
    file_id: int
    filename: str
    raw_path: Path
    xmp_path: Path
    action: str  # "create" | "skip_existing_xmp" | "skip_no_evaluation"
    rating: int | None = None
    label: str | None = None


def _build_description(evaluation: dict, group: dict | None) -> str:
    parts = [
        f"PhotoCritic Local: {evaluation['overall_score']:.1f}/100 "
        f"(class {evaluation['classification']}, {evaluation['recommendation']})."
    ]
    if evaluation.get("reasoning"):
        parts.append(evaluation["reasoning"])
    if group and group.get("role"):
        parts.append(f"Similarity group rank {group['rank']}: {group['role'].replace('_', ' ')}.")
    return " ".join(parts)


def build_xmp_content(evaluation: dict, group: dict | None, model_version: str) -> str:
    rating = CLASSIFICATION_TO_RATING.get(evaluation["classification"], 0)
    label = RECOMMENDATION_TO_LABEL.get(evaluation["recommendation"], "")
    description = escape(_build_description(evaluation, group))
    now = datetime.now(timezone.utc).isoformat()

    return f"""<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="PhotoCritic Local">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmp:Rating="{rating}"
    xmp:Label="{label}"
    xmp:MetadataDate="{now}">
   <dc:description>
    <rdf:Alt>
     <rdf:li xml:lang="x-default">{description}</rdf:li>
    </rdf:Alt>
   </dc:description>
   <dc:creator>
    <rdf:Seq>
     <rdf:li>PhotoCritic Local ({model_version})</rdf:li>
    </rdf:Seq>
   </dc:creator>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
"""


def plan_export(conn, shoot_id: int) -> list[ExportPlan]:
    """Read-only: computes what export_shoot would do without writing anything."""
    rows = conn.execute("""
        SELECT f.id AS file_id, f.filename, f.full_path, ae.evaluation_json
        FROM files f
        LEFT JOIN ai_evaluations ae ON ae.file_id = f.id
        WHERE f.shoot_id = ?
        ORDER BY f.filename
    """, (shoot_id,)).fetchall()

    plans = []
    for r in rows:
        raw_path = Path(r["full_path"])
        xmp_path = raw_path.with_suffix(".xmp")

        if r["evaluation_json"] is None:
            plans.append(ExportPlan(r["file_id"], r["filename"], raw_path, xmp_path, "skip_no_evaluation"))
            continue
        if xmp_path.exists():
            plans.append(ExportPlan(r["file_id"], r["filename"], raw_path, xmp_path, "skip_existing_xmp"))
            continue

        import json
        evaluation = json.loads(r["evaluation_json"])
        rating = CLASSIFICATION_TO_RATING.get(evaluation["classification"])
        label = RECOMMENDATION_TO_LABEL.get(evaluation["recommendation"])
        plans.append(ExportPlan(r["file_id"], r["filename"], raw_path, xmp_path, "create", rating, label))

    return plans


def apply_export(conn, plans: list[ExportPlan]) -> int:
    """Writes only the plans with action == 'create'. Returns count written."""
    import json

    written = 0
    for p in plans:
        if p.action != "create":
            continue
        if p.xmp_path.exists():
            # Re-check at write time in case something changed between plan and apply.
            continue

        ev_row = conn.execute(
            "SELECT evaluation_json FROM ai_evaluations WHERE file_id = ?", (p.file_id,)
        ).fetchone()
        evaluation = json.loads(ev_row["evaluation_json"])

        group_row = conn.execute("""
            SELECT r.rank, r.role FROM similarity_group_members sgm
            JOIN rankings r ON r.group_id = sgm.group_id AND r.file_id = sgm.file_id
            WHERE sgm.file_id = ?
        """, (p.file_id,)).fetchone()
        group = dict(group_row) if group_row else None

        content = build_xmp_content(evaluation, group, config.VLM_MODEL_VERSION)
        p.xmp_path.write_text(content, encoding="utf-8")
        written += 1

    return written
