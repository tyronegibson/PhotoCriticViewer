"""Runs before ANY test module in this package is imported -- `unittest discover` imports this
package's __init__.py first, before collecting/importing its submodules in whatever order it
finds them (alphabetical). This is the ONLY place that's guaranteed to run before any test
module's own `from photocritic import ...` does.

Why that guarantee matters: photocritic.config computes WORKSPACE_ROOT/DATABASE_PATH from
PHOTOCRITIC_WORKSPACE at MODULE IMPORT time, and photocritic.db.connect()'s default parameter
value is bound to config.DATABASE_PATH at THAT SAME import time -- both frozen for the rest of
the process, immune to the env var changing afterward. Previously, each test file that needed
isolation set this env var in its own module body (some via plain assignment, some via
setdefault), which worked only by accident: whichever test file's `photocritic` import happened
to run FIRST, in whatever order `unittest discover` found files, decided the real value for
every other test file in that run. Adding tests/test_scoring.py and tests/test_calibration.py
(which import photocritic.scoring/calibration -- and transitively photocritic.config -- without
setting this env var at all) broke that accident: discovery order put them first alphabetically,
so they froze config to the REAL production path, and tests/test_organize_twin.py and
tests/test_travel_sync.py silently wrote their synthetic fixtures into the real database and
the real evaluate.py-adjacent workspace for one full `unittest discover` run before this was
caught (see the conversation/incident writeup, not reproduced here) and cleaned up by hand.

Every in-process test file that touches `photocritic.*` now shares ONE synthetic workspace, set
here, before anything else can race it. Individual test files may still call
os.environ.setdefault("PHOTOCRITIC_WORKSPACE", ...) themselves for clarity/standalone-run
support -- it's a harmless no-op once this has already run -- but nothing should rely on being
first any more.
"""

import os
import tempfile
from pathlib import Path

_WORK = tempfile.mkdtemp(prefix="pc-tests-shared-ws-")
os.environ["PHOTOCRITIC_WORKSPACE"] = str(Path(_WORK) / "ws")
