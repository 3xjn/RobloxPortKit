local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local total = 0
local function test(name, callback)
	local ok, message = pcall(callback); assert(ok, name .. ": " .. tostring(message))
	total += 1; print("PASS", name)
end
local globals = {Vector2 = roblox.Vector2, UDim = roblox.UDim, Color3 = roblox.Color3,
	Enum = {ResamplerMode = {Pixelated = "Pixelated"}}, Content = {fromObject = function(image) return image end}}
local function load(name)
	local fn, message = loadstring(fs.readFile("runtime/" .. name .. ".luau"), name); assert(fn, message)
	setfenv(fn, setmetatable(globals, {__index = getfenv()})); return fn()
end
for _, file in fs.readDir("runtime") do test("syntax " .. file, function() assert(loadstring(fs.readFile("runtime/" .. file))) end) end
local Input = load("Input")
local time = 1
local function input()
	return Input.new({connect = false, clock = function() return time end,
		bindings = {grab = {"ButtonL2", "ButtonR2", "Z"}, jump = {"Space", "ButtonA"}, primary = {"MouseButton1"}}})
end
local function event(key, z, kind) return {KeyCode = {Name = key}, Position = {X = 0, Y = 0, Z = z or 0}, UserInputType = {Name = kind or "Gamepad1"}} end
test("both analog triggers honor hysteresis and digital endpoints", function()
	for _, key in {"ButtonL2", "ButtonR2"} do
		local i = input()
		i:process("Changed", event(key, .24)); assert(not i:check("grab"))
		i:process("Changed", event(key, .25)); assert(i:check("grab"))
		i:process("Changed", event(key, .2)); assert(i:check("grab"))
		i:process("Changed", event(key, .179)); assert(not i:check("grab"))
		i:process("Began", event(key)); assert(i:check("grab"))
		i:process("Ended", event(key)); assert(not i:check("grab"))
	end
end)
test("sources aggregate, processed releases clear, other gamepads ignored", function()
	local i = input(); i:process("Began", event("ButtonL2")); i:process("Began", event("Z", 0, "Keyboard"))
	i:process("Ended", event("ButtonL2"), true); assert(i:check("grab"))
	i:process("Ended", event("Z", 0, "Keyboard"), true); assert(not i:check("grab"))
	i:process("Began", event("ButtonL2", 1, "Gamepad2")); assert(not i:check("grab"))
	i:process("Began", event("Space", 0, "Keyboard"), true); assert(not i:check("jump"))
end)
test("buffer is time limited and consumed once", function()
	local i = input(); time = 10; i:setSource("jump", "test", true); i:setSource("jump", "test", false)
	time = 10.1; assert(i:consumeBuffer("jump", .15)); assert(not i:consumeBuffer("jump", .15))
	i:setSource("jump", "test", true); time = 11; assert(not i:consumeBuffer("jump", .15))
end)
test("hold invert toggle and modal reset", function()
	local i = input(); i:setBehavior("grab", "Invert"); assert(i:check("grab")); i:setSource("grab", "key", true); assert(not i:check("grab"))
	i:setSource("grab", "key", false); i:setBehavior("grab", "Toggle")
	i:setSource("grab", "key", true); i:setSource("grab", "key", false); assert(i:check("grab"))
	i:setSource("grab", "key", true); assert(not i:check("grab"))
	i:setEnabled(false); i:setSource("jump", "key", true); assert(not i:check("jump")); i:setEnabled(true); assert(not i:check("jump"))
end)
test("all eight touch directions and deadzone", function()
	local i = input()
	for x = -1, 1 do for y = -1, 1 do if x ~= 0 or y ~= 0 then
		i:setTouchDirection(x * 60, y * 60)
		assert(i:axis("left", "right", "X") == x and i:axis("up", "down", "Y") == y)
	end end end
	i:setTouchDirection(2, 2); assert(i:axis("left", "right", "X") == 0)
end)
test("mouse normalization clamps and tracks canvas inclusion", function()
	local i = input(); i.canvas = {AbsolutePosition = roblox.Vector2.new(100, 50), AbsoluteSize = roblox.Vector2.new(400, 200)}
	i:updatePointer({X = 300, Y = 150}); assert(i.pointer.x == .5 and i.pointer.y == .5 and i.pointer.inside)
	i:updatePointer({X = 0, Y = 150}); assert(i.pointer.x == 0 and not i.pointer.inside)
	i:process("Began", event("Unknown", 0, "MouseButton1")); assert(i:check("primary"))
end)
test("touch visibility follows last device and explicit overrides", function()
	local i = input(); i.overlay = {}; i.uis = {TouchEnabled = true}
	i.lastType = "Touch"; i:updateTouchVisibility(); assert(i.overlay.Visible)
	i.lastType = "Keyboard"; i:updateTouchVisibility(); assert(not i.overlay.Visible)
	i:setTouchMode("On"); assert(i.overlay.Visible); i:setTouchMode("Off"); assert(not i.overlay.Visible)
	i:setTouchMode("Auto"); i.lastType = "Gamepad1"; i:updateTouchVisibility(); assert(not i.overlay.Visible)
end)
local Atlas = load("AtlasPool")
local function image() return {WritePixelsBuffer = function() end, Destroy = function(self) self.destroyed = true end} end
test("LRU evicts only unpinned and enforces hard budget", function()
	local p = Atlas.new({maxPages = 2, create = image}); local pixels = buffer.create(16)
	local a = p:acquire("a", 2, 2, pixels); p:acquire("b", 2, 2, pixels); p:pin("a"); p:acquire("c", 2, 2, pixels)
	assert(p.images.a and not p.images.b and p.count == 2 and not a.destroyed)
	p:pin("c"); assert(not pcall(function() p:acquire("d", 2, 2, pixels) end))
	p:releasePins(); p:destroy(); assert(p.count == 0 and a.destroyed)
end)
test("image allocation retry, invalid sizes and failed uploads", function()
	local fail = false
	local p = Atlas.new({maxPages = 3, create = function() if fail then fail = false; return nil end; return image() end})
	p:acquire("a", 1, 1, buffer.create(4)); fail = true; p:acquire("b", 1, 1, buffer.create(4)); assert(not p.images.a and p.images.b)
	assert(not pcall(function() p:acquire("big", 1025, 1, buffer.create(4)) end))
	assert(not pcall(function() p:acquire("bad", 1, 1, buffer.create(2)) end)); assert(p.count == 1)
end)
test("unchanged scenes write zero properties; hidden slots and styles reset", function()
	local Scene = load("GpuScene"); local scene = Scene.new({}, function() return {Destroy = function() end} end)
	local props = {ImageContent = "image", ZIndex = 1, Position = "p"}
	scene:begin(); scene:image(props); scene:frame({Size = "size"}, 4, {color = roblox.Color3.new(1, 0, 0)}); scene:finish(); assert(scene.writes > 0)
	scene:begin(); scene:image(props); scene:frame({Size = "size"}, 4, {color = roblox.Color3.new(1, 0, 0)}); scene:finish(); assert(scene.writes == 0)
	scene:begin(); scene:frame({Size = "size"}); scene:finish(); assert(scene.images[1].object.Visible == false and not scene.frames[1].stroke.object.Enabled)
	scene:begin(); scene:frame({Size = "size"}); scene:finish(); assert(scene.writes == 0)
end)
test("Fit PixelPerfect and Stretch scaling", function()
	local Shell = load("Shell")
	local s, w, h = Shell.computeScale(320, 180, roblox.Vector2.new(1000, 600), "Fit"); assert(s == 3.125 and w == 320 and h == 180)
	s = Shell.computeScale(320, 180, roblox.Vector2.new(1000, 600), "PixelPerfect"); assert(s == 3)
	s, w, h = Shell.computeScale(320, 180, roblox.Vector2.new(1000, 600), "Stretch"); assert(w * s == 1000 and h * s == 600)
end)
local Server = load("SaveServer")
local function clone(t) local out = {}; for k, v in t do out[k] = if type(v) == "table" then clone(v) else v end; return out end
local function server(store)
	return Server.new({store = store, retrySeconds = 0, guid = function() return "session" end,
		blank = function() return {value = 0} end,
		validate = function(data) return type(data) == "table" and type(data.value) == "number", data end,
		merge = function(old, data) old.value = math.max(old.value, data.value); return old end})
