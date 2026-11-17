"""Black-box integration tests for PhotoCriticViewer's local control API
(LocalAPIServer.swift). Launches the real, already-built .app directly as a subprocess
against an isolated synthetic workspace -- overriding workspaceRootPath via `defaults`,
the same mechanism WorkspaceConfig.swift documents for pointing a second machine at its
own workspace -- so nothing here touches the real photo library or database. Drives it
over plain HTTP exactly as an external client would, using only the stdlib.

Deliberately does NOT let a /critique job's evaluate.py run to completion: that means
loading the ~30B-parameter vision model, and this project has a standing policy against
running AI evaluation without being asked. The critique test confirms the job is accepted
and starts, then kills that one subprocess -- scoped to this test's own unique workspace
path, so it can never match a real evaluate.py run -- well before it would get anywhere
near the model.

Seeding a fake evaluation (for the /results tests) runs through a one-off subprocess using
the project's own .venv interpreter, rather than importing photocritic in this test's own
process -- other test files in this suite share one synthetic workspace via
os.environ.setdefault at module scope (see test_travel_sync.py's comment), and importing
photocritic here directly would race that and risk writing into the wrong database.

Requires the app to already be built and installed to /Applications (xcodebuild ...
PhotoCriticViewer, as done throughout this project) -- this does not build it itself.

Run: python3 -m unittest tests.test_local_api   (from the project root)
"""

import json
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT))

BUNDLE_ID = "com.photocritic.viewer"
APP_BINARY = Path("/Applications/PhotoCriticViewer.app/Contents/MacOS/PhotoCriticViewer")
VENV_PYTHON = PROJECT / ".venv/bin/python3"
BASE = "http://127.0.0.1:8765"


def defaults_write(key: str, value: str) -> None:
    subprocess.run(["defaults", "write", BUNDLE_ID, key, value], check=True)


def defaults_delete(key: str) -> None:
    subprocess.run(["defaults", "delete", BUNDLE_ID, key], stderr=subprocess.DEVNULL)


def request(method: str, path: str, token: str | None = None, body: dict | None = None, timeout: float = 10):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode())


def wait_for_health(timeout: float = 20) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            status, _ = request("GET", "/health", timeout=2)
            if status == 200:
                return True
        except Exception:
            pass
        time.sleep(0.3)
    return False


