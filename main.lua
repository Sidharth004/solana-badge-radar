--==========================================================================
--  RADAR                                       Solana OS badge app, v1.2.0
--  Who is around you at Breakpoint: a sweeping radar with a pixel creature
--  for each person, labelled with the name they linked from X.
--
--  Every badge on the mesh shows up -- they don't need this app: badges
--  broadcast a HELLO every couple of seconds while a mesh app is open or
--  their Wi-Fi is on the event's mesh channel, and the OS keeps the list
--  (mesh.nearby). Each person's creature is picked from their badge id, so
--  they look the same on every badge. SELECT shows a QR that installs
--  Radar; every copy has it, so whoever you onboard onboards the next.
--
--  Permissions: mesh, led, profile.   Sprites need Solana OS 0.5.9+.
--==========================================================================

local APP_ID    = "badge-radar"     -- keep in step with app.json "id"
local STORE_URL = "https://solana.com/breakpoint/badge/apps/app?id=" .. APP_ID

local POLL_MS      = 1000
local MAX_BLIPS    = 24
local SWEEP_MS     = 3000
local PROF_RETRY   = 60000
local PROF_TIMEOUT = 10000

-- Zoom levels. RSSI is signal strength, not distance (people soak up
-- 2.4 GHz), so these are bands, not metres. `min` filters what is shown,
-- `lo` is the signal drawn on the outer ring.
local RANGES = {
  { label = "CLOSE", sub = "talking distance",      min = -60,   lo = -60 },
  { label = "AREA",  sub = "this part of the hall", min = -75,   lo = -75 },
  { label = "ALL",   sub = "everything in range",   min = -1000, lo = -92 },
}
local RSSI_TOP = -38

-- DEMO mode adds simulated people so you can test alone. deploy.py --demo
-- turns it on; so does DOWN on the QR screen (remembered on the badge).
local DEMO = false
local DEMO_PEOPLE = {   -- id, X name, @handle, centre dBm, swing, period ms
  { "DEMO01", "Ana Builder",  "ana_builds",  -50,  8, 17000 },
  { "DEMO02", "Kofi Dev",     "kofi_dev",    -60, 14, 23000 },
  { "DEMO03", "Mei Validator","mei_val",     -68, 10, 31000 },
  { "DEMO04", "Raj Founder",  "raj_founds",  -74, 16, 13000 },
  { "DEMO05", "Lena Design",  "lena_px",     -82,  8, 29000 },
  { "DEMO06", "Sam Intern",   "sam_ships",   -64, 22, 11000, true }, -- comes and goes
}

--------------------------------------------------------------- the creatures
--
-- Original 10x10 creatures (swap in your own art here). In the templates:
--   X body   Y belly/accent   E eye white   k black   . see-through
-- X and Y are replaced by the type's colours; everything must end up as one
-- of the badge's built-in pixel-art characters (k w p g m v b a l y o).

