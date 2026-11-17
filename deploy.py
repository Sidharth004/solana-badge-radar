#!/usr/bin/env python3
"""Copy Radar onto a badge over USB, start it, and screenshot it.

    python3 deploy.py                    # find the port, upload, run, screenshot
    python3 deploy.py --port /dev/cu.usbserial-110
    python3 deploy.py --no-shot
    python3 deploy.py --demo             # same, with simulated people on the radar
    python3 deploy.py --then "key down" --then "sleep 2" --then shot
                                         # after starting it, drive it and screenshot
    python3 deploy.py --cmd "key down" --cmd "shot"   # just drive the console

Opening the serial port on macOS reboots the badge (CH340), so a second run
starts from the home screen: do everything in one run with --then.

Uses the console's `lua recv` transfer (docs/LUA_API.md, "Console"): the badge
says `recv: ready <n>`, we send the next n base64 characters, it says
`recv: more <n>` once the card has written them, and `recv: ok` when the size
and SHA-256 match. Files that are already on the badge (`lua sums`) are
skipped. Needs pyserial, and Pillow for screenshots.
"""
import argparse, base64, glob, hashlib, os, re, struct, sys, time

try:
    import serial
except ImportError:
    sys.exit("needs pyserial:  ./setup.sh")

APP_ID = "badge-radar"
FILES = ["app.json", "main.lua"]          # app.json first: recv checks it like an install
HERE = os.path.dirname(os.path.abspath(__file__))

ap = argparse.ArgumentParser()
ap.add_argument("--port")
ap.add_argument("--no-shot", action="store_true")
ap.add_argument("--cmd", action="append", default=[], help="console command(s) only, no upload")
ap.add_argument("--out", default=os.path.join(HERE, "shots"))
ap.add_argument("--demo", action="store_true", help="upload with DEMO = true (simulated people)")
ap.add_argument("--then", action="append", default=[], dest="after",
                help="console command(s) to run after the app starts ('shot', 'sleep N' too)")
a = ap.parse_args()


def find_port():
    pats = ["/dev/cu.usbserial-*", "/dev/cu.wchusbserial*", "/dev/cu.usbmodem*",
            "/dev/ttyUSB*", "/dev/ttyACM*"]
    found = sorted(p for pat in pats for p in glob.glob(pat))
    return found[0] if found else None


port = a.port or find_port()
if not port:
    sys.exit("No badge found (no /dev/cu.usbserial-*, /dev/ttyUSB* or similar).\n"
             "  - Is the badge on?\n"
             "  - Is the USB-C cable a DATA cable? Many are charge-only.\n"
             "  - Plug it straight into the Mac, not through a hub, and retry.")

s = serial.Serial()
s.port, s.baudrate, s.timeout = port, 115200, 0.1
s.dtr = s.rts = False                    # don't hold the chip in reset/boot
s.open()
print(f"badge on {port}")


def read_for(seconds, until=None):
    buf, end = b"", time.time() + seconds
    while time.time() < end:
        d = s.read(4096)
        buf += d
        if until is not None and until in buf:
            break
    return buf


# Opening a CH340 port on macOS can reset the board: wait for the console.
head = read_for(1.0, b"ESP-ROM")
if b"ESP-ROM" in head or b"rst:" in head:
    print("badge rebooted on connect, waiting for the console...")
    read_for(20, b"console ready")
    time.sleep(1.5)


def send(cmd):
    s.write((cmd + "\r\n").encode())


def command(cmd, quiet_s=0.8, max_s=15):
    """Send a command and return what came back until the console goes quiet."""
    send(cmd)
    out, idle, end = b"", 0.0, time.time() + max_s
    while time.time() < end and idle < quiet_s:
        d = s.read(4096)
        out += d
        idle = 0.0 if d else idle + 0.1
    return out.decode("utf-8", "replace")


def sums():
    out = command(f"lua sums {APP_ID}")
    have = {}
    for line in out.splitlines():
        m = re.match(r"\s*([0-9a-f]{64})\s+(\d+)\s+(\S+)", line)
        if m:
            have[m.group(3)] = m.group(1)
    return have


