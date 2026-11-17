#!/bin/bash
# One-time setup of the small "travel" copy of PhotoCritic on a laptop (Apple Silicon).
# It installs only what organize needs (RAW decode, previews, quick cull, burst grouping) —
# NOT the AI model. AI scoring stays on the Studio.
#
# Run from the project folder on the laptop:   bash setup_travel_mac.sh
set -e

PROJECT="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$HOME/PhotoCriticTravel"

echo "== Checking this Mac"
if [ "$(uname -m)" != "arm64" ]; then
  echo "This needs an Apple Silicon Mac (uname -m printed $(uname -m)). Stop here and tell Claude."
  exit 1
fi
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is missing. Install it from https://brew.sh, then re-run this script."
  exit 1
fi
FREE_GB=$(df -g "$HOME" | awk 'NR==2 {print $4}')
echo "Free disk space: ${FREE_GB} GB (each RAW is ~212 MB, plus ~0.4 MB per preview)"

echo "== Installing tools (exiftool, uv)"
brew list exiftool >/dev/null 2>&1 || brew install exiftool
brew list uv >/dev/null 2>&1 || brew install uv

echo "== Python environment (same versions as the Studio)"
cd "$PROJECT"
[ -d .venv ] || uv venv --python 3.13 .venv
uv pip install --python .venv/bin/python3 \
  rawpy==0.27.1 pillow==12.3.0 numpy==2.5.2 imagehash==4.3.2 exifread==3.5.1 \
  tqdm==4.70.0 opencv-python==5.0.0.93 scipy==1.18.1 pywavelets==1.9.0

echo "== Travel workspace at $WORKSPACE"
mkdir -p "$WORKSPACE"/{database,previews,logs,cache,exports}
# Point the viewer app at it (the app reads this setting; the Studio's default is untouched).
defaults write com.photocritic.viewer workspaceRootPath "$WORKSPACE"
defaults write com.photocritic.viewer projectRootPath "$PROJECT"

echo "== Smoke test"
PHOTOCRITIC_WORKSPACE="$WORKSPACE" .venv/bin/python3 -c "
from photocritic import config, pipeline, db
print('workspace ->', config.WORKSPACE_ROOT)
with db.connect() as conn:
    db.init_schema(conn)
print('database ok')
"
exiftool -ver >/dev/null && echo "exiftool ok"

cat <<EOF

Setup complete. To use it:

  # 1. Import + quick-cull a folder of RAWs into the travel workspace (no AI, fast, CPU only)
  cd "$PROJECT"
  PHOTOCRITIC_WORKSPACE="$WORKSPACE" .venv/bin/python3 organize.py ~/Florida-shoot/DCIM

  # 2. Open PhotoCriticViewer.app to browse and mark (it now reads $WORKSPACE)

  # 3. Before you head home, export your marks:
  PHOTOCRITIC_WORKSPACE="$WORKSPACE" .venv/bin/python3 travel_sync.py export ~/florida-marks.json

EOF