local SPECIES = {
  { "GLOOPY", {
    "..........", "...XXXX...", "..XXXXXX..", ".XXXXXXXX.", ".XEkXXkEX.",
    "XXXXXXXXXX", "XXXYYYYXXX", "XXYYYYYYXX", ".XXXXXXXX.", ".........." } },
  { "FLITBAT", {
    "X........X", "XX..XX..XX", "XXX.XX.XXX", "XXXXXXXXXX", ".XEkXXkEX.",
    ".XXXXXXXX.", "..XYYYYX..", "...XYYX...", "....XX....", ".........." } },
  { "WHISKIT", {
    ".X......X.", ".XX....XX.", ".XXXXXXXX.", "XXXXXXXXXX", "XXEkXXkEXX",
    "XXXXYYXXXX", ".XXYYYYXX.", "..XYYYYX..", "..XX..XX..", ".........." } },
  { "CHIRPO", {
    "....XX....", "...XXXX...", "..XEkXXX..", "..XXXXXYY.", ".XXXXXX...",
    "XYYYYXXX..", "XYYYYXXXX.", ".XXXXXXX..", "...k..k...", ".........." } },
  { "FINNET", {
    "..........", "....XXX...", "..XXXXXX.X", ".XEkXXXXXX", "XXXXXXXXXX",
    "XYYYYYXXXX", ".XYYYYXX.X", "..XXXXX...", "....X.....", ".........." } },
  { "SPOOKLE", {
    "...XXXX...", "..XXXXXX..", ".XXXXXXXX.", ".XEkXXkEX.", ".XXXXXXXX.",
    ".XXXYYXXX.", ".XXXXXXXX.", ".XXXXXXXX.", ".XX.XX.XX.", ".X..XX..X." } },
  { "SHROOMP", {
    "...XXXX...", ".XXYXXYXX.", "XXYYXXYYXX", "XXXXXXXXXX", ".XXXXXXXX.",
    "...EEEE...", "..EkEEkE..", "..EEEEEE..", "...EEEE...", ".........." } },
  { "BEETIK", {
    "..k....k..", "...k..k...", "..XXXXXX..", ".XEkXXkEX.", ".XXXXXXXX.",
    "kXYYXXYYXk", ".XYYXXYYX.", "kXXXXXXXXk", "..XX..XX..", ".........." } },
  { "DRAKELET", {
    ".Y......Y.", ".YX....XY.", "..XXXXXX..", ".XEkXXkEX.", ".XXXXXXXX.",
    "..XkXXkX..", ".YXYYYYXY.", "YYXYYYYXYY", "..XX..XX..", ".........." } },
  { "BOTTO", {
    "....kk....", "....XX....", ".XXXXXXXX.", ".XEEXXEEX.", ".XEkXXkEX.",
    ".XXXXXXXX.", ".XYkYYkYX.", ".XXXXXXXX.", "..XX..XX..", ".........." } },
  { "HOPSY", {
    "..XX..XX..", "..XY..YX..", "..XY..YX..", ".XXXXXXXX.", ".XEkXXkEX.",
    ".XXXYYXXX.", "..XYYYYX..", ".XXYYYYXX.", ".XX....XX.", ".........." } },
  { "FOXEL", {
    "..........", "X........X", "XX......XX", "XXXXXXXXXX", ".XEkXXkEX.",
    ".XXXXXXXX.", "..YYXXYY..", "...YkkY...", "....YY....", ".........." } },
  { "CROAKIT", {
    "..........", ".EE....EE.", ".Ek....kE.", ".XXXXXXXX.", "XXXXXXXXXX",
    "XkXXXXXXkX", "XXkkkkkkXX", ".XYYYYYYX.", "XX......XX", ".........." } },
  { "OCTOPOP", {
    "...XXXX...", "..XXXXXX..", ".XXXXXXXX.", ".XEkXXkEX.", ".XXXXXXXX.",
    ".XXYYYYXX.", "X.X.XX.X.X", "X.X.XX.X.X", ".X.X..X.X.", ".........." } },
  { "TWINKL", {
    "....XX....", "....XX....", "...XXXX...", "XXXXXXXXXX", ".XEkXXkEX.",
    "..XXYYXX..", "..XXXXXX..", ".XXX..XXX.", ".XX....XX.", "X........X" } },
}

-- body char, belly char, theme colour for text, LED colour
local TYPES = {
  { "FIRE",   "o", "y", "orange",  0xFF754A },
  { "WATER",  "b", "a", "blue",    0x4D7CFF },
  { "GRASS",  "g", "l", "green",   0x14F195 },
  { "SPARK",  "y", "w", "yellow",  0xFFD23F },
  { "PSYCH",  "m", "v", "pink",    0xFF5FD2 },
  { "SHADOW", "p", "v", "lpurple", 0x9945FF },
  { "FROST",  "a", "w", "aqua",    0x00D1FF },
  { "TOXIC",  "l", "p", "lime",    0xB7FF4A },
}
local SHINY = { "SHINY", "w", "y", "yellow", 0xFFFFFF }   -- 1 in 32

-- 31-bit hash. The badge's Lua has 32-bit integers, so every step is kept
-- below 2^31 and gives the same answer on 32- and 64-bit builds.
local function hash32(s)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + string.byte(s, i)) & 0x7FFFFFFF
  end
  h = h ~ (h >> 15)
  h = (h * 0x2C1B3C6D) & 0x7FFFFFFF
  return h ~ (h >> 13)