def file_bytes(name):
    data = open(os.path.join(HERE, name), "rb").read()
    if a.demo and name == "main.lua":
        data = data.replace(b"local DEMO = false", b"local DEMO = true", 1)
    return data


def upload(name):
    data = file_bytes(name)
    b64 = base64.b64encode(data).decode()
    sha = hashlib.sha256(data).hexdigest()
    send(f"lua recv {APP_ID} {name} {len(data)} {sha}")
    pos, buf, end = 0, b"", time.time() + 30
    pat = re.compile(rb"recv: (ready|more|ok|error)\s*([^\r\n]*)")
    while time.time() < end:
        buf += s.read(4096)
        m = pat.search(buf)
        if not m:
            continue
        buf = buf[m.end():]
        kind, rest = m.group(1).decode(), m.group(2).decode().strip()
        if os.environ.get("RADAR_DEBUG"):
            print(f"    <- recv: {kind} {rest}  (sent {pos}/{len(b64)})")
        if kind in ("ready", "more"):
            n = int(rest.split()[0])
            chunk = b64[pos:pos + n]
            pos += len(chunk)
            # small pieces with a breath between: the badge's UART buffer is
            # small, and bytes it drops while busy stall the transfer
            for i in range(0, len(chunk), 256):
                s.write(chunk[i:i + 256].encode())
                s.flush()
                time.sleep(0.03)
            end = time.time() + 30
        elif kind == "ok":
            print(f"  {name}: {len(data)} bytes ok")
            return True
        else:
            print(f"  {name}: badge refused it: {rest}")
            return False
    print(f"  {name}: no answer from the badge (is a microSD card in?)")
    return False


def shot():
    send("shot")
    text = read_for(60, b"SHOT-END").decode("utf-8", "replace")
    try:
        from PIL import Image
    except ImportError:
        print("  (install Pillow to save screenshots)")
        return
    w = h = None
    rows = {}
    for line in text.splitlines():
        if line.startswith("SHOT-BEGIN"):
            _, w, h = line.split()[:3]
            w, h = int(w), int(h)
        elif line.startswith("SHOT "):
            parts = line.split(" ")
            if len(parts) == 5:
                try:
                    rows[(int(parts[1]), int(parts[2]))] = (int(parts[3]), base64.b64decode(parts[4]))
                except Exception:
                    pass
    if not w:
        print("  no screenshot came back")
        return
    img = Image.new("RGB", (w, h))
    px = img.load()
    for (x0, y), (n, data) in rows.items():
        for i in range(min(n, len(data) // 2)):
            v = struct.unpack_from("<H", data, i * 2)[0]
            r, g, b = (v >> 11) & 0x1F, (v >> 5) & 0x3F, v & 0x1F
            if 0 <= x0 + i < w and 0 <= y < h:
                px[x0 + i, y] = (r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2)
    os.makedirs(a.out, exist_ok=True)
    path = os.path.join(a.out, f"shot_{int(time.time())}.png")
    img.save(path)
    print(f"  screenshot: {path}")


def run_cmds(cmds):
    for c in cmds:
        if c == "shot":
            shot()
        elif c.startswith("sleep "):
            time.sleep(float(c.split()[1]))
        else:
            sys.stdout.write(command(c))


if a.cmd:
    run_cmds(a.cmd)
    sys.exit(0)

print(command("lua list").strip() or "(lua list: no answer)")
command("open home")                     # recv refuses while an app runs
time.sleep(1.0)
have = sums()
for f in FILES:
    data = file_bytes(f)
    if have.get(f) == hashlib.sha256(data).hexdigest():
        print(f"  {f}: unchanged, skipped")
    else:
        for attempt in range(3):
            if upload(f):
                break
            print("  retrying...")
            read_for(2.0)
        else:
            sys.exit(f"  {f}: upload failed 3 times")
print("starting Radar...")
out = command(f"lua run {APP_ID}", quiet_s=3.0)
sys.stdout.write(out)
if "rror" in out:
    sys.exit("the app reported an error above")
if not a.no_shot:
    time.sleep(4)                         # let it poll the room a few times
    shot()
run_cmds(a.after)
print(command("lua mem").strip())