@unittest.skipUnless(APP_BINARY.exists(), "PhotoCriticViewer.app is not built/installed at /Applications")
class LocalAPITest(unittest.TestCase):
    """setUpClass does the one real /open call and seeds one fake evaluation; every test
    method below is an independent, order-agnostic assertion against that fixed state
    (unittest runs test methods alphabetically, not declaration order, so nothing here can
    depend on another *test method* running first)."""

    @classmethod
    def setUpClass(cls):
        # CRITICAL: a PhotoCriticViewer instance already running (e.g. left open from manual
        # testing) would already hold port 8765, bound to the REAL workspace from before this
        # test ever touched workspaceRootPath. The new instance launched below would then fail
        # to bind the port, while wait_for_health() below would happily get a 200 from that
        # STALE instance instead -- and every request this test makes after that would hit the
        # real production database, not this test's sandbox. This happened for real once
        # (caught and cleaned up by hand) before this kill was added here. Never remove it.
        subprocess.run(["pkill", "-x", "PhotoCriticViewer"], stderr=subprocess.DEVNULL)
        for _ in range(20):
            if subprocess.run(["pgrep", "-x", "PhotoCriticViewer"], stdout=subprocess.DEVNULL).returncode != 0:
                break
            time.sleep(0.2)

        cls.workspace = Path(tempfile.mkdtemp(prefix="pc-api-test-ws-"))
        # Under cls.workspace, not /tmp -- LocalAPIPaths only allows the home directory and
        # the configured workspace root, and workspaceRootPath is about to be set to
        # cls.workspace below, so anything /open needs to reach must live under it.
        cls.source = cls.workspace / "incoming"
        cls.source.mkdir()
        # Not a real RAW -- organize.py's decode step fails open and still creates the
        # file/shoot rows (same as tests/test_organize_twin.py relies on), which is all
        # this needs to exercise the API's plumbing.
        (cls.source / "A1.3FR").write_bytes(b"x" * 500)

        defaults_write("workspaceRootPath", str(cls.workspace))
        defaults_delete("localAPIAllowedRoots")  # fall back to the default (home + workspace)

        cls.proc = subprocess.Popen([str(APP_BINARY)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not wait_for_health():
            cls._cleanup()
            raise RuntimeError("PhotoCriticViewer did not come up on :8765 in time")

        # Belt-and-suspenders on top of the pkill above: confirm port 8765 is actually held by
        # the PID this test just launched, not some other process that won the bind race.
        held_by = subprocess.run(
            ["lsof", "-ti", "tcp:8765"], capture_output=True, text=True
        ).stdout.strip()
        if held_by != str(cls.proc.pid):
            cls._cleanup()
            raise RuntimeError(
                f"port 8765 is held by pid {held_by!r}, not this test's own pid {cls.proc.pid} "
                "-- refusing to continue against a process this test doesn't control"
            )

        cls.token = (Path.home() / ".photocritic" / "api_token").read_text().strip()

        status, body = request("POST", "/open", token=cls.token, body={"path": str(cls.source)}, timeout=60)
        if status != 200:
            cls._cleanup()
            raise RuntimeError(f"setup /open failed: {status} {body}")
        cls.file_id = body["photos"][0]["id"]

        seed = (
            "from photocritic import db\n"
            "with db.connect() as conn:\n"
            "    db.init_schema(conn)\n"
            f"    db.save_evaluation(conn, {cls.file_id}, 'test-model', 'test-prompt', {{\n"
            "        'overall_score': 77.0, 'classification': 'B', 'recommendation': 'MAYBE',\n"
            "        'scores': {'composition': 7.0}, 'reasoning': 'test critique text',\n"
            "        'technical_issues': [], 'artistic_choices': [], 'strengths': [], 'weaknesses': [],\n"
            "    })\n"
            "    conn.commit()\n"
        )
        seed_result = subprocess.run(
            [str(VENV_PYTHON), "-c", seed],
            cwd=PROJECT, capture_output=True, text=True,
            env={"PHOTOCRITIC_WORKSPACE": str(cls.workspace), "PATH": "/usr/bin:/bin"},
        )
        if seed_result.returncode != 0:
            cls._cleanup()
            raise RuntimeError(f"seeding a fake evaluation failed: {seed_result.stderr}")

    @classmethod
    def _cleanup(cls):
        proc = getattr(cls, "proc", None)
        if proc:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        defaults_delete("workspaceRootPath")
        shutil.rmtree(getattr(cls, "workspace", "/nonexistent"), ignore_errors=True)
        shutil.rmtree(getattr(cls, "source", "/nonexistent"), ignore_errors=True)

    @classmethod
    def tearDownClass(cls):
        cls._cleanup()

    # --- auth ---

    def test_health_needs_no_auth(self):
        status, body = request("GET", "/health")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertEqual(body["app"], "PhotoCriticViewer")

    def test_missing_token_is_401(self):
        status, body = request("GET", "/results")
        self.assertEqual(status, 401)
        self.assertEqual(body["error"]["code"], "unauthorized")

    def test_wrong_token_is_401(self):
        status, _ = request("GET", "/results", token="not-the-real-token")
        self.assertEqual(status, 401)

    def test_openapi_spec_is_served_and_authenticated(self):
        status, _ = request("GET", "/openapi.json")
        self.assertEqual(status, 401)  # not GET /health -- auth is required
        status, body = request("GET", "/openapi.json", token=self.token)
        self.assertEqual(status, 200)
        self.assertEqual(body["openapi"], "3.0.3")

    # --- /open ---

    def test_open_rejects_path_outside_allowed_roots(self):
        status, body = request("POST", "/open", token=self.token, body={"path": "/etc"})
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "invalid_path")

    def test_open_rejects_missing_path(self):
        status, body = request("POST", "/open", token=self.token, body={})
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "missing_path")

    def test_setup_open_found_the_one_photo(self):
        # Re-asserts what setUpClass's /open call returned, so a regression there shows up
        # as a normal test failure rather than only as a setup exception.
        self.assertIsNotNone(self.file_id)

    # --- /results ---

    def test_results_lists_the_seeded_evaluation(self):
        status, body = request("GET", "/results", token=self.token)
        self.assertEqual(status, 200)
        self.assertEqual(len(body), 1)
        row = body[0]
        self.assertEqual(row["id"], self.file_id)
        self.assertEqual(row["filename"], "A1.3FR")
        self.assertEqual(row["score"], 77.0)
        self.assertEqual(row["classification"], "B")
        self.assertEqual(row["recommendation"], "MAYBE")
        self.assertEqual(row["critique"], "test critique text")
        self.assertEqual(row["scores"]["composition"], 7.0)
        self.assertIn("MAYBE", row["tags"])

    def test_results_min_score_filter_excludes_it(self):
        status, body = request("GET", "/results?min_score=90", token=self.token)
        self.assertEqual(status, 200)
        self.assertEqual(body, [])

    def test_results_min_score_filter_includes_it(self):
        status, body = request("GET", "/results?min_score=50", token=self.token)
        self.assertEqual(status, 200)
        self.assertEqual(len(body), 1)

    def test_result_detail_by_id(self):
        status, body = request("GET", f"/results/{self.file_id}", token=self.token)
        self.assertEqual(status, 200)
        self.assertEqual(body["critique"], "test critique text")
        self.assertEqual(body["scores"]["composition"], 7.0)

    def test_result_detail_unknown_id_is_404(self):
        status, body = request("GET", "/results/999999999", token=self.token)
        self.assertEqual(status, 404)

    # --- /critique job flow ---

    def test_critique_rejects_missing_ids_and_path(self):
        status, body = request("POST", "/critique", token=self.token, body={})
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "missing_ids_or_path")

    def test_critique_unknown_path_is_404(self):
        status, body = request("POST", "/critique", token=self.token, body={"path": str(self.workspace)})
        self.assertEqual(status, 404)
        self.assertEqual(body["error"]["code"], "shoot_not_found")

    def test_critique_accepts_and_job_is_pollable(self):
        status, body = request("POST", "/critique", token=self.token, body={"ids": [self.file_id]})
        self.assertEqual(status, 202, body)
        job_id = body["job_id"]
        try:
            statuses_seen = set()
            for _ in range(20):
                status, job = request("GET", f"/jobs/{job_id}", token=self.token)
                self.assertEqual(status, 200)
                statuses_seen.add(job["status"])
                time.sleep(0.2)
            self.assertTrue(statuses_seen & {"queued", "running", "done", "failed"})
        finally:
            # Stop just this test's one subprocess -- matched by its unique (per-test-run)
            # workspace path, so this can never touch a real evaluate.py run -- well before
            # it would get anywhere near loading the actual vision model.
            subprocess.run(["pkill", "-f", str(self.workspace)], stderr=subprocess.DEVNULL)

        status, body = request("GET", "/jobs/does-not-exist", token=self.token)
        self.assertEqual(status, 404)

    # --- /export ---

    def test_export_rejects_missing_dest(self):
        status, body = request("POST", "/export", token=self.token, body={"ids": [1]})
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "missing_dest")

    def test_export_rejects_bad_preset(self):
        dest = tempfile.mkdtemp(prefix="pc-api-test-export-", dir=self.workspace)
        status, body = request("POST", "/export", token=self.token, body={"ids": [1], "dest": dest, "preset": "nope"})
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "invalid_preset")

    def test_export_runs_and_reports_the_undecodable_fixture(self):
        dest = tempfile.mkdtemp(prefix="pc-api-test-export-", dir=self.workspace)
        status, body = request(
            "POST", "/export", token=self.token,
            body={"ids": [self.file_id], "dest": dest, "preset": "original"},
            timeout=60,
        )
        self.assertEqual(status, 200, body)
        # The fixture isn't a real RAW, so rawpy can't decode it -- export_photo.py reports
        # that as a per-file error rather than crashing, which is exactly what confirms the
        # id -> path -> subprocess -> JSON response plumbing works end to end.
        self.assertEqual(body["failed"], 1)
        self.assertIn("decode failed", body["results"][0]["error"])


if __name__ == "__main__":
    unittest.main()
