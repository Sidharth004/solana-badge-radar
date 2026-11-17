-- Offline harness for Radar.  Run:  lua test.lua   (Lua 5.5)
-- Mocks the badge API and checks: the creature art is valid badge pixel art,
-- everyone in range shows up (no app needed on their side), the same person is
-- the same creature on every badge, picking, the invite QR, X lookups, zoom,
-- a 400-badge hall against the 200k instruction budget, hostile input, old
-- firmware, and that every card string fits its column.

local PASS, FAIL = 0, 0
local function ok(cond, what)
  if cond then PASS = PASS + 1; print("  ok   " .. what)
  else FAIL = FAIL + 1; print("  FAIL " .. what) end
end
local function copy(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, e in pairs(v) do o[k] = copy(e) end
  return o
end

-- the badge's built-in pixel-art characters (LUA_API.md, "Pixel art")
local ART = {}
for ch in string.gmatch(". #kwpgmvblyoa", ".") do ART[ch] = true end
local function validRows(rows)
  if type(rows) ~= "table" or #rows == 0 then return false, "not rows" end
  for i, r in ipairs(rows) do
    if type(r) ~= "string" then return false, "row " .. i .. " not a string" end
    for ch in string.gmatch(r, ".") do
      if not ART[ch] then return false, "row " .. i .. " has '" .. ch .. "'" end
    end
  end
  return true
end

CLOCK = 0
local badges = {}
local PROFILES = { AAA111 = { name = "Alice", x = "alice_onX" } }
local INSTR_LIMIT = 200000
local N, PAUSED = 0, false
debug.sethook(function() if not PAUSED then N = N + 1 end end, "", 100)
local function counted(B, label, fn, ...)
  local n0 = N
  local good, err = pcall(fn, ...)
  local n = (N - n0) * 100
  if n > (B.maxInstr[label] or 0) then B.maxInstr[label] = n end
  if not good then B.errors[#B.errors + 1] = label .. ": " .. tostring(err) end
  return good, err
end

local function newBadge(id, owner, opts)
  opts = opts or {}
  local B = { id = id, owner = owner, store = {}, timers = {}, nt = 1, objs = 0,
    peak = 0, toasts = {}, sent = 0, errors = {}, near = {}, online = true,
    at = {}, qrText = nil, leds = {}, profCalls = 0, queue = {}, maxInstr = {},
    sprite = nil, stamps = 0, badArt = nil }
  local env = {}
  for _, k in ipairs({ "assert", "error", "ipairs", "next", "pairs", "pcall",
      "select", "tonumber", "tostring", "type", "xpcall", "print",
      "getmetatable", "setmetatable", "rawequal", "rawget", "rawlen", "rawset",
      "_VERSION", "string", "table", "math", "utf8", "coroutine" }) do
    env[k] = _G[k]
  end
  env._G = env
  local function art(rows, where)
    local good, why = validRows(rows)
    if not good then B.badArt = where .. ": " .. why; error("bad pixel art: " .. why) end
  end
  local function obj(kind, x, y, txt)
    B.objs = B.objs + 1
    if B.objs > B.peak then B.peak = B.objs end
    local o = { kind = kind, txt = txt or "" }
    if x then B.at[x .. "," .. y] = o end
    function o:text(t) self.txt = tostring(t) end
    function o:pos(nx, ny) self.x, self.y = nx, ny end
    function o:color(c) self.col = c end
    function o:show() end
    function o:size() end
    function o:remove() B.objs = B.objs - 1 end
    function o:clear() end
    function o:pixel() end
    function o:rect() end
    function o:line() end
    function o:image(rows) art(rows, "c:image"); B.stamps = B.stamps + 1 end
    function o:set(rows) art(rows, "image:set"); B.sprite = rows end
    return o
  end
  env.ui = {
    W = 320, H = 218,
    bg = function() end,
    label = function(x, y, t, o) local l = obj("label", x, y, tostring(t or "")); l.col = o and o.color; return l end,
    rect = function() return obj("rect") end,
    canvas = (not opts.oldOS) and function() return obj("canvas") end or nil,
    image = (not opts.oldOS) and function(x, y, rows, o)
      art(rows, "ui.image")
      assert(o and o.scale and o.scale >= 1 and o.scale <= 16, "image scale")
      B.sprite = rows
      return obj("image")
    end or nil,
    qr = (not opts.oldOS) and function(_, _, size, text)
      assert(size >= 25 and size <= 218, "qr size")
      assert(#text <= 256, "qr text too long")
      B.qrText = text
      return obj("qr")
    end or nil,
    hint = function(s) B.hint = s end,
    toast = function(s) B.toasts[#B.toasts + 1] = s end,
    clear = function() B.objs = 0; B.at = {}; B.qrText = nil end,
  }
  env.led = {
    count = 8,
    set = function(i, r, g, b)
      assert(i >= 1 and i <= 8, "led index")
      assert(r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and b <= 255, "led value")
      B.leds[i] = { r, g, b }
    end,
    fill = function(r, g, b) for i = 1, 8 do B.leds[i] = { r, g, b } end end,
    off = function() for i = 1, 8 do B.leds[i] = nil end end,
  }
  env.timer = {
    after = function(ms, fn) assert(ms >= 20); local t = B.nt; B.nt = t + 1
      B.timers[t] = { due = CLOCK + ms, fn = fn }; return t end,
    every = function(ms, fn) assert(ms >= 20); local t = B.nt; B.nt = t + 1
      B.timers[t] = { due = CLOCK + ms, fn = fn, rep = ms }; return t end,
    cancel = function(t) B.timers[t] = nil end,
  }
  env.sys = { millis = function() return CLOCK end, time = function() return 1763300000 end,
              keys = function() return {} end, exit = function() end }
  env.badge = { id = function() return B.id end, owner = function() return B.owner end,
                online = function() return B.online end }
  env.storage = { get = function(k) return copy(B.store[k]) end,
                  set = function(k, v) B.store[k] = copy(v) end,
                  remove = function(k) B.store[k] = nil end }
  env.profile = {
    get = function(bid, cb)
      B.profCalls = B.profCalls + 1
      B.queue[#B.queue + 1] = { due = CLOCK + 300, fn = function()
        local p = PROFILES[bid]
        if not B.online then cb(false, "offline")
        elseif p then cb(true, copy(p)) else cb(false, "no profile") end
      end }
    end,
  }
  env.mesh = {
    nearby = function()
      local was = PAUSED
      PAUSED = true                       -- the OS builds this list in C
      local out = {}
      for _, e in ipairs(B.near) do out[#out + 1] = copy(e) end
      table.sort(out, function(a, b)
        local x, y = tonumber(a.rssi) or -999, tonumber(b.rssi) or -999
        if x ~= x then x = -999 end
        if y ~= y then y = -999 end
        return x > y
      end)
      PAUSED = was
      return out
    end,
    send = function() B.sent = B.sent + 1; return true end,
    info = function() return { channel = 149, band = "5", online = B.online } end,
  }
  B.env = env
  return B
end

local function boot(B)
  local chunk, err = loadfile("main.lua", "t", B.env)
  assert(chunk, err)
  B.alive = true
  return (counted(B, "boot", chunk))
end
local function step(dt)
  CLOCK = CLOCK + dt
  for _, B in ipairs(badges) do
    if B.alive then
      for i = #B.queue, 1, -1 do
        local q = B.queue[i]
        if CLOCK >= q.due then table.remove(B.queue, i); counted(B, "profile cb", q.fn) end
      end
      for t, tm in pairs(B.timers) do
        if CLOCK >= tm.due then
          if tm.rep then tm.due = CLOCK + tm.rep else B.timers[t] = nil end
          counted(B, "timer", tm.fn)
        end
      end
      counted(B, "on_tick", B.env.on_tick, dt)
    end
  end
end
local function run(ms) for _ = 1, ms // 30 do step(30) end end
local function key(B, k) counted(B, "on_key", B.env.on_key, k) end
local function plain(B, id, name, rssi, kind)
  B.near[#B.near + 1] = { id = id, name = name, level = 2, rssi = rssi, kind = kind or "badge", bridged = false }
end
local function L(B, x, y) local o = B.at[x .. "," .. y]; return o and o.txt or nil end
local function errs(B) return #B.errors == 0 and "none" or B.errors[1] end
local function pick(B, name)
  for _ = 1, 60 do
    if L(B, 208, 66) == name then return true end
    key(B, "down")
  end
  return L(B, 208, 66) == name
end

--==========================================================================
print("\n== 1. the creature art ==")
-- pull the art tables straight out of main.lua and check every combination
local src = io.open("main.lua"):read("a")
local a = src:find("local SPECIES = {", 1, true)
local b = src:find("-- Same badge id", 1, true)
local artChunk = assert(load(src:sub(a, b - 1) .. "\nreturn SPECIES, TYPES, SHINY, paint, hash32"))
local SPECIES, TYPES, SHINY, paint, hash32 = artChunk()
local tmplOK, sizeOK, nameOK = true, true, true
for _, sp in ipairs(SPECIES) do
  if #sp[2] ~= 10 then sizeOK = false end
  for _, r in ipairs(sp[2]) do
    if #r ~= 10 then sizeOK = false end
    if r:find("[^%.XYEk]") then tmplOK = false end
  end
end
ok(#SPECIES == 15, "15 species")
ok(sizeOK, "every species is exactly 10 x 10")
ok(tmplOK, "templates use only X Y E k .")
local allValid, combos = true, 0
for si, sp in ipairs(SPECIES) do
  for ti, ty in ipairs(TYPES) do
    combos = combos + 1
    if not validRows(paint(sp[2], ty[2], ty[3])) then allValid = false end
  end
  if not validRows(paint(sp[2], SHINY[2], SHINY[3])) then allValid = false end
end
ok(allValid, "all " .. combos .. " species x type combos (and shinies) are valid badge pixel art")
-- The badge's Lua has 32-bit integers; this desktop Lua has 64-bit ones.
-- A literal of 2^31 or more becomes a float on the badge and crashes it.
local big = nil
for lit in src:gmatch("0[xX]%x+") do if tonumber(lit) >= 0x80000000 then big = lit end end
for lit in src:gmatch("%f[%w]%d%d%d%d%d%d%d%d%d%d+") do if tonumber(lit) >= 2147483648 then big = lit end end
ok(big == nil, "no integer literal needs more than 32 bits (" .. tostring(big) .. ")")
local h31 = true
for i = 1, 2000 do local h = hash32(string.format("K%05d", i)); if h < 0 or h >= 2147483648 then h31 = false end end
ok(h31, "creature hash stays inside 31 bits")
local shinies = 0
for i = 1, 6400 do if ((hash32(string.format("K%05d", i)) >> 16) % 32) == 0 then shinies = shinies + 1 end end
ok(shinies > 120 and shinies < 290, "shinies about 1 in 32 (" .. shinies .. " of 6400)")

print("\n== 2. sees badges that do NOT run the app ==")
local A = newBadge("AAA111", "@alice")
badges = { A }
plain(A, "P00001", "Ben Builder", -48)
plain(A, "P00002", "Cara",        -58)
plain(A, "P00003", "Dev Dave",    -70)
plain(A, "P00004", "",            -82)
plain(A, "P00005", "Far Fran",    -91)
plain(A, "BEACON", "Zaphod",      -66, "beacon")
ok(boot(A), "boots: " .. errs(A))
run(1500)
ok(L(A, 208, 156) == "5", "AROUND YOU = 5 (beacons not counted): " .. tostring(L(A, 208, 156)))
ok(L(A, 208, 184) == "near Zaphod", "nearest beacon as a landmark")
ok(A.stamps > 0, "creatures stamped onto the radar")
ok(A.badArt == nil, "every sprite drawn was valid: " .. tostring(A.badArt))
ok(A.sent == 0, "sends nothing over the mesh")
local welcomed = false
for _, t in ipairs(A.toasts) do if t:find("who's around") then welcomed = true end end
ok(welcomed, "first launch shows how to use it")

print("\n== 3. the card shows the person's X name ==")
ok(L(A, 208, 66) == "@alice" and L(A, 208, 86) == "this is you", "starts on YOU")
ok(L(A, 272, 4) == "YOU", "tagged YOU, no dex number: " .. tostring(L(A, 272, 4)))
local mine = A.sprite
key(A, "down")
ok(L(A, 208, 66) == "Ben Builder", "DOWN picks the nearest: " .. tostring(L(A, 208, 66)))
ok(L(A, 208, 106) == "very close ||||", "band: " .. tostring(L(A, 208, 106)))
ok(A.sprite ~= nil and A.sprite ~= mine, "card sprite switches to Ben's creature")
local benArt = table.concat(A.sprite)
ok(L(A, 272, 4) == "", "no tag on other people")
key(A, "down")
ok(L(A, 208, 66) == "Cara", "then Cara")
key(A, "up"); key(A, "up")
ok(L(A, 208, 86) == "this is you", "UP back to YOU")
key(A, "up")
ok(L(A, 208, 66) == "Dev Dave", "UP from YOU wraps to the farthest one in view (AREA zoom hides < -75 dBm)")

print("\n== 4. same person, same creature, on every badge ==")
local C = newBadge("CCC333", "@carol")
badges = { A, C }
plain(C, "P00001", "Ben Builder", -55)
ok(boot(C), "second badge boots: " .. errs(C))
run(1500)
ok(pick(C, "Ben Builder"), "C picks Ben")
ok(table.concat(C.sprite) == benArt, "Ben is the same creature on both badges")

print("\n== 5. invite QR ==")
key(A, "select")
ok(A.qrText == "https://solana.com/breakpoint/badge/apps/app?id=badge-radar", "QR: " .. tostring(A.qrText))
run(300)
ok(A.leds[1] ~= nil, "LEDs chase on the QR screen")
key(A, "back")
ok(A.qrText == nil and L(A, 208, 156) ~= nil, "CANCEL back to the radar")
ok(pick(A, "Cara"), "pick someone")
key(A, "select")
ok(A.qrText ~= nil, "SELECT on anyone shows the same QR")
key(A, "select")
ok(A.qrText == nil, "SELECT again closes it")

print("\n== 6. X handle, only when Wi-Fi works ==")
plain(C, "AAA111", "Alice", -50)
run(1500)
ok(pick(C, "Alice"), "C picks Alice")
run(1500)
ok(L(C, 208, 86) == "@alice_onX", "C shows Alice's @handle: " .. tostring(L(C, 208, 86)))
local calls = C.profCalls
for _ = 1, 3 do key(C, "down"); key(C, "up") end
run(3000)
ok(C.profCalls == calls, "looked up once, cached")
local D = newBadge("DDD444", "@dan")
D.online = false
plain(D, "AAA111", "Alice", -50)
badges = { A, C, D }
ok(boot(D), "offline badge boots")
run(1500)
ok(pick(D, "Alice"), "offline badge picks Alice")
run(2000)
ok(D.profCalls == 0 and L(D, 208, 86) == "", "no server call while offline; line stays empty")
D.alive = false
badges = { A, C }

print("\n== 7. zoom ==")
for _ = 1, 60 do if L(A, 208, 86) == "this is you" then break end; key(A, "up") end
key(A, "left"); key(A, "left")
ok(L(A, 4, 2) == "CLOSE", "zoom label CLOSE")
local seen = {}
for _ = 1, 12 do key(A, "down"); seen[L(A, 208, 66) or "?"] = true end
ok(seen["Ben Builder"] and seen["Cara"], "CLOSE keeps the near ones")
ok(not seen["Dev Dave"] and not seen["Far Fran"], "CLOSE hides the far ones")
key(A, "right"); key(A, "right")
for _ = 1, 12 do key(A, "down"); seen[L(A, 208, 66) or "?"] = true end
ok(seen["Far Fran"] and seen["P00004"], "ALL shows everyone; unnamed badge shows its id")
ok(A.store["zoom"] == 3, "zoom remembered")

print("\n== 8. hostile nearby input ==")
local before = #A.errors
A.near[#A.near + 1] = { id = 7, name = "x", rssi = -50, kind = "badge" }
A.near[#A.near + 1] = { id = "NAN001", name = {}, rssi = 0/0, kind = "badge" }
A.near[#A.near + 1] = { id = "HUGE01", name = "\1\2bad\200", rssi = 1e9, kind = "badge" }
A.near[#A.near + 1] = { id = string.rep("L", 200), name = "long", rssi = -50, kind = "badge" }
A.near[#A.near + 1] = { id = "BRIDGE", name = "emu", rssi = 0, bridged = true, kind = "badge" }
A.near[#A.near + 1] = "not a table"
run(2500)
ok(#A.errors == before, "junk ignored, not fatal: " .. errs(A))
ok(pick(A, "emu") and L(A, 208, 106) == "bridged ~~~~", "bridged badge shown in ALL, labelled")
ok(pick(A, "bad"), "control characters stripped from names")

print("\n== 9. a keynote hall: 400 badges ==")
local H = newBadge("HHH999", "@hall")
badges = { H }
for i = 1, 400 do plain(H, string.format("K%05d", i), "Guest number " .. i, -45 - (i % 50)) end
for i = 1, 15 do plain(H, string.format("BC%04d", i), "Beacon " .. i, -60 - i, "beacon") end
ok(boot(H), "boots in a crowd: " .. errs(H))
run(4000)
key(H, "right")
run(2000)
for _ = 1, 40 do key(H, "down") end
run(2000)
ok(#H.errors == 0, "no errors: " .. errs(H))
ok(L(H, 208, 156) == "400", "AROUND YOU = 400")
print(string.format("     worst VM instructions: poll %d, radar frame %d, key %d  (limit %d)",
  H.maxInstr["timer"] or 0, H.maxInstr["on_tick"] or 0, H.maxInstr["on_key"] or 0, INSTR_LIMIT))
ok((H.maxInstr["timer"] or 0) < INSTR_LIMIT * 0.75, "poll well inside the budget")
ok((H.maxInstr["on_tick"] or 0) < INSTR_LIMIT * 0.75, "radar frame well inside the budget")
ok((H.maxInstr["on_key"] or 0) < INSTR_LIMIT * 0.75, "keys well inside the budget")
print("     peak UI objects: " .. H.peak .. " (limit 128)")
ok(H.peak <= 128, "UI objects inside the limit")
local nt = 0
for _ in pairs(H.timers) do nt = nt + 1 end
ok(nt <= 8, "timers: " .. nt .. " (limit 8)")
ok(H.badArt == nil, "400 creatures drawn, all valid art")

print("\n== 10. old firmware ==")
local O = newBadge("OOO000", "@old", { oldOS = true })
badges = { O }
plain(O, "P00001", "Ben Builder", -50)
ok(boot(O), "boots without canvas/image/qr: " .. errs(O))
run(1500)
ok(L(O, 208, 156) == "1", "card still counts people")
key(O, "select")
ok(L(O, 10, 104) == "search Radar", "invite falls back to text")
key(O, "back"); run(500)
ok(#O.errors == 0, "no errors: " .. errs(O))

print("\n== 11. no X linked yet ==")
local U = newBadge("UUU000", nil)
badges = { U }
ok(boot(U), "unclaimed badge boots: " .. errs(U))
run(1500)
ok(L(U, 208, 66) == "you" and L(U, 208, 86) == "link X /profile", "asks you to link X")
local told = false
for _, t in ipairs(U.toasts) do if t:find("Link X") then told = true end end
ok(told, "first launch says to link X")

print("\n== 12. demo people ==")
local Z = newBadge("ZZZ000", "@zed")
badges = { Z }
ok(boot(Z), "boots: " .. errs(Z))
run(1500)
ok(L(Z, 208, 156) == "0", "alone: nobody around")
key(Z, "select"); key(Z, "down"); key(Z, "back")
ok(Z.store["demo"] == true, "DOWN on the QR screen turns demo on, remembered")
run(2500)
ok(tonumber(L(Z, 208, 156) or "0") >= 5, "demo people appear: " .. tostring(L(Z, 208, 156)))
ok(L(Z, 4, 2) == "AREA  demo", "zoom label says demo")
ok(pick(Z, "Ana Builder") and L(Z, 208, 86) == "@ana_builds", "demo person has an X name and @handle")
ok(Z.profCalls == 0, "no server lookups for demo people")
key(Z, "right"); key(Z, "right")
local counts = {}
for _ = 1, 40 do run(1000); counts[L(Z, 208, 156) or "?"] = true end
local nc = 0
for _ in pairs(counts) do nc = nc + 1 end
ok(nc >= 2, "someone walks in and out of range")
ok(#Z.errors == 0 and Z.badArt == nil, "no errors: " .. errs(Z))
key(Z, "select"); key(Z, "down"); key(Z, "back")
run(32000)
ok(L(Z, 208, 156) == "0" and Z.store["demo"] == false, "demo off: they leave")

print("\n== 13. every card string fits its column ==")
local function over(B)
  local bad = {}
  for k, o in pairs(B.at) do
    local x = tonumber(k:match("^(%d+),"))
    if o.kind == "label" and x and x >= 208 then
      local maxc = (x >= 272) and 6 or 15
      if #o.txt > maxc then bad[#bad + 1] = k .. "=" .. o.txt end
    end
  end
  return bad
end
local bad = {}
badges = { A, C }
for _, B in ipairs({ A, C }) do
  for _ = 1, 14 do
    for _, x in ipairs(over(B)) do bad[#bad + 1] = x end
    key(B, "down"); run(300)
  end
end
ok(#bad == 0, "no overflow (" .. (bad[1] or "none") .. ")")

print(string.format("\n%d passed, %d failed\n", PASS, FAIL))
if FAIL > 0 then error("tests failed", 0) end
