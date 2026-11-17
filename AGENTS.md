# AGENTS.md: instructions for AI coding agents

This repo is **Radar**, a Lua app for the Solana Breakpoint 2026 badge (an
ESP32-C5 running Solana OS). Use these steps to install it on a badge,
change it, or verify it.

## 0. Facts you need

- **Badge code.** Only `main.lua` and `app.json` go onto the badge. Everything
  else is host tooling.
- **Sandbox.** The badge runs **Lua 5.5 in a sandbox** with:
  - no `io`, `os`, `debug` or `load`
  - 200 000 VM instructions per callback
  - 128 UI objects and 8 timers
  - 16 KB of storage
- **Lua on the badge has 32-bit integers.** Keep every integer literal and
  intermediate below 2^31. Desktop Lua is 64-bit and will not catch this;
  `test.lua` has a literal check.
- **API reference.** The official API is
  https://github.com/solana-foundation/solana-os, in `docs/LUA_API.md` and
  `docs/CONNECTIVITY.md`. solana.com/breakpoint/badge blocks scripted
  fetches (HTTP 429), so read the docs from GitHub.
- **Connection.** The badge talks over a CH340 USB-serial chip at 115200 baud
  and appears as `/dev/cu.usbserial-*` (macOS) or `/dev/ttyUSB*` (Linux).
  - **Opening the port reboots the badge** on macOS. Each `deploy.py` run
    starts from the home screen, so chain actions with `--then` in one run.
  - **Uploading needs a microSD card in the badge.**

## 1. Host setup (once)

```sh
./setup.sh
```

This creates `.venv` with `pyserial` and `pillow`. If `lua` (5.5) is on PATH,
it also runs the tests. To install Lua on macOS, use `brew install lua`.

## 2. Check the badge is visible

```sh
ls /dev/cu.usbserial-* /dev/ttyUSB* 2>/dev/null
```

If nothing is listed, the cable is almost certainly charge-only, or the badge
is off. On macOS, `ioreg -p IOUSB` should show "USB Serial", vendor 6790
(0x1a86, CH340). Ask the human to swap to a data cable. Do not try to install
drivers first.

## 3. Install / update the app on the badge

```sh
.venv/bin/python deploy.py                 # upload changed files, start Radar, screenshot to shots/
.venv/bin/python deploy.py --demo          # same, with simulated people (for testing alone)
.venv/bin/python deploy.py --then "key down" --then "sleep 1.5" --then shot
.venv/bin/python deploy.py --cmd "mesh status" --cmd "mesh peers"   # console only, no upload
```

What `deploy.py` does:

1. Finds the port and waits for `console ready` if the badge rebooted.
2. Runs `open home`, then compares files with `lua sums badge-radar` and
   skips any that haven't changed.
3. Uploads with `lua recv` (the `ready`/`more`/`ok` handshake), in throttled
   256-byte pieces, retrying up to 3 times.
4. Runs `lua run badge-radar`. If the output contains `Script error`, the
   script exits non-zero. Fix the error and redeploy.
5. Saves a screenshot PNG to `shots/`. Open it to check the UI.

To check the upload stage on its own, set `RADAR_DEBUG=1` to print the
handshake.

## 4. Change the app

1. Edit `main.lua`. If you add a feature, add tests to `test.lua`.
2. Run `lua test.lua`. All checks must pass. It prints VM-instruction
   budgets, which must stay under 75 % of 200 000.
3. Bump `"version"` in `app.json`.
4. Deploy (step 3) and look at the screenshot.

Useful console commands (send them with `--cmd` or `--then`):

| Command | What it does |
|---|---|
| `lua list` | list installed apps |
| `lua run <id>` | start an app |
| `lua mem` | show the app's memory use |
| `open home` | go to the home screen |
| `key up\|down\|left\|right\|select\|back` | press a key |
| `shot` | take a screenshot |
| `info` | show battery and board info |
| `wifi status` | show Wi-Fi state |
| `mesh status` | show mesh state |
| `mesh peers` | list badges heard on the mesh |
| `mesh acquire` / `mesh release` | take or give back the radio for the mesh |
| `mesh channel <n\|auto>` | change the mesh channel |

## 5. Publish to the badge App Store (human step)

Publishing needs the owner's X account linked at
solana.com/breakpoint/badge/profile, then an upload of `main.lua` and
`app.json` at `/apps/submit`. An agent can prepare the files but should
leave the submission to the human. If the id `badge-radar` is taken, change
it in **both** `app.json` and `APP_ID` in `main.lua`.

## Rules

- Never commit `shots/`, `.venv/` or `__pycache__/`.
- Keep the creature art original, not copied from any franchise.
- Radar must not send mesh messages. Detection relies only on `mesh.nearby()`.
