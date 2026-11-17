#!/bin/sh
# One-time host setup for Radar: Python venv for deploy.py, then the tests.
set -e
cd "$(dirname "$0")"
python3 -m venv .venv
.venv/bin/pip install -q -r requirements.txt
echo "ok: .venv ready (pyserial, pillow)"
if command -v lua >/dev/null 2>&1; then
  lua test.lua | tail -2
else
  echo "note: install Lua 5.5 (macOS: brew install lua) to run the tests"
fi
echo "next: plug the badge in with a data cable and run  .venv/bin/python deploy.py"