end
test("monotonic merging idempotent retry stale packets and validation", function()
	local stored = {value = 5, revision = 8}; local writes = 0
	local s = server({GetAsync = function() return clone(stored) end, UpdateAsync = function(_, _, callback)
		writes += 1; stored = callback(clone(stored)); stored = callback(clone(stored)); return clone(stored)
	end})
	assert(s:load("u1").ok)
	local request = {sequence = 1, revision = 0, data = {value = 10}}
	assert(s:commit("u1", request).revision == 9 and stored.value == 10)
	assert(s:commit("u1", request).revision == 9 and writes == 1)
	assert(not s:commit("u1", {sequence = 2, revision = 9, data = false}).ok)
	assert(not s:commit("u1", {sequence = 0/0, revision = 9, data = {value = 1}}).ok)
end)
test("failed loads never write and failed commits flush pending", function()
	local writes = 0; local failLoad, failSave = true, true
	local s = server({GetAsync = function() if failLoad then error("offline") end end,
		UpdateAsync = function(_, _, fn) writes += 1; if failSave then error("offline") end; return fn({value = 1}) end})
	assert(not s:load("u1").ok); assert(not s:commit("u1", {sequence = 1, revision = 0, data = {value = 2}}).ok and writes == 0)
	failLoad = false; assert(s:load("u1").ok)
	assert(not s:commit("u1", {sequence = 1, revision = 0, data = {value = 2}}).ok)
	failSave = false; assert(s:flush("u1").ok and not s.sessions.u1.pending)
end)
test("client retains failed payload sequence and marks Studio offline honestly", function()
	local Client = load("SaveClient"); local fail = false; local seen = {}; local applied
	local c = Client.new({isStudio = true, snapshot = function() return {value = 7} end, apply = function(data, sent) applied = sent end,
		remote = {InvokeServer = function(_, request)
			table.insert(seen, request); if fail then error("offline") end
			return {ok = true, data = {}, revision = 2}
		end}})
	assert(c:sync()); fail = true; assert(not c:sync()); assert(c.lastStatus:match("Studio"))
	fail = false; assert(c:sync()); assert(seen[2] == seen[3] and applied.value == 7)
end)
test("rolling stats and native stripping", function()
	local Benchmark = load("Benchmark"); local b = Benchmark.new(3)
	for _, n in {10, 1, 2, 3} do b:record(n / 1000, 1 / 240) end
	local s = b:stats(); assert(s.samples == 3 and s.meanMs == 2 and s.p50Ms == 2 and s.p95Ms == 3 and s.maxMs == 3)
	assert(math.abs(s.observedRenderFPS - 240) < .001)
	assert(Benchmark.stripNative("--!native\nreturn 1") == "return 1")
end)
print("PortKit runtime checks:", total)