end

local function paint(rows, body, belly)
  local out = {}
  for i = 1, #rows do
    local r = string.gsub(rows[i], "X", body)
    r = string.gsub(r, "Y", belly)
    r = string.gsub(r, "E", "w")
    out[i] = r
  end
  return out
end

-- Same badge id -> same creature, on every badge.
local creatures, ncreatures = {}, 0
local function creature(id)
  local c = creatures[id]
  if c then return c end
  if ncreatures >= 600 then creatures, ncreatures = {}, 0 end
  local h = hash32(id)
  local si = (h % #SPECIES) + 1
  local ti = ((h >> 8) % #TYPES) + 1
  local shiny = ((h >> 16) % 32) == 0
  local ty = shiny and SHINY or TYPES[ti]
  local sp = SPECIES[si]
  c = {
    led  = ty[5],      -- the creature's colour, for the LEDs
    rows = paint(sp[2], ty[2], ty[3]),
  }
  creatures[id] = c
  ncreatures = ncreatures + 1
  return c
end

--------------------------------------------------------------------- helpers

-- Names arrive from other badges: printable ASCII only, trimmed, capped.
local function clean(s, max)
  if type(s) == "number" then s = tostring(s) end
  if type(s) ~= "string" then return "" end
  local out, n = {}, 0
  for i = 1, #s do
    local b = string.byte(s, i)
    if b >= 32 and b <= 126 then
      n = n + 1
      out[n] = string.char(b)
      if n >= max then break end
    end
  end
  local t = table.concat(out)
  t = string.gsub(t, "^%s+", "")
  t = string.gsub(t, "%s+$", "")
  return t
end

local function trunc(s, n)
  if #s <= n then return s end
  return string.sub(s, 1, n - 1) .. "."
end

local function band(s, bridged)
  if bridged then return "bridged ~~~~" end
  if s >= -50 then return "very close ||||" end
  if s >= -62 then return "talking |||." end
  if s >= -75 then return "nearby ||.." end
  return "far |..."
end

----------------------------------------------------------------------- state

local me = { id = badge.id() or "ME" }
me.x = clean(badge.owner() or "", 20)          -- "@toly" once X is linked
me.name = me.x ~= "" and me.x or "you"

local zoom0 = tonumber(storage.get("zoom"))
if zoom0 ~= 1 and zoom0 ~= 2 and zoom0 ~= 3 then zoom0 = 2 end

local S = {
  screen   = "radar",
  zoom     = zoom0,
  track    = {},     -- id -> {s, name, kind, bridged, ang, r, gen}
  gen      = 0,
  vis      = {},     -- people on screen, strongest first
  beacons  = {},
  around   = 0,
  landmark = nil,
  sel      = "me",
  sweep    = 0,
  dirty    = true,
  hint     = nil,
  shown    = nil,    -- whose creature the card shows
  callTxt  = nil,
  prof     = {},
  demo     = DEMO or storage.get("demo") == true,
  profBusy = false,
  profId   = nil,
  profAt   = 0,
}

-------------------------------------------------------------------- X lookup

-- The X display name already comes in the HELLO. The @handle needs the
-- server: fetched only for the person you pick, once, and only when Wi-Fi is
-- usable from the mesh channel (otherwise it would just answer "offline").
local function wantProfile(id)
  if id == "me" or type(profile) ~= "table" or not profile.get then return end
  if string.sub(id, 1, 4) == "DEMO" then return end      -- handles built in
  local now = sys.millis()
  if S.profBusy and now - S.profAt > PROF_TIMEOUT then
    S.prof[S.profId] = { failAt = now }
    S.profBusy = false
  end
  local pf = S.prof[id]
  if pf and (pf.done or pf.pending) then return end
  if pf and pf.failAt and now - pf.failAt < PROF_RETRY then return end
  if S.profBusy then return end
  if mesh.info then
    local info = mesh.info()
    if type(info) == "table" and info.online == false then return end
  end
  S.prof[id] = { pending = true }
  S.profBusy, S.profId, S.profAt = true, id, now
  local ok = pcall(profile.get, id, function(good, res)
    if S.profId == id then S.profBusy = false end
    if good and type(res) == "table" then
      local x = clean(res.x or "", 20)
      local xn = clean(res.xName or "", 20)
      S.prof[id] = { done = true, x = (x ~= "" and x or nil),
                     xn = (xn ~= "" and xn or nil) }
    else
      S.prof[id] = { failAt = sys.millis() }
    end
    S.dirty = true
  end)
  if not ok then
    S.profBusy = false
    S.prof[id] = { failAt = now }
  end
end

--------------------------------------------------------------- who is here

local layout = function() end    -- defined with the radar geometry below

local function rebuild()
  local R = RANGES[S.zoom]
  local keys, ids, k = {}, {}, 0
  local beacons, nb = {}, 0
  local around = 0
  local best, bestS = nil, -1e9
  for id, t in pairs(S.track) do
    if t.kind == "beacon" then
      if t.s > bestS then best, bestS = t, t.s end
      if t.s >= R.min and nb < 12 then
        nb = nb + 1
        beacons[nb] = id
      end
    else
      around = around + 1
      if (t.s >= R.min or id == S.sel) and k < 4000 then
        k = k + 1
        ids[k] = id
        -- one integer per badge so table.sort compares in C, not Lua: a
        -- keynote hall can put hundreds in range, and a callback only gets
        -- 200 000 VM instructions
        keys[k] = -math.floor((t.s + 200) * 10) * 4096 + k  -- stays far below 2^31
      end
    end
  end
  table.sort(keys)
  local vis, selIn = {}, false
  local n = k
  if n > MAX_BLIPS then n = MAX_BLIPS end
  for i = 1, n do
    local id = ids[keys[i] % 4096]
    vis[i] = id
    if id == S.sel then selIn = true end
  end
  if S.sel ~= "me" and not selIn then
    if S.track[S.sel] then vis[#vis + 1] = S.sel else S.sel = "me" end
  end
  S.vis, S.beacons, S.around = vis, beacons, around
  S.landmark = best and best.name or nil
  layout()
  S.dirty = true
end

-- Simulated people for DEMO mode: each drifts closer and farther on its own
-- slow cycle, and one walks in and out of range.
local function demoPeople(list)
  local out = {}
  for i = 1, #list do out[i] = list[i] end
  local now = sys.millis()
  for i = 1, #DEMO_PEOPLE do
    local d = DEMO_PEOPLE[i]
    local w = math.sin((now + i * 3700) * 2 * math.pi / d[6])
    if not (d[7] and w < -0.5) then
      out[#out + 1] = { id = d[1], name = d[2], level = i, kind = "badge",
                        rssi = math.floor(d[4] + d[5] * w), bridged = false }
      if not S.prof[d[1]] then S.prof[d[1]] = { done = true, x = d[3] } end
    end
  end
  out[#out + 1] = { id = "DEMOBC", name = "Main Stage", level = 0,
                    kind = "beacon", rssi = -70, bridged = false }
  return out
end

local function poll()
  if me.id == "ME" then
    local bid = badge.id()
    if bid then me.id = bid end
  end
  local list = mesh.nearby()
  if type(list) ~= "table" then list = {} end
  if S.demo then list = demoPeople(list) end
  S.gen = S.gen + 1
  local gen = S.gen
  for i = 1, #list do
    local p = list[i]
    if type(p) == "table" then
      local id = p.id
      if type(id) == "string" and #id > 0 and #id <= 16 then
        local rssi = tonumber(p.rssi) or -90
        if rssi ~= rssi then rssi = -90 end
        local bridged = p.bridged == true or rssi == 0
        if bridged then
          rssi = -88
        elseif rssi > -20 then
          rssi = -20
        elseif rssi < -110 then
          rssi = -110
        end
        local t = S.track[id]
        if not t then
          t = { s = rssi, ang = hash32("@" .. id) % 96 }
          S.track[id] = t
        else
          t.s = t.s * 0.6 + rssi * 0.4   -- raw RSSI jumps +-10 dB per HELLO
        end
        if t.rawName ~= p.name or not t.name then
          t.rawName = p.name
          local nm = clean(p.name, 20)
          if nm == "" then nm = clean(id, 16) end
          t.name = nm
        end
        t.kind = (p.kind == "beacon") and "beacon" or "badge"
        t.bridged = bridged
        t.gen = gen
      end
    end
  end
  for id, t in pairs(S.track) do
    if t.gen ~= gen then S.track[id] = nil end
  end
  rebuild()
  if S.sel ~= "me" then wantProfile(S.sel) end
end

------------------------------------------------------------------ the radar

local W = {}

local COS, SIN = {}, {}
for i = 0, 95 do
  local a = i * math.pi / 48
  COS[i] = math.cos(a)
  SIN[i] = math.sin(a)
end

local CX, CY, RMAX = 50, 50, 47
local C_DISC, C_RING, C_CROSS = 0x04140E, 0x0F4A33, 0x0A3324
local C_SWEEP, C_ME, C_SEL, C_BEACON = 0x14F195, 0x9945FF, 0xFFFFFF, 0x6B7F3A

local function shade(c, f)
  local r = math.floor(((c >> 16) & 255) * f)
  local g = math.floor(((c >> 8) & 255) * f)
  local b = math.floor((c & 255) * f)
  return (r << 16) | (g << 8) | b
end

local DISC = {}
for y = 0, 99 do
  local dy = (y + 0.5) - CY
  local q = (RMAX + 0.5) ^ 2 - dy * dy
  DISC[y] = q >= 0 and math.floor(math.sqrt(q)) or -1
end
local RX, RY, NR = {}, {}, 0
for _, rr in ipairs({ 16, 31, 47 }) do
  for i = 0, 95, 2 do
    NR = NR + 1
    RX[NR] = CX + math.floor(COS[i] * rr + 0.5)
    RY[NR] = CY + math.floor(SIN[i] * rr + 0.5)
  end
end
local SX, SY, TAIL = {}, {}, {}
for i = 0, 95 do
  SX[i] = CX + math.floor(COS[i] * RMAX + 0.5)
  SY[i] = CY + math.floor(SIN[i] * RMAX + 0.5)
end
for k = 0, 9 do TAIL[k] = shade(C_SWEEP, 0.85 - k * 0.08) end

local function radiusFor(s)
  local lo = RANGES[S.zoom].lo
  local f = (RSSI_TOP - s) / (RSSI_TOP - lo)
  if f < 0 then f = 0 elseif f > 1 then f = 1 end
  return 15 + f * 27              -- creatures stay clear of you and the rim
end

-- Creatures are 10 px wide, so two at nearby angles and distances would
-- sit on top of each other. Once a second, walk everyone nearest-first and
-- slide each one round the ring to the closest free spot, trying the spot
-- it had last time first so nobody jitters. Only the angle moves: distance
-- from the centre stays the real signal.
local OFFS = { 0, 4, -4, 8, -8, 12, -12, 16, -16, 20, -20, 24, -24 }
layout = function()
  local px, py, n = { CX }, { CY }, 1          -- you, in the middle
  for i = 1, #S.vis do
    local t = S.track[S.vis[i]]
    if t then
      local rr = radiusFor(t.s)
      local chosen, cx, cy = nil, nil, nil
      local tries = t.off and { t.off } or {}
      for j = 1, #OFFS do tries[#tries + 1] = OFFS[j] end
      for j = 1, #tries do
        local a = (t.ang + tries[j]) % 96
        local x = CX + COS[a] * rr
        local y = CY + SIN[a] * rr
        local free = true
        for q = 1, n do
          local dx, dy = x - px[q], y - py[q]
          if dx * dx + dy * dy < 100 then free = false break end
        end
        if free then chosen, cx, cy = tries[j], x, y break end
      end
      if not chosen then                       -- packed solid: stay put
        chosen = t.off or 0
        local a = (t.ang + chosen) % 96
        cx, cy = CX + COS[a] * rr, CY + SIN[a] * rr
      end
      t.off = chosen
      n = n + 1
      px[n], py[n] = cx, cy
    end
  end
end

local function box(c, x0, y0, x1, y1, col)
  c:line(x0, y0, x1, y0, col)
  c:line(x0, y1, x1, y1, col)
  c:line(x0, y0, x0, y1, col)
  c:line(x1, y0, x1, y1, col)
end

local function callout(x, y)
  local l = W.callout
  if not l then return end
  local plate = W.plate
  if not x then
    if S.callTxt ~= "" then
      l:text(""); S.callTxt = ""
      if plate then plate:show(false) end
    end
    return
  end
  local t = S.track[S.sel]
  local txt = t and trunc(t.name, 12) or ""
  if txt ~= S.callTxt then l:text(txt); S.callTxt = txt end
  local sx, sy = x * 2, y * 2
  local tw = #txt * 7
  local lx = sx - tw // 2
  if lx < 0 then lx = 0 end
  if lx + tw > 200 then lx = 200 - tw end
  local ly = sy + 14                     -- under the creature
  if ly > 184 then ly = sy - 30 end      -- or above it, near the bottom
  l:pos(lx, ly)
  if plate then                          -- a dark plate keeps the name legible
    plate:pos(lx - 3, ly - 1)
    plate:size(tw + 6, 16)
    plate:show(txt ~= "")
  end
end

local function drawRadar(now)
  local c = W.canvas
  if not c then return end
  c:clear()
  for y = 0, 99 do
    local hw = DISC[y]
    if hw >= 0 then c:rect(CX - hw, y, hw * 2 + 1, 1, C_DISC) end
  end
  for i = 1, NR do c:pixel(RX[i], RY[i], C_RING) end
  c:line(CX - RMAX, CY, CX + RMAX, CY, C_CROSS)
  c:line(CX, CY - RMAX, CX, CY + RMAX, C_CROSS)
  local head = math.floor(S.sweep)
  for k = 0, 9 do
    local i = (head - k) % 96
    c:line(CX, CY, SX[i], SY[i], TAIL[k])
  end

  for _, id in ipairs(S.beacons) do
    local t = S.track[id]
    if t then
      local rr = radiusFor(t.s)
      local x = CX + math.floor(COS[t.ang] * rr + 0.5)
      local y = CY + math.floor(SIN[t.ang] * rr + 0.5)
      c:line(x - 2, y, x + 2, y, C_BEACON)
      c:line(x, y - 2, x, y + 2, C_BEACON)
    end
  end

  local selX, selY
  for i = 1, #S.vis do
    local id = S.vis[i]
    local t = S.track[id]
    if t then
      local target = radiusFor(t.s)
      if t.r then t.r = t.r + (target - t.r) * 0.2 else t.r = target end
      local a = (t.ang + (t.off or 0)) % 96
      local x = CX + math.floor(COS[a] * t.r + 0.5)
      local y = CY + math.floor(SIN[a] * t.r + 0.5)
      c:image(creature(id).rows, x - 5, y - 5)
      -- the sweep "pings" each creature as it passes
      if (head - a) % 96 < 5 then
        local g = shade(C_SWEEP, 0.9)
        c:pixel(x - 6, y - 6, g); c:pixel(x + 5, y - 6, g)
        c:pixel(x - 6, y + 5, g); c:pixel(x + 5, y + 5, g)
      end
      if id == S.sel then selX, selY = x, y end
    end
  end

  c:image(creature(me.id).rows, CX - 5, CY - 5)
  local blink = ((now // 350) % 2) == 0
  if S.sel == "me" then
    box(c, CX - 7, CY - 7, CX + 6, CY + 6, blink and C_SEL or C_ME)
    callout(nil)
  elseif selX then
    box(c, CX - 7, CY - 7, CX + 6, CY + 6, shade(C_ME, 0.5))
    if blink then box(c, selX - 7, selY - 7, selX + 6, selY + 6, C_SEL) end
    callout(selX, selY)
  else
    callout(nil)
  end
end

local function setHint(h)
  if h ~= S.hint then ui.hint(h); S.hint = h end
end

-- The card: whoever you picked, by the name they linked from X.
local function paintCard()
  if not W.name then return end
  local id = S.sel
  local t = id ~= "me" and S.track[id] or nil
  if id ~= "me" and not t then S.sel, id = "me", "me" end
  if S.shown ~= id then
    S.shown = id
    if W.sprite then W.sprite:set(creature(id == "me" and me.id or id).rows) end
    W.tag:text(id == "me" and "YOU" or "")
  end
  if id == "me" then
    W.name:text(trunc(me.name, 14))
    if me.x ~= "" then
      W.handle:text("this is you")
    else
      W.handle:text("link X /profile")
    end
    W.band:text("SELECT: your QR")
  else
    local pf = S.prof[id]
    W.name:text(trunc((pf and pf.xn) or t.name, 14))
    if pf and pf.x then
      W.handle:text("@" .. trunc(pf.x, 13))
    elseif pf and pf.pending then
      W.handle:text("finding @...")
    else
      W.handle:text("")
    end
    W.band:text(band(t.s, t.bridged))
  end
  W.around:text(tostring(S.around))
  W.near:text(S.landmark and ("near " .. trunc(S.landmark, 10)) or "")
  W.zoom:text(RANGES[S.zoom].label .. (S.demo and "  demo" or ""))
end

local function buildRadar()
  ui.clear()
  W = {}
  ui.bg("bg")
  if ui.canvas then
    W.canvas = ui.canvas(0, 0, 100, 100, { scale = 2 })
  else
    W.nc1 = ui.label(20, 80, "Radar needs", { size = 14, color = "dim" })
    W.nc2 = ui.label(20, 100, "Solana OS 0.5.9+", { size = 14, color = "dim" })
  end
  W.zoom    = ui.label(4, 2, "", { size = 14, color = "green" })
  W.plate   = ui.rect(0, 0, 1, 1, { color = 0x020A07, radius = 3 })
  W.plate:show(false)
  W.callout = ui.label(0, 0, "", { size = 12 })
  -- the person you picked
  W.screen  = ui.rect(208, 2, 58, 58, { color = 0x0A1F16, radius = 4 })
  if ui.image then
    W.sprite = ui.image(212, 6, creature(me.id).rows, { scale = 5 })
  end
  W.tag     = ui.label(272, 4, "", { size = 14, color = "lpurple" })
  W.name    = ui.label(208, 66, "", { size = 14, color = "green" })
  W.handle  = ui.label(208, 86, "", { size = 12, color = "dim" })
  W.band    = ui.label(208, 106, "", { size = 12 })
  W.div     = ui.rect(208, 136, 108, 1, { color = "border" })
  W.k1      = ui.label(208, 142, "AROUND YOU", { size = 12, color = "dim" })
  W.around  = ui.label(208, 156, "0", { size = 20 })
  W.near    = ui.label(208, 184, "", { size = 12, color = "dim" })
  S.hint, S.shown, S.callTxt = nil, nil, nil
  setHint("UP/DN pick   L/R zoom   SELECT QR")
end

local function showRadar()
  S.screen = "radar"
  buildRadar()
  paintCard()
  drawRadar(sys.millis())
end

-------------------------------------------------------------- invite (QR)

local function showQR()
  S.screen = "qr"
  ui.clear()
  W = {}
  ui.bg("bg")
  local drawn = false
  if ui.qr then
    drawn = pcall(function() W.qr = ui.qr(10, 14, 176, STORE_URL) end)
  end
  if not drawn then
    W.u1 = ui.label(10, 60, "Get Radar from the", { size = 14 })
    W.u2 = ui.label(10, 80, "badge App Store:", { size = 14 })
    W.u3 = ui.label(10, 104, "search Radar", { size = 20, color = "green" })
  end
  local X = 196
  W.t1 = ui.label(X, 14, "RADAR", { size = 20, color = "green" })
  W.t2 = ui.label(X, 40, "who's around you", { size = 12, color = "dim" })
  W.s1 = ui.label(X, 70, "1 scan with phone", { size = 12 })
  W.s2 = ui.label(X, 88, "2 install it on", { size = 12 })
  W.s3 = ui.label(X, 102, "  your badge", { size = 12 })
  W.s4 = ui.label(X, 120, "3 open Radar and", { size = 12 })
  W.s5 = ui.label(X, 134, "  look around", { size = 12 })
  W.t4 = ui.label(X, 166, "then share this", { size = 12, color = "dim" })
  W.t5 = ui.label(X, 180, "QR yourself", { size = 12, color = "dim" })
  S.hint = nil
  setHint("CANCEL back to radar")
end

----------------------------------------------------------------- the keys

local function setZoom(z)
  if z < 1 then z = 1 elseif z > 3 then z = 3 end
  if z == S.zoom then return end
  S.zoom = z
  storage.set("zoom", z)
  rebuild()
  ui.toast(RANGES[z].label .. ": " .. RANGES[z].sub)
  paintCard()
end

local function moveSel(d)
  local order = S.vis
  local n = #order
  local idx = 0
  if S.sel ~= "me" then
    for i = 1, n do
      if order[i] == S.sel then idx = i break end
    end
  end
  idx = idx + d                    -- 0 is YOU; wraps both ways
  if idx < 0 then idx = n end
  if idx > n then idx = 0 end
  S.sel = (idx == 0) and "me" or order[idx]
  wantProfile(S.sel)
  paintCard()
end

function on_key(k)
  if S.screen == "qr" then
    if k == "back" or k == "select" then showRadar() end
    if k == "down" then                    -- hidden: simulated people
      S.demo = not S.demo
      storage.set("demo", S.demo)
      ui.toast(S.demo and "Demo people ON" or "Demo people OFF")
    end
    return true
  end
  if k == "up"     then moveSel(-1) return true end
  if k == "down"   then moveSel(1)  return true end
  if k == "left"   then setZoom(S.zoom - 1) return true end
  if k == "right"  then setZoom(S.zoom + 1) return true end
  if k == "select" then showQR() return true end
  return false                     -- CANCEL on the radar closes the app
end

------------------------------------------------------------------- LEDs

-- LEDs 1-6 glow in the type colours of the six creatures nearest you; on
-- the QR screen a light chases to catch the other person's eye.
local ledKey, ledAcc = "", 0
local function leds(now)
  local key
  if S.screen == "qr" then
    key = "Q" .. ((now // 140) % 6 + 1)
  else
    key = "R" .. (S.vis[1] or "") .. "," .. (S.vis[2] or "") .. "," .. (S.vis[3] or "")
       .. "," .. (S.vis[4] or "") .. "," .. (S.vis[5] or "") .. "," .. (S.vis[6] or "")
  end
  if key == ledKey then return end
  ledKey = key
  if string.sub(key, 1, 1) == "Q" then
    local lit = tonumber(string.sub(key, 2))
    for j = 1, 8 do
      if j == lit then led.set(j, 20, 200, 120) else led.set(j, 40, 15, 80) end
    end
  else
    for j = 1, 6 do
      local id = S.vis[j]
      if id then
        local col = creature(id).led
        led.set(j, ((col >> 16) & 255) // 5, ((col >> 8) & 255) // 5, (col & 255) // 5)
      else
        led.set(j, 0, 0, 0)
      end
    end
    led.set(7, 0, 0, 0)
    led.set(8, 0, 0, 0)
  end
end

---------------------------------------------------------------- lifecycle

local frame, cardAcc = 0, 0
function on_tick(ms)
  local now = sys.millis()
  S.sweep = (S.sweep + 96 * ms / SWEEP_MS) % 96
  frame = frame + 1
  if S.screen == "radar" and frame % 2 == 0 then drawRadar(now) end
  cardAcc = cardAcc + ms
  if cardAcc >= 250 then
    cardAcc = 0
    if S.screen == "radar" and S.dirty then
      S.dirty = false
      paintCard()
    end
  end
  ledAcc = ledAcc + ms
  if ledAcc >= 60 then
    ledAcc = 0
    leds(now)
  end
end

function on_exit()
  led.off()
end

timer.every(POLL_MS, poll)
showRadar()
poll()
if storage.get("onboarded") ~= true then
  storage.set("onboarded", true)
  if me.x == "" then
    ui.toast("Link X at /profile so people see your name")
  else
    ui.toast("UP/DOWN to see who's around")
  end
end
