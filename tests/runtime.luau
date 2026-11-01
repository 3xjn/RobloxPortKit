--!optimize 2
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local total = 0
local function test(name, callback)
	local ok, message = pcall(callback); assert(ok, name .. ": " .. tostring(message))
	total += 1; print("PASS", name)
end
local globals = {Vector2 = roblox.Vector2, UDim2 = roblox.UDim2, UDim = roblox.UDim, Color3 = roblox.Color3,
	Enum = {ResamplerMode = {Pixelated = "Pixelated"}}, Content = {fromObject = function(image) return image end,none='empty'}}
local function load(name)
	local fn, message = loadstring(fs.readFile("runtime/" .. name .. ".luau"), name); assert(fn, message)
	setfenv(fn, setmetatable(globals, {__index = getfenv()})); return fn()
end
globals.script={Parent=setmetatable({},{__index=function(_,name)return name end})};globals.require=load
test('native payload decoding validates declared sizes',function()
    local payload=load('Payload')
    globals.Enum.CompressionAlgorithm={Zstd='zstd'}
    local service={Base64Decode=function(_,text)return text end,
        GetDecompressedBufferSize=function()return 3 end,DecompressBuffer=function()return buffer.fromstring('abc')end}
    assert(buffer.tostring(payload.decode('test',{bytes=3,compression='zstd'},nil,service))=='abc')
    assert(not pcall(payload.decode,'test',{bytes=9,compression='zstd'},nil,service))
end)
for _, file in fs.readDir("runtime") do test("syntax " .. file, function() assert(loadstring(fs.readFile("runtime/" .. file))) end) end
test('preloader batches deduplicated assets and preserves progress', function()
    local created, batches = {}, {}
    local scheduler = {spawn=function(fn) fn() end, wait=function() end}
    local provider = {PreloadAsync=function(_, batch, callback)
        batches[#batches+1]=#batch
        for _, object in batch do callback(object.SoundId or object.Image, 'Success'); callback(object.SoundId or object.Image, 'Success') end
    end}
    local p=load('Preloader').new({headless=true, contentProvider=provider, scheduler=scheduler, batchSize=2,
        instanceFactory=function(class) local object={class=class,Destroy=function(self) self.destroyed=true end};created[#created+1]=object;return object end})
    local result=p:preload({sounds={'a','a','b'},images={'c','a'}})
    assert(result.total==3 and result.completed==3 and result.status=='complete')
    assert(#batches==2 and batches[1]==2 and batches[2]==1 and p.target==.85)
    p:setStage('Initialize',.9);p:setStage('Earlier',.2);assert(p.target==.9)
    p:finish();assert(p.destroyed and p.target==1)
    for _, object in created do assert(object.destroyed) end
end)
test('preloader timeout and late callbacks are safe', function()
    local pending, callback
    local scheduler={spawn=function(fn) pending=fn end,wait=function() end}
    local p=load('Preloader').new({headless=true,timeoutSec=.001,scheduler=scheduler,
        instanceFactory=function() return {Destroy=function()end} end,
        contentProvider={PreloadAsync=function(_, batch, cb) callback=cb end}})
    local result=p:preload({sounds={'a'}});assert(result.status=='timeout' and result.completed==0)
    pending();callback('a','Success');assert(result.completed==0 and p.target==0)
    p:fail('Unable to load');p:finish();assert(p.failed and not p.destroyed);p:destroy()
end)
local Input = load("Input")
test("shell settings button follows configured input policy", function()
	globals.Enum.UserInputType = {Touch = "Touch", Keyboard = "Keyboard"}
	local shell = load("Shell")
	local touch, keyboard = globals.Enum.UserInputType.Touch, globals.Enum.UserInputType.Keyboard
	assert(shell.settingsButtonVisible(nil, false, keyboard))
	assert(shell.settingsButtonVisible(true, false, keyboard))
	assert(not shell.settingsButtonVisible(false, true, touch))
	assert(shell.settingsButtonVisible("TouchOnly", true, touch))
	assert(not shell.settingsButtonVisible("TouchOnly", true, keyboard))
	assert(not shell.settingsButtonVisible("TouchOnly", false, touch))
end)
test("shell CoreGui defaults, chat policy and overrides", function()
	local shell = load("Shell")
	globals.Enum.CoreGuiType = {Backpack = "Backpack", Health = "Health", EmotesMenu = "EmotesMenu", PlayerList = "PlayerList", Chat = "Chat"}
	local scheduler = {spawn = function(fn) fn() end, wait = function() end}
	local function run(options)
		local calls, configs = {}, {}
		for _, name in {"ChatWindowConfiguration", "ChatInputBarConfiguration", "BubbleChatConfiguration"} do configs[name] = {Enabled = true} end
		options.scheduler = scheduler
		options.starterGui = {SetCoreGuiEnabled = function(_, kind, enabled) calls[kind] = enabled end}
		options.textChatService = {FindFirstChildOfClass = function(_, name) return configs[name] end}
		shell.configureCoreGui(options)
		return calls, configs
	end
	local calls, configs = run({})
	for _, name in {"Backpack", "Health", "EmotesMenu", "PlayerList"} do assert(calls[name] == false) end
	assert(calls.Chat == nil and configs.ChatWindowConfiguration.Enabled)
	for _, options in {{singlePlayer = true}, {chat = false}, {singlePlayer = true, chat = false, coreGui = {Chat = true}}} do
		calls, configs = run(options); assert(calls.Chat == false)
		for _, item in configs do assert(item.Enabled == false) end
	end
	calls, configs = run({singlePlayer = true, chat = true, coreGui = {Backpack = true, Chat = false}})
	assert(calls.Backpack == true and calls.Chat == nil and configs.BubbleChatConfiguration.Enabled)
	calls = run({coreGui = {Chat = false, PlayerList = true}})
	assert(calls.Chat == false and calls.PlayerList == true)
end)
test("shell CoreGui retries independently and stops at destruction", function()
	local shell = load("Shell")
	local counts, waits, warnings = {}, 0, 0
	local previousWarn = globals.warn
	globals.warn = function() warnings += 1 end
	local scheduler = {spawn = function(fn) fn() end, wait = function() waits += 1 end}
	local starter = {SetCoreGuiEnabled = function(_, kind)
		counts[kind] = (counts[kind] or 0) + 1
		if kind == "Health" or (kind == "Backpack" and counts[kind] < 3) then error("not ready") end
	end}
	shell.configureCoreGui({starterGui = starter, scheduler = scheduler})
	assert(counts.Backpack == 3 and counts.Health == 10 and counts.PlayerList == 1 and waits == 9 and warnings == 1)
	counts = {}; waits = 0
	shell.configureCoreGui({starterGui = starter, scheduler = scheduler}, function() return waits == 0 end)
	assert(counts.Health == 1 and waits == 1)
	globals.warn = previousWarn
end)
test("shell suppression tolerates absent services and chat configurations", function()
	local shell = load("Shell")
	local oldGame = globals.game
	globals.game = {GetService = function() error("unavailable") end}
	shell.configureCoreGui({singlePlayer = true})
	local chat = {FindFirstChildOfClass = function(_, name)
		if name == "ChatWindowConfiguration" then error("unavailable") end
		return nil
	end}
	shell.configureCoreGui({chat = false, textChatService = chat})
	globals.game = oldGame
end)
test('binary file storage round trips bytes and preserves concurrent edits',function()
    local B=load('Base64');local raw=''
    for i=0,255 do raw..=string.char(i)end
    for _,value in {'','a','ab','abc',raw}do assert(B.decode(B.encode(value))==value)end
    assert(not B.isValid('ab=c'))
    local F=load('FileStore');local a,b=F.new('a'),F.new('b')
    a:write('saves/0.bin',raw);b:apply(a:snapshot());assert(b:read('saves/0.bin')==raw)
    local sent=a:snapshot();a:write('saves/0.bin','later');a:apply(sent,sent)
    assert(a.dirty and a:read('saves/0.bin')=='later')
    b:write('saves/1.bin','other');a:apply(b:snapshot())
    assert(a:read('saves/1.bin')=='other'and a:read('saves/0.bin')=='later')
    a:delete('saves/0.bin');b:apply(a:snapshot());assert(not b:exists('saves/0.bin'))
    assert(F.validate(a:snapshot()))
    local invalid=a:snapshot();invalid.files['../escape']=invalid.files['saves/1.bin'];assert(not F.validate(invalid))
end)
test('achievement ledger validates IDs, merges monotonically and unlocks once',function()
    local A=load('Achievements');local count=0;local definitions={{id='CH1'},{id='STRB1'}}
    local a=A.new(definitions,function()count+=1 end)
    assert(a:unlock('CH1') and not a:unlock('CH1') and count==1)
    a:merge({STRB1=true});a:merge({});assert(a:has('CH1')and a:has('STRB1'))
    local snapshot=a:snapshot();snapshot.CH1=nil;assert(a:has('CH1'))
    assert(not A.validate({CHEAT=true},definitions));assert(not A.validate({CH1=false},definitions))
    assert(A.validate({CH1=true},definitions))
end)
test('badge adapter retries failures and reports unmapped IDs',function()
    local calls=0;local service={UserHasBadgeAsync=function()return false end,AwardBadgeAsync=function()calls+=1;return calls>1 end}
    local b=load('AchievementBadges').new({CH1=123},service)
    assert(#b:sync(1,{CH1=true,STRB1=true}).failed==1)
    local result=b:sync(1,{CH1=true,STRB1=true});assert(#result.awarded==1 and #result.unmapped==1)
    b:sync(1,{CH1=true});assert(calls==2)
end)
local time = 1
local function input()
	return Input.new({connect = false, clock = function() return time end,
		bindings = {grab = {"ButtonL2", "ButtonR2", "Z"}, jump = {"Space", "ButtonA"}, primary = {"MouseButton1"}}})
end
local function event(key, z, kind) return {KeyCode = {Name = key}, Position = {X = 0, Y = 0, Z = z or 0}, UserInputType = {Name = kind or "Gamepad1"}} end
test("controller style and focus follow input and mapping", function()
	globals.Enum.KeyCode = {ButtonA="ButtonA"}
	local mapped = "ButtonCross"
	local i = Input.new({connect = false, uis = {GetStringForKeyCode = function() return mapped end}})
	assert(i:getGamepadStyle() == "ps" and not i.ControllerHasFocus)
	i:process("Began", event("ButtonA")); assert(i.Attached and i.ControllerHasFocus)
	i:process("Began", event("Q", 0, "Keyboard")); assert(not i.ControllerHasFocus)
	i:process("Changed", {KeyCode={Name="Thumbstick2"}, UserInputType={Name="Gamepad2"}, Position={X=.1,Y=.1,Z=0}}); assert(not i.ControllerHasFocus)
	i:process("Changed", {KeyCode={Name="Thumbstick2"}, UserInputType={Name="Gamepad2"}, Position={X=.5,Y=0,Z=0}}); assert(i.ControllerHasFocus)
	mapped="ButtonA"; i:refreshGamepadStyle(); assert(i:getGamepadStyle()=="xbox")
	mapped="ButtonB"; i:refreshGamepadStyle(); assert(i:getGamepadStyle()=="switch")
	i:setGamepadStyleOverride("ps"); assert(i:getGamepadStyle()=="ps"); i:setGamepadStyleOverride(nil); assert(i:getGamepadStyle()=="switch")
end)
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
test("shell lets hosted game receive controller pause and cancel", function()
	local shell = load("Shell")
	globals.Enum.KeyCode = {ButtonStart = "start", ButtonB = "b"}
	globals.Enum.UserInputState = {Begin = "begin", End = "end"}
	globals.Enum.ContextActionResult = {Sink = "sink", Pass = "pass"}
	local count = 0
	local host = setmetatable({open = false, pauseHandler = function() count += 1 end}, shell)
	assert(host:gamepadMenuAction("begin", "start") == "pass" and count == 0)
	assert(host:gamepadMenuAction("begin", "b") == "pass")
	host.open = true; host.setOpen = function(self, value) self.open = value end
	assert(host:gamepadMenuAction("begin", "b") == "sink" and not host.open)
	host.pauseHandler = nil; host.toggleMenu = function() count += 1 end
	assert(host:gamepadMenuAction("begin", "start") == "sink" and count == 1)
end)
test("touch chords and sliding retain independent fingers", function()
	local i = input(); local grab, jump = {}, {Position = {X = 5, Y = 5}}
	i.touchButtons = {{action = "jump", button = {AbsolutePosition = {X = 0, Y = 0}, AbsoluteSize = {X = 10, Y = 10}}},
		{action = "dash", button = {AbsolutePosition = {X = 10, Y = 0}, AbsoluteSize = {X = 10, Y = 10}}}}
	i:setTouchAction(grab, "grab"); i:setTouchAction(jump, "jump"); i:setTouchDirection(60, 0)
	assert(i:check("grab") and i:check("jump") and i:check("right"))
	jump.Position.X = 15; i:moveTouchAction(jump)
	assert(i:check("grab") and not i:check("jump") and i:check("dash") and i:check("right"))
	jump.Position.X = 30; i:moveTouchAction(jump); assert(not i:check("dash"))
	jump.Position.X = 5; i:moveTouchAction(jump); assert(i:check("jump"))
	i:setTouchAction(jump, nil); i:setTouchAction(grab, nil); assert(not i:check("jump") and not i:check("grab"))
end)
-- Deterministic event/GUI fixture: counts every native property assignment.
local function touchFixture(config, actions)
	local function signal()
		local callbacks = {}
		return {Connect = function(_, fn)
			local connection = {connected = true}
			function connection:Disconnect() self.connected = false end
			table.insert(callbacks, {fn, connection}); return connection
		end, Fire = function(_, ...)
			for _, item in callbacks do if item[2].connected then item[1](...) end end
		end}
	end
	local writes, created = 0, {}
	local previousInstance, previousFont = globals.Instance, globals.Enum.Font
	globals.Enum.Font = {GothamMedium = "GothamMedium"}
	globals.Instance = {new = function(class)
		local values = {Visible = true, AbsolutePosition = roblox.Vector2.new(10, 20),
			AbsoluteSize = roblox.Vector2.new(100, 100), InputBegan = signal(), Activated = signal(),
			Destroy = function(self) self.destroyed = true end}
		local object = setmetatable({}, {__index = values, __newindex = function(_, key, value)
			values[key] = value; writes += 1
		end})
		table.insert(created, object); return object
	end}
	local uis = {TouchEnabled = true, TouchMoved = signal(), TouchEnded = signal()}
	config = config or {}; config.connect = false; config.uis = uis
	local i = Input.new(config)
	local ok, message = pcall(function() i:mountTouch({}, "Platformer", actions or {}) end)
	globals.Instance, globals.Enum.Font = previousInstance, previousFont
	assert(ok, message)
	local function touch(x, y)
		return {UserInputType = globals.Enum.UserInputType.Touch, Position = {X = x, Y = y}}
	end
	return i, uis, touch, function() return writes, #created end
end

test("touch contexts diff writes, override labels and end hidden finger ownership", function()
	local i, uis, touch, counts = touchFixture({touchContext = "gameplay"}, {
		{action = "jump", label = "Jump", contexts = {"gameplay"}, labels = {gameplay = "Hop"}, textSize = 18},
		{action = "menu", contexts = {menu = true}}, {action = "always"},
		{action = "disabled", visible = false}})
	local jump, menu = i.touchButtons[1].button, i.touchButtons[2].button
	assert(i:getTouchContext() == "gameplay" and jump.Visible and jump.Text == "Hop" and jump.TextSize == 18)
	assert(not menu.Visible and i.touchButtons[3].button.Visible and not i.touchButtons[4].button.Visible)
	local held, other = touch(15, 25), touch(15, 25)
	jump.InputBegan:Fire(held); i:setTouchAction(other, "jump"); assert(i:check("jump"))
	i:setTouchContext("menu")
	assert(not jump.Visible and menu.Visible and jump.Text == "Jump")
	assert(not i:check("jump") and i.touch[held] == nil and i.touch[other] == nil)
	uis.TouchMoved:Fire(held); assert(not i:check("menu"), "Cancelled finger must not acquire overlapping menu")
	jump.InputBegan:Fire(held); assert(i.touch[held] == nil, "Hidden button must reject begins")
	local before, objects = counts()
	i:setTouchContext("menu"); i:applyTouchContext(); i:updateTouchVisibility()
	local after, retained = counts(); assert(before == after and objects == retained)
	menu.InputBegan:Fire(held); assert(i:check("menu")); uis.TouchEnded:Fire(held); assert(i.touch[held] == nil)
	i:setActionVisible("jump", true); assert(jump.Visible)
	i:setActionLabel("jump", "Fly"); assert(jump.Text == "Fly")
	i:setActionLabel("jump", nil); assert(jump.Text == "Jump")
	i:setActionVisible("jump", nil); assert(not jump.Visible)
	i:setTouchContext("gameplay"); assert(jump.Visible and jump.Text == "Hop")
	i:setActionVisible("jump", false); assert(not jump.Visible)
	i:setActionVisible("jump", nil); assert(jump.Visible)
	for _, bad in {false, "", 42} do assert(not pcall(i.setTouchContext, i, bad)) end
	assert(not pcall(i.setActionVisible, i, "jump", 1))
	assert(not pcall(i.setActionLabel, i, "jump", false))
end)

test("sliding skips hidden overlapping action buttons", function()
	local i, _, touch = touchFixture(nil, {{action = "hidden", visible = false}, {action = "shown"}})
	local finger = touch(15, 25)
	i:setTouchAction(finger, false); i:moveTouchAction(finger)
	assert(i:check("shown") and not i:check("hidden"))
	i:setActionVisible("shown", false)
	assert(i.touch[finger] == nil and not i:check("shown"))
end)

test("context axes project held drags, cues and thumb with diff writes", function()
	local i, _, _, counts = touchFixture({touchLayout = {moveAxes = {gameplay = "X", vertical = "Y", default = "XY"}}})
	i:setTouchDirection(60, -60); assert(i:check("right") and i:check("up"))
	i:setTouchContext("gameplay")
	assert(i:check("right") and not i:check("up") and not i:check("down") and not i:check("left"))
	assert(not i.moveArrows.up.Visible and not i.moveArrows.down.Visible and i.moveArrows.left.Visible and i.moveArrows.right.Visible)
	assert(i.thumb.Position == roblox.UDim2.new(.5, 38, .5, 0))
	local before = counts(); i:setTouchDirection(60, -60); assert(counts() == before)
	i:setTouchContext("vertical")
	assert(i:check("up") and not i:check("right") and not i:check("left"))
	assert(i.moveArrows.up.Visible and not i.moveArrows.right.Visible)
	assert(i.thumb.Position == roblox.UDim2.new(.5, 0, .5, -38))
	i:setTouchContext("other"); assert(i:check("right") and i:check("up") and i.moveArrows.right.Visible)
	i.touchLayout.moveAxes = "X"; i.touchLayout.moveDeadzone = 20; i.touchLayout.moveRadius = 30
	i:setTouchDirection(19, 90); assert(not i:check("right") and not i:check("down"))
	i:setTouchDirection(-20, 90); assert(i:check("left") and i.thumb.Position == roblox.UDim2.new(.5, -20, .5, 0))
end)

test("dynamic pad anchors, follows each axis and stops promptly on reversal", function()
	for _, axes in {"X", "Y", "XY"} do
		local i, uis, touch, counts = touchFixture({touchContext = "gameplay", touchLayout = {
			moveMode = "Dynamic", moveContexts = {"gameplay"}, moveAxes = axes, hideIdleMove = true}})
		assert(not i.moveZone.Visible and i.moveArea.Visible)
		local finger = touch(145, 275)
		i.moveArea.InputBegan:Fire(finger)
		assert(i.moveTouch == finger and i.moveOrigin == roblox.Vector2.new(145, 275))
		assert(i.moveZone.Position == roblox.UDim2.fromOffset(135, 255) and i.moveZone.Visible and i.moveZone.BackgroundTransparency == .72)
		local second = touch(20, 100); i.moveArea.InputBegan:Fire(second); assert(i.moveTouch == finger)
		local vertical = axes == "Y"
		finger.Position = if vertical then {X = 160, Y = 575} else {X = 445, Y = 275}
		uis.TouchMoved:Fire(finger)
		local offset = roblox.Vector2.new(finger.Position.X, finger.Position.Y) - i.moveOrigin
		assert(math.abs(offset.Magnitude - 38) < .0001)
		assert(i:check(if vertical then "down" else "right"))
		-- Reverse 38 - 14 + 2 pixels: inside the deadzone at the leashed origin.
		if vertical then finger.Position.Y -= 26 else finger.Position.X -= 26 end
		uis.TouchMoved:Fire(finger); assert(not i:check("right") and not i:check("down"))
		if vertical then finger.Position.Y -= 28 else finger.Position.X -= 28 end
		uis.TouchMoved:Fire(finger); assert(i:check(if vertical then "up" else "left"))
		local before = counts(); uis.TouchMoved:Fire(finger); assert(counts() == before)
		i:setTouchContext("menu")
		assert(not i.moveArea.Visible and not i.moveZone.Visible and not i.moveTouch and not i.moveOrigin)
		assert(not i:check("left") and not i:check("up") and i.moveZone.Position == i.moveHomePosition)
		uis.TouchMoved:Fire(finger); i.moveArea.InputBegan:Fire(second); assert(not i.moveTouch)
		i:setTouchContext("gameplay"); assert(i.moveArea.Visible and not i.moveZone.Visible)
		i.moveArea.InputBegan:Fire(second); uis.TouchEnded:Fire(second)
		assert(not i.moveTouch and not i.moveOrigin and not i.moveZone.Visible and i.moveZone.BackgroundTransparency == .86)
		i.moveArea.InputBegan:Fire(second); i:reset(); assert(not i.moveTouch and not i.moveOrigin and not i.moveZone.Visible)
		i.moveArea.InputBegan:Fire(second); i:setTouchMode("Off")
		assert(not i.overlay.Visible and not i.moveTouch and not i.moveOrigin)
	end
end)

test("dynamic radial follow and disabled follow preserve configured geometry", function()
	for _, follow in {true, false} do
		local i, uis, touch = touchFixture({touchLayout = {moveMode = "Dynamic", dynamicFollow = follow,
			moveRadius = 50, moveDeadzone = 10, movePosition = roblox.UDim2.fromOffset(80, 90),
			moveSize = roblox.UDim2.fromOffset(120, 120), moveAreaPosition = roblox.UDim2.fromOffset(5, 6),
			moveAreaSize = roblox.UDim2.fromOffset(200, 300)}})
		assert(i.moveZone.Visible and i.moveZone.Size == roblox.UDim2.fromOffset(120, 120))
		assert(i.moveArea.Position == roblox.UDim2.fromOffset(5, 6) and i.moveArea.Size == roblox.UDim2.fromOffset(200, 300))
		local finger = touch(100, 200); i.moveArea.InputBegan:Fire(finger)
		finger.Position = {X = 400, Y = 600}; uis.TouchMoved:Fire(finger)
		assert(i.moveOrigin == (if follow then roblox.Vector2.new(370, 560) else roblox.Vector2.new(100, 200)))
		assert(i:check("right") and i:check("down"))
		assert(i.thumb.Position == roblox.UDim2.new(.5, 30, .5, 40))
		uis.TouchEnded:Fire(finger); assert(i.moveZone.Visible and i.moveZone.Position == roblox.UDim2.fromOffset(80, 90))
	end
end)

test("fixed movement keeps existing center geometry and eight-way defaults", function()
	local i, uis, touch = touchFixture()
	assert(i.moveZone.Position == roblox.UDim2.new(0, 18, 1, -158) and not i.moveArea)
	local finger = touch(100, 110); i.moveZone.InputBegan:Fire(finger)
	assert(i:check("right") and i:check("down"))
	finger.Position = {X = 60, Y = 20}; uis.TouchMoved:Fire(finger)
	assert(i:check("up") and not i:check("right"))
	uis.TouchEnded:Fire(finger); assert(not i:check("up") and not i.moveTouch)
	i.moveContexts = {menu = true}; i:applyTouchContext(); assert(not i.moveZone.Visible)
	i.moveZone.InputBegan:Fire(finger); assert(not i.moveTouch)
	i:setTouchContext("menu"); assert(i.moveZone.Visible)
end)

test("Platformer pointer contexts map virtual taps, drags, outside prompts and cancellation", function()
	local i = Input.new({connect = false, layout = "Platformer", touchContext = "menu",
		virtualSize = roblox.Vector2.new(480, 360), canvasScale = {Scale = 3},
		canvas = {AbsolutePosition = roblox.Vector2.new(100, 50), AbsoluteSize = roblox.Vector2.new(960, 540)},
		touchLayout = {pointerContexts = {"menu", "prompt_jump"}, allowOutsidePointer = {prompt_jump = true}}})
	local function finger(x, y) return {UserInputType = {Name = "Touch"}, Position = {X = x, Y = y}} end
	local tap = finger(580, 320)
	i:process("Began", tap); assert(i.pointer.down and i:check("primary") and i.pointer.inside)
	assert(i.pointer.virtualX == 240 and i.pointer.virtualY == 180 and i.pointer.x == .5 and i.pointer.y == .5)
	i:process("Ended", tap, true); local drop = i:consumeDrop()
	assert(drop.x == 240 and drop.y == 180 and drop.inside and not drop.wasDrag)
	i:process("Began", tap); tap.Position = {X = 628, Y = 350}; i:process("Changed", tap, true)
	assert(i.pointer.dragging and i.pointer.deltaX == 24 and math.abs(i.pointer.deltaY - 20) < .0001)
	i:process("Ended", tap); drop = i:consumeDrop(); assert(drop.wasDrag and drop.x == 264 and drop.y == 200)
	local outside = finger(52, 23)
	i:process("Began", outside); assert(not i.pointerTouch and not i.pointer.down)
	i:setTouchContext("prompt_jump"); i:process("Began", outside)
	assert(i.pointerTouch == outside and i.pointer.down and not i.pointer.inside)
	assert(i.pointer.x == 0 and i.pointer.y == 0 and i.pointer.virtualX == -24 and i.pointer.virtualY == -18)
	i:process("Ended", outside); drop = i:consumeDrop(); assert(not drop.inside and drop.x == -24 and drop.y == -18)
	i:process("Began", tap); i:setTouchContext("gameplay")
	assert(not i.pointerTouch and not i.pointerOwner and not i.pointer.down and i.pointer.cancelled and not i:check("primary"))
	i:process("Ended", tap); assert(not i:consumeDrop()); i:process("Began", tap); assert(not i.pointerTouch)
	i.touchLayout.allowOutsidePointer = {default = true, menu = false}
	i:setTouchContext("menu"); assert(not i:allowsOutsidePointer())
	i:setTouchContext("prompt_jump"); assert(i:allowsOutsidePointer())
	i.touchLayout.allowOutsidePointer = true; assert(i:allowsOutsidePointer())
	i:updatePointer(outside.Position); i:beginPointer("MouseButton1"); assert(not i.pointer.down)
	i.touchLayout.pointerContexts = {gameplay = true}; i:applyTouchContext(); assert(not i:isTouchPointerEnabled())
	i:setTouchContext("gameplay"); assert(i:isTouchPointerEnabled())
	i.touchLayout.allowOutsidePointer = false; assert(not i:allowsOutsidePointer())
end)

test("touch-only visibility ignores software keyboard and emulated mouse", function()
	for _, device in {{enabled = false}, {enabled = true}, {}} do
		local i, uis = touchFixture()
		uis.KeyboardEnabled = device.enabled; uis.MouseEnabled = device.enabled
		for _, kind in {"Keyboard", "MouseMovement", "MouseButton1", "Gamepad1", "Touch"} do
			i.lastType = kind; i:updateTouchVisibility()
			local expected = kind == "Touch" or (device.enabled == false and kind ~= "Gamepad1")
			assert(i.overlay.Visible == expected, "Unexpected visibility for " .. kind .. " / " .. tostring(device.enabled))
		end
	end
end)

test("first touch wakes canvas and controls before last-input-type notification", function()
	for _, device in {{enabled = false, lastType = "Gamepad1"}, {enabled = true, lastType = "Keyboard"}} do
		for _, target in {"canvas", "fixed", "moveArea", "dpad", "jump", "pause", "back"} do
			local mode = if target == "moveArea" then "Dynamic" elseif target == "dpad" then "Dpad" else "Fixed"
			local i, uis, touch = touchFixture({touchContext = "menu",
				canvas = {AbsolutePosition = roblox.Vector2.new(10, 20), AbsoluteSize = roblox.Vector2.new(100, 100)},
				touchLayout = {moveMode = mode, pointerContexts = {"menu"}}},
				{{action = "jump", label = "Jump"}, {action = "pause", label = "II"}, {action = "back", label = "Back"}})
			uis.KeyboardEnabled = device.enabled; uis.MouseEnabled = device.enabled
			local function hide()
				i.lastType = device.lastType; i:updateTouchVisibility(); assert(not i.overlay.Visible)
			end
			local function begin(finger)
				if target == "canvas" then i:process("Began", finger)
				elseif target == "fixed" then i.moveZone.InputBegan:Fire(finger)
				elseif target == "moveArea" then i.moveArea.InputBegan:Fire(finger)
				elseif target == "dpad" then i.dpadButtons.up.InputBegan:Fire(finger)
				else
					for _, entry in i.touchButtons do
						if entry.action == target then entry.button.InputBegan:Fire(finger) end
					end
				end
			end
			hide()
			local finger = touch(60, 70)
			if target == "canvas" then finger.UserInputType = {Name = "Touch"} end
			-- Invoke each path directly: no LastInputTypeChanged or service begin runs first.
			begin(finger)
			assert(i.lastType == "Touch" and i.overlay.Visible, "First touch did not wake " .. target)
			if target == "canvas" then
				assert(i.pointerTouch == finger and i.pointer.down and i:check("primary"))
				i:process("Ended", finger); assert(i:consumeDrop().inside)
			elseif target == "fixed" or target == "moveArea" then assert(i.moveTouch == finger)
			elseif target == "dpad" then assert(i.dpadTouches[finger] == "up" and i:check("up"))
			else assert(i.touch[finger] == target and i:check(target)) end
			-- Disabled input and explicit Off must never wake the overlay.
			i:setEnabled(false); hide(); begin(finger)
			assert(i.lastType == device.lastType and not i.overlay.Visible)
			i:setEnabled(true); i:setTouchMode("Off"); hide(); begin(finger)
			assert(i.lastType == device.lastType and not i.overlay.Visible)
		end
	end
end)

test("Cardinal movement chooses one dominant axis and horizontal ties", function()
	local unmounted = Input.new({connect = false, touchLayout = {moveAxes = {gameplay = "X"}}})
	unmounted:setTouchDirection(60, -60); unmounted:setTouchContext("gameplay")
	assert(unmounted:check("right") and not unmounted:check("up"))
	local i, _, _, counts = touchFixture({touchLayout = {moveAxes = "Cardinal"}})
	for _, case in {{60, 40, "right", 38, 0}, {-60, 40, "left", -38, 0},
		{40, -60, "up", 0, -38}, {40, 60, "down", 0, 38}, {30, 30, "right", 30, 0}, {-30, -30, "left", -30, 0}} do
		i:setTouchDirection(case[1], case[2])
		for _, direction in {"up", "down", "left", "right"} do assert(i:check(direction) == (direction == case[3])) end
		assert(i.thumb.Position == roblox.UDim2.new(.5, case[4], .5, case[5]))
	end
	i:setTouchDirection(9, 9); assert(not i:check("left") and not i:check("right") and not i:check("up") and not i:check("down"))
	assert(i.thumb.Position == roblox.UDim2.fromScale(.5, .5))
	local before = counts(); i:setTouchDirection(9, 9); assert(counts() == before)
end)

test("context movement modes retain controls and release hidden Dpad fingers", function()
	local i, uis, touch, counts = touchFixture({touchContext = "gameplay", touchLayout = {
		moveModes = {gameplay = "Dynamic", menu = "Dpad", horizontal = "Dpad", default = "Fixed"},
		moveAxes = {horizontal = "X"}, pointerContexts = {menu = true}}})
	assert(i:resolveMoveMode() == "Dynamic" and i.moveZone.Visible and i.moveArea.Visible and not i.dpad.Visible)
	local held = touch(125, 200); i.moveArea.InputBegan:Fire(held)
	held.Position.X += 80; uis.TouchMoved:Fire(held); assert(i:check("right"))
	i:setTouchContext("menu")
	assert(i.dpad.Visible and not i.moveZone.Visible and not i.moveArea.Visible and not i.moveTouch and not i.moveOrigin and not i:check("right"))
	-- Give each retained button independent geometry for deterministic hit tests.
	for index, direction in {"up", "down", "left", "right"} do
		i.dpadButtons[direction].AbsolutePosition = roblox.Vector2.new(index * 50, 0)
		i.dpadButtons[direction].AbsoluteSize = roblox.Vector2.new(44, 44)
		assert(i.dpadButtons[direction].Size == roblox.UDim2.fromOffset(44, 44))
	end
	local up, right = touch(55, 5), touch(205, 5)
	i.dpadButtons.up.InputBegan:Fire(up); i.dpadButtons.right.InputBegan:Fire(right)
	assert(i:check("up") and i:check("right"))
	-- A control-owned touch cannot also become a direct canvas pointer.
	up.UserInputType = {Name = "Touch"}; i:process("Began", up); assert(not i.pointerTouch)
	up.Position.X = 105; uis.TouchMoved:Fire(up); assert(i:check("down") and not i:check("up") and i:check("right"))
	up.Position.X = 400; uis.TouchMoved:Fire(up); assert(not i:check("down") and i.dpadTouches[up] == false)
	up.Position.X = 55; uis.TouchMoved:Fire(up); assert(i:check("up"))
	i:setTouchContext("horizontal"); assert(not i.dpadButtons.up.Visible and not i.dpadButtons.down.Visible)
	assert(i.dpadTouches[up] == nil and not i:check("up") and i:check("right"))
	uis.TouchMoved:Fire(up); assert(not i:check("up"))
	uis.TouchEnded:Fire(right); assert(not i:check("right") and i.dpadTouches[right] == nil)
	i:setTouchContext("menu"); i.dpadButtons.up.InputBegan:Fire(up); i:setTouchContext("gameplay")
	assert(not i.dpad.Visible and i.moveArea.Visible and i.dpadTouches[up] == nil and not i:check("up"))
	local before, created = counts(); i:setTouchContext("gameplay"); i:applyTouchContext()
	local after, retained = counts(); assert(before == after and created == retained)
	i:setTouchContext("other"); assert(i:resolveMoveMode() == "Fixed" and i.moveZone.Visible and not i.moveArea.Visible)
	assert(i.moveZone.Position == roblox.UDim2.new(0, 18, 1, -158) and i.moveZone.AnchorPoint == roblox.Vector2.zero)
	i:setTouchContext("menu"); i.dpadButtons.up.InputBegan:Fire(up); i:reset()
	assert(not i:check("up") and next(i.dpadTouches) == nil)
	i.dpadButtons.up.InputBegan:Fire(up); i:setTouchMode("Off")
	assert(not i:check("up") and next(i.dpadTouches) == nil)
end)

test("SmokedGlass touch controls illuminate held buttons, D-pad cross arms, and pause bars", function()
	local i, uis, touch, counts = touchFixture({touchContext = "gameplay", touchLayout = {
		moveModes = {gameplay = "Fixed", menu = "Dpad"}, moveContexts = {"gameplay", "menu"},
		moveAxes = {gameplay = "X", menu = "XY"}, moveArrows = {gameplay = "X", menu = "XY"}, freeThumb = true}}, {
		{action = "jump", label = "Jump", size = roblox.UDim2.fromOffset(92, 92)},
		{action = "pause", label = "II", labels = {ending = "Skip"}, size = roblox.UDim2.fromOffset(44, 44)}})
	assert(i.touchTheme == "SmokedGlass" and i.dpadArms and i.touchButtons[1].button.AutoButtonColor == false)
	assert(i.touchButtons[1].button.TextSize == 16 and i.touchButtons[2].pauseIcon.Visible and i.touchButtons[2].button.TextTransparency == 1)
	i:setTouchDirection(30, 50)
	assert(i.thumb.Position.X.Offset > 0 and i.thumb.Position.Y.Offset > 0 and i:check("right") and not i:check("down"))
	local jf = touch(15, 25); i.touchButtons[1].button.InputBegan:Fire(jf)
	assert(i.touchButtons[1].button.BackgroundTransparency == .12); uis.TouchEnded:Fire(jf)
	assert(i.touchButtons[1].button.BackgroundTransparency == .28)
	i:setTouchContext("menu")
	local df = touch(15, 25); i.dpadButtons.up.InputBegan:Fire(df)
	assert(i.dpadArms.up.cap.BackgroundTransparency == .10); uis.TouchEnded:Fire(df)
	assert(i.dpadArms.up.cap.BackgroundTransparency == .28)
	i:setTouchContext("ending")
	assert(not i.touchButtons[2].pauseIcon.Visible and i.touchButtons[2].button.TextTransparency == 0)
	local before = counts(); i:applyTouchContext(); assert(counts() == before)
end)

test("Dpad base mode, context hide and pointer event order cancel ownership", function()
	local i, uis, touch = touchFixture({touchContext = "menu", virtualSize = roblox.Vector2.new(480, 360),
		canvas = {AbsolutePosition = roblox.Vector2.zero, AbsoluteSize = roblox.Vector2.new(480, 360)},
		touchLayout = {moveMode = "Dpad", moveContexts = {"menu"}, pointerContexts = {"menu"}}}, {{action = "jump"}})
	assert(i.dpad.Visible and not i.moveZone.Visible and not i.moveArea)
	local held = touch(50, 100); held.UserInputType = {Name = "Touch"}
	i:process("Began", held); assert(i.pointerTouch == held)
	held.UserInputType = globals.Enum.UserInputType.Touch; i.dpadButtons.left.InputBegan:Fire(held)
	assert(not i.pointerTouch and not i.pointer.down and not i:consumeDrop() and i:check("left"))
	i:setTouchContext("gameplay"); assert(not i.dpad.Visible and next(i.dpadTouches) == nil and not i:check("left"))
	i:setTouchContext("menu"); uis.TouchMoved:Fire(held); assert(not i:check("left"))
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
local function pointerInput(extra)
	local config = {connect = false, layout = "Pointer",
		canvas = {AbsolutePosition = roblox.Vector2.new(100, 50), AbsoluteSize = roblox.Vector2.new(640, 360)},
		canvasScale = {Scale = 2}, bindings = {primary = {"MouseButton1"}}}
	for key, value in extra or {} do config[key] = value end
	return Input.new(config)
end
local function point(kind, x, y)
	local e = event("Unknown", 0, kind); e.Position = {X = x, Y = y}; return e
end
for _, kind in {"MouseButton1", "Touch"} do
	test(kind .. " virtual drag threshold, sticky drag and one-shot drop", function()
		local i = pointerInput(); local pointer = i.pointer
		local press = point(kind, 120, 90); i:process("Began", press)
		assert(pointer.down and not pointer.dragging and i:check("primary"))
		assert(pointer.startX == 10 and pointer.startY == 20 and pointer.deltaX == 0)
		local function move(x, y)
			if kind == "Touch" then press.Position = {X = x, Y = y}; i:process("Changed", press, true)
			else i:process("Changed", point("MouseMovement", x, y), true) end
		end
		move(128, 90); assert(not pointer.dragging and pointer.deltaX == 4)
		move(126, 96); assert(pointer.dragging and pointer.deltaX == 3 and pointer.deltaY == 3)
		move(120, 90); assert(pointer.dragging)
		press.Position = {X = 156, Y = 130}; i:process("Ended", press, true)
		assert(i.pointer == pointer and not pointer.down and not pointer.dragging and not i:check("primary"))
		local drop = i:consumeDrop()
		assert(drop.startX == 10 and drop.startY == 20 and drop.x == 28 and drop.y == 40 and drop.wasDrag and drop.inside)
		assert(pointer.deltaX == 18 and pointer.deltaY == 20 and not i:consumeDrop())
	end)
	test(kind .. " click, release-only motion, outside drop and custom deadzone", function()
		local i = pointerInput({dragDeadzone = 10})
		local press = point(kind, 120, 90); i:process("Began", press); i:process("Ended", press)
		assert(not i:consumeDrop().wasDrag)
		i:process("Began", press); press.Position = {X = 140, Y = 90}; i:process("Ended", press)
		assert(not i:consumeDrop().wasDrag)
		i:process("Began", press); press.Position = {X = 800, Y = 430}; i:process("Ended", press)
		local drop = i:consumeDrop(); assert(drop.wasDrag and not drop.inside and drop.x == 350 and drop.y == 190)
		assert(i.pointer.x == 1 and i.pointer.y == 1)
	end)
	test(kind .. " modal cancellation invalidates drops and ignores late release", function()
		local i = pointerInput(); local press = point(kind, 120, 90)
		i:process("Began", press); i:process("Ended", press) -- Pending drop must also be invalidated.
		i:process("Began", press); i:updatePointer({X = 200, Y = 90}); assert(i.pointer.dragging)
		i:setEnabled(false)
		assert(i.pointer.cancelled and not i.pointer.down and not i.pointer.dragging and not i:check("primary"))
		i:process("Ended", press, true); assert(not i:consumeDrop())
		i:setEnabled(true); assert(i.pointer.cancelled)
		i:process("Began", press); assert(i.pointer.down and not i.pointer.cancelled)
		i:process("Ended", press); assert(i:consumeDrop())
	end)
end
test("pointer rejects processed, disabled and outside starts", function()
	local i = pointerInput()
	for _, kind in {"MouseButton1", "Touch"} do
		local press = point(kind, 120, 90)
		i:process("Began", press, true); i:process("Ended", press); assert(not i:consumeDrop())
		i:setEnabled(false); i:process("Began", press); assert(not i.pointer.down); i:setEnabled(true)
		local outside = point(kind, 90, 90); i:process("Began", outside); i:process("Ended", outside)
		assert(not i:consumeDrop())
	end
end)
test("drop consumption retains only the latest unconsumed release", function()
	local i = pointerInput()
	for _, x in {120, 140} do
		local press = point("MouseButton1", x, 90); i:process("Began", press); i:process("Ended", press)
	end
	assert(i:consumeDrop().x == 20 and not i:consumeDrop())
end)
test("touch ownership, secondary toggle and touch visibility cancellation", function()
	local i = pointerInput(); local first = point("Touch", 120, 90); local other = point("Touch", 500, 300)
	i:process("Began", first); i:process("Began", other); i:process("Changed", other); i:process("Ended", other)
	i:process("Changed", point("MouseMovement", 500, 300))
	assert(i.pointer.down and i.pointer.virtualX == 10)
	i:setTouchMode("Off"); assert(i.pointer.cancelled and not i.pointer.down and not i:check("primary"))
	i:process("Ended", first); assert(not i:consumeDrop())
	i:process("Began", first); assert(not i.pointer.down)
	i:setTouchMode("On"); i.pointerSecondary = true
	i:process("Began", first); assert(i:check("secondary") and not i.pointer.down)
	i:process("Ended", first, true); assert(not i:check("secondary") and not i:consumeDrop())
	i.pointerSecondary = false; i.overlay = {}; i.uis = {TouchEnabled = true}; i.lastType = "Touch"
	i:setTouchMode("Auto"); i:process("Began", first); assert(i.pointer.down)
	i.lastType = "MouseMovement"; i:updateTouchVisibility()
	assert(i.pointer.cancelled and not i.pointer.down and not i:check("primary"))
end)
local function signal()
	local s = {listeners = {}}
	function s:Connect(callback)
		local c = {connected = true}; function c:Disconnect() self.connected = false end
		table.insert(self.listeners, {callback, c}); return c
	end
	function s:fire(...)
		for _, listener in self.listeners do if listener[2].connected then listener[1](...) end end
	end
	return s
end
test("gamepad connection events refresh attachment and style", function()
	local mapped, pads = "ButtonA", {}
	local uis = {GetLastInputType=function() return {Name="Keyboard"} end,
		GetStringForKeyCode=function() return mapped end, GetConnectedGamepads=function() return pads end}
	for _, name in {"InputBegan", "InputChanged", "InputEnded", "WindowFocusReleased", "GamepadConnected", "GamepadDisconnected", "LastInputTypeChanged"} do uis[name] = signal() end
	local i=Input.new({uis=uis}); assert(not i.Attached and i:getGamepadStyle()=="xbox")
	mapped="ButtonCross"; pads={{Name="Gamepad1"}}; uis.GamepadConnected:fire(pads[1]); assert(i.Attached and i:getGamepadStyle()=="ps")
	uis.InputBegan:fire(event("ButtonA"),false); assert(i.ControllerHasFocus)
	mapped="ButtonB"; uis.LastInputTypeChanged:fire({Name="Gamepad2"}); assert(i:getGamepadStyle()=="switch")
	pads={}; uis.GamepadDisconnected:fire({Name="Gamepad1"}); assert(not i.Attached and not i.ControllerHasFocus)
	i:destroy()
end)
test("gamepad vibration caches writes and stops on disconnect and destroy", function()
    globals.Enum.UserInputType = {Gamepad1={Name="Gamepad1"}, Gamepad2={Name="Gamepad2"}, Gamepad3={Name="Gamepad3"}, Gamepad4={Name="Gamepad4"}}
    globals.Enum.VibrationMotor = {Large="large", Small="small"}
    local calls, queries = {}, 0
    local haptic = {IsVibrationSupported=function(_, pad) queries+=1; return pad.Name ~= "Gamepad2" end,
        SetMotor=function(_,pad,motor,value) table.insert(calls,{pad.Name,motor,value}) end}
    local uis = {GetLastInputType=function() return {Name="Keyboard"} end,
        GetStringForKeyCode=function() return "ButtonA" end, GetConnectedGamepads=function() return {} end}
    for _,name in {"InputBegan","InputChanged","InputEnded","WindowFocusReleased","GamepadConnected","GamepadDisconnected","LastInputTypeChanged"} do uis[name]=signal() end
    local i=Input.new({uis=uis,hapticService=haptic})
    assert(i:setVibration(0,.5,1)); assert(#calls==2 and queries==1)
    assert(i:setVibration(0,.5,1)); assert(#calls==2 and queries==1)
    assert(not i:setVibration(1,1,1)); assert(not i:setVibration(1,1,1)); assert(queries==2 and #calls==2)
    uis.GamepadDisconnected:fire(globals.Enum.UserInputType.Gamepad1)
    assert(#calls==4 and calls[3][3]==0 and calls[4][3]==0)
    assert(i:setVibration(0,1,0)); assert(queries==3 and #calls==5)
    i:destroy(); assert(#calls==6 and calls[6][3]==0)
end)
test("connected mouse and touch events cancel on window focus loss", function()
	for _, kind in {"MouseButton1", "Touch"} do
		local uis = {GetLastInputType = function() return {Name = kind} end}
		for _, name in {"InputBegan", "InputChanged", "InputEnded", "WindowFocusReleased", "GamepadDisconnected", "LastInputTypeChanged"} do uis[name] = signal() end
		local i = pointerInput({connect = true, uis = uis}); local press = point(kind, 120, 90)
		uis.InputBegan:fire(press, false); assert(i.pointer.down)
		if kind == "Touch" then press.Position = {X = 160, Y = 90}; uis.InputChanged:fire(press, true)
		else uis.InputChanged:fire(point("MouseMovement", 160, 90), true) end
		assert(i.pointer.dragging)
		uis.WindowFocusReleased:fire()
		assert(i.pointer.cancelled and not i.pointer.down and not i:check("primary"))
		uis.InputEnded:fire(press, true); assert(not i:consumeDrop())
		i:destroy(); uis.InputBegan:fire(press, false); assert(not i.pointer.down)
	end
end)
-- Run the complete input section independently of rendering regressions.
if require("@lune/process").args[1] == "--input" then
	print("PortKit input checks:", total); return
end
local Stepper = load("Stepper")
local function close(a, b) assert(math.abs(a - b) < 1e-7, tostring(a) .. " ~= " .. tostring(b)) end
test("fixed clock returns exact 1x and 3x ticks and fractional interpolation", function()
	for _, speed in {1, 3} do
		local s = Stepper.new(); s:setSpeed(speed); local ticks = 0
		for _ = 1, 120 do local steps, alpha = s:advance(1 / 120); ticks += steps; assert(alpha >= 0 and alpha < 1) end
		assert(ticks == 60 * speed); close(s.stepDt, 1 / 60)
	end
	local s = Stepper.new(); local steps, alpha = s:advance(1 / 240); assert(steps == 0); close(alpha, .25)
	s:setSpeed(3); steps, alpha = s:advance(1 / 240); assert(steps == 1); close(alpha, 0)
end)
test("fixed clock is independent of frame partition below overload", function()
	for _, speed in {1, 3} do
		local a = Stepper.new({speed = speed}); local b = Stepper.new({speed = speed}); local ticksA, ticksB = 0, 0
		for _ = 1, 60 do ticksA += a:advance(1 / 60) end
		for _ = 1, 20 do for _, dt in {1 / 120, 1 / 40, 1 / 60} do ticksB += b:advance(dt) end end
		assert(ticksA == ticksB and ticksA == 60 * speed); close(a.accumulator, b.accumulator)
	end
end)
test("pause retains remainder without accumulating elapsed wall time", function()
	local s = Stepper.new(); s:advance(s.stepDt / 2); s:setSpeed(0)
	for _, dt in {0, 1, 1000} do local steps, alpha = s:advance(dt); assert(steps == 0); close(alpha, .5) end
	s:setSpeed(1); local steps, alpha = s:advance(s.stepDt / 2); assert(steps == 1); close(alpha, 0)
end)
test("lag clamps wall delta, scales work limit and discards backlog", function()
	for _, speed in {1, 3} do
		local s = Stepper.new({speed = speed}); s:advance(s.stepDt / (2 * speed))
		local steps, alpha = s:advance(1000); assert(steps == 8 * speed); close(alpha, .5)
		steps, alpha = s:advance(0); assert(steps == 0); close(alpha, .5)
		steps, alpha = s:advance(s.stepDt / (2 * speed)); assert(steps == 1); close(alpha, 0)
		local capped = Stepper.new({maxStepsPerFrame = 100, speed = speed})
		assert(capped:advance(1000) == 15 * speed) -- .25s, before speed scaling.
	end
	assert(Stepper.new({rate = 30, maxSteps = 6, speed = 3}):advance(1) == 18)
	assert(Stepper.new({rate = 100, maxDelta = .1, maxStepsPerFrame = 100}):advance(1) == 10)
	local slow = Stepper.new({speed = .5}); local steps, alpha = slow:advance(1 / 60); assert(steps == 0); close(alpha, .5)
	assert(slow:advance(1) == 4)
end)
test("fixed clock rejects invalid config, speed and frame deltas", function()
	for _, value in {-1, math.huge, -math.huge, 0 / 0, "bad"} do
		assert(not pcall(function() Stepper.new({rate = value}) end))
		assert(not pcall(function() Stepper.new({maxDelta = value}) end))
		assert(not pcall(function() Stepper.new({maxSteps = value}) end))
		assert(not pcall(function() Stepper.new():setSpeed(value) end))
		assert(not pcall(function() Stepper.new():advance(value) end))
	end
	for _, config in {{rate = 0}, {maxDelta = 0}, {maxSteps = 0}, {maxSteps = 1.5}} do
		assert(not pcall(function() Stepper.new(config) end))
	end
end)
test("Kit exposes Stepper and createApp wires optional clock and virtual canvas scale", function()
	local shell = {Canvas = {}, Scale = {Scale = 2}, HudGui = {}, onModal = function(self, callback) self.modal = callback end, destroy = function() end}
	local modules = {Stepper = Stepper, Input = Input, Shell = {new = function() return shell end}, Benchmark = {new = function() return {} end}}
	local fn = assert(loadstring(fs.readFile("runtime/init.luau")))
	setfenv(fn, setmetatable({script = setmetatable({}, {__index = function(_, name) return name end}),
		require = function(name) return modules[name] or {} end}, {__index = getfenv()}))
	local Kit = fn(); assert(Kit.Stepper == Stepper)
	local app = Kit.createApp({input = {connect = false}, stepper = {rate = 30, maxSteps = 6}})
	assert(app.input.canvasScale == shell.Scale and app.input.canvas == shell.Canvas)
	close(app.stepper.stepDt, 1 / 30); assert(app.stepper.maxStepsPerFrame == 6)
	shell.modal(true); assert(not app.input.enabled); shell.modal(false); assert(app.input.enabled)
	app:destroy(); assert(Kit.createApp({input = {connect = false}}).stepper == nil)
end)
local Atlas = load("AtlasPool")
local function image() return {WritePixelsBuffer = function() end, Destroy = function(self) self.destroyed = true end} end
test('editable staging is denied by default; shared opt-in counts successful creations',function()
    local Policy=load('EditableImagePolicy');local Static=load('StaticImagePool')
    local calls=0
    local service={CreateEditableImage=function()calls+=1;return image()end,
        CreateDataModelContentAsync=function()return 'ok',{} end}
    local forbidden=Static.new({service=service,success='ok'})
    local asset={uri='rbxassetid://123'};assert(forbidden:import('published',asset,1,1).content==asset)
    local ok,err=pcall(forbidden.request,forbidden,'raw',1,1,buffer.create(4))
    assert(not ok and tostring(err):find('EditableImage is disabled',1,true) and calls==0)
    assert(forbidden.pending==0 and forbidden.editableImagePolicy.editableImagesCreated==0)
    local atlas=Atlas.new({create=function()calls+=1;return image()end})
    ok,err=pcall(atlas.acquire,atlas,'raw',1,1,buffer.create(4))
    assert(not ok and tostring(err):find('EditableImage is disabled',1,true) and calls==0)
    local shared=Policy.new({allowEditableImages=true});local deferred
    local staged=Static.new({editableImagePolicy=shared,service=service,success='ok',
        scheduler={defer=function(fn)deferred=fn end,wait=function()end}})
    local retained=Atlas.new({editableImagePolicy=shared,create=function()calls+=1;return image()end})
    staged:request('one',1,1,buffer.create(4));deferred()
    retained:acquire('two',1,1,buffer.create(4))
    assert(calls==2 and shared.editableImagesCreated==2)
    staged:destroy();retained:destroy();assert(shared.editableImagesCreated==2)
end)
test('static pages stage once outside render and release editable memory',function()
    local Static=load('StaticImagePool');local deferred,created={},{}
    local service={CreateEditableImage=function()local im=image();created[#created+1]=im;return im end,
        CreateDataModelContentAsync=function(_,im)return 'ok',{immutable=im}end}
    local p=Static.new({service=service,success='ok',maxBytes=80,maxPages=10,allowEditableImages=true,
        scheduler={defer=function(fn)deferred[#deferred+1]=fn end,wait=function()end}})
    local decodes=0;local function pixels()decodes+=1;return buffer.create(16)end
    assert(p:request('a',2,2,pixels)==nil and #created==0 and p.pending==1)
    assert(p:request('a',2,2,pixels)==nil and p.pending==1 and #deferred==1)
    deferred[1]();assert(decodes==1 and created[1].destroyed and p.pending==0 and p.bytes==16)
    local entry=p:request('a',2,2,pixels);assert(entry==p.images.a and decodes==1)
    p:pin('a');p:pin('a');p:unpin('a');assert(p.pins.a==1)
    p:request('b',4,4,buffer.create(64));deferred[2]()
    p:request('c',4,4,buffer.create(64));deferred[3]()
    assert(p.images.a and p.images.c and not p.images.b and p.evictions==1 and p.bytes==80)
    p:destroy();assert(p.bytes==0 and not next(p.images))
end)
test('static conversion failures release staging and propagate to consumers',function()
    local Static=load('StaticImagePool');local run;local im=image()
    local p=Static.new({allowEditableImages=true,service={CreateEditableImage=function()return im end,
        CreateDataModelContentAsync=function()return 'failure' end},success='ok',
        scheduler={defer=function(fn)run=fn end,wait=function()end}})
    p:request('a',1,1,buffer.create(4));run()
    assert(im.destroyed and p.count==0 and p.pending==0)
    assert(#p.errors==1 and p.errors[1]:find('Static image conversion failed',1,true))
    local ok,err=pcall(function()p:request('a',1,1,buffer.create(4))end)
    assert(not ok and tostring(err):find('Static image conversion failed',1,true))
end)
test('published immutable pages bypass editable allocation and decoding',function()
    local Static=load('StaticImagePool')
    local p=Static.new({service={CreateEditableImage=function()error('Published page must not stage pixels')end},success='ok',maxPages=1})
    local content={uri='published'};local a=p:import('source:1',content,1024,512)
    assert(a.content==content and a.published and p.bytes==0 and p.uploads==0 and p.pending==0)
    assert(p:import('source:1',content,1024,512)==a and p.count==0)
    p:import('source:2',content,1,1)
    assert(p.images['source:1'] and p.count==0 and not p:evict())
end)
test('published imports do not evict staged pages',function()
    local Static=load('StaticImagePool');local deferred={}
    local p=Static.new({allowEditableImages=true,service={CreateEditableImage=function()return image()end,
        CreateDataModelContentAsync=function()return 'ok',{} end},success='ok',maxPages=64,
        scheduler={defer=function(f)deferred[#deferred+1]=f end,wait=function()end}})
    for i=1,64 do p:request('staged:'..i,1,1,buffer.create(4)) end
    deferred[1]()
    for i=1,500 do p:import('published:'..i,{uri='rbxassetid://'..i},1,1) end
    p:import('prepared',{},1,1,function()end);deferred[2]()
    assert(p.count==64 and p.evictions==0 and p.images.prepared)
    for i=1,64 do assert(p.images['staged:'..i]) end
end)
test('published image preparation runs off-frame and retains only ready content',function()
    local Static=load('StaticImagePool');local deferred,loads={},0
    local p=Static.new({service={CreateEditableImage=function()error('Published pixels must not stage')end},success='ok',
        scheduler={defer=function(f)deferred[#deferred+1]=f end,wait=function()end}})
    local content={uri='published'};local function prepare()loads+=1 end
    assert(not p:import('page',content,32,32,prepare)and loads==0 and p.pending==1)
    assert(not p:import('page',content,32,32,prepare)and #deferred==1)
    deferred[1]();assert(loads==1 and p.pending==0 and p.bytes==0 and p.uploads==0)
    assert(p:import('page',content,32,32,prepare).content==content and loads==1)
end)
test("LRU evicts only unpinned and enforces hard budget", function()
	local p = Atlas.new({maxPages = 2, create = image, allowEditableImages=true}); local pixels = buffer.create(16)
	local a = p:acquire("a", 2, 2, pixels); p:acquire("b", 2, 2, pixels); p:pin("a"); p:acquire("c", 2, 2, pixels)
	assert(p.images.a and not p.images.b and p.count == 2 and not a.destroyed)
	p:pin("c"); assert(not pcall(function() p:acquire("d", 2, 2, pixels) end))
	p:releasePins(); p:destroy(); assert(p.count == 0 and a.destroyed)
end)
test("byte budget evicts by actual image size and retains pins", function()
	local p = Atlas.new({maxPages = 20, maxBytes = 80, create = image, allowEditableImages=true})
	local a = p:acquire("a", 2, 2, buffer.create(16)); p:pin("a")
	local b = p:acquire("b", 4, 4, buffer.create(64)); assert(p.bytes == 80)
	p:acquire("c", 4, 4, buffer.create(64))
	assert(p.images.a and not p.images.b and b.destroyed and p.bytes == 80)
	p:pin("c"); assert(not pcall(function() p:acquire("d", 1, 1, buffer.create(4)) end))
	assert(not pcall(function() p:acquire("large", 5, 5, buffer.create(100)) end))
	p:remove("c"); assert(p.bytes == 16 and p.count == 1 and not a.destroyed)
	p:destroy(); assert(p.bytes == 0 and p.count == 0)
end)
test("image allocation retry, invalid sizes and failed uploads", function()
	local fail = false
	local p = Atlas.new({maxPages = 3, allowEditableImages=true, create = function() if fail then fail = false; return nil end; return image() end})
	p:acquire("a", 1, 1, buffer.create(4)); fail = true; p:acquire("b", 1, 1, buffer.create(4)); assert(not p.images.a and p.images.b)
	assert(not pcall(function() p:acquire("big", 1025, 1, buffer.create(4)) end))
	assert(not pcall(function() p:acquire("bad", 1, 1, buffer.create(2)) end)); assert(p.count == 1)
end)
test("unchanged scenes write zero properties; hidden slots and styles reset", function()
	local Scene = load("GpuScene"); local scene = Scene.new({}, function() return {Destroy = function() end} end,{imageRetentionFrames=0})
	local props = {ImageContent = "image", ZIndex = 1, Position = "p"}
	scene:begin(); local label=scene:image(props); scene:frame({Size = "size"}, 4, {color = roblox.Color3.new(1, 0, 0)}); scene:finish(); assert(scene.writes > 0)
	scene:begin(); scene:image(props); scene:frame({Size = "size"}, 4, {color = roblox.Color3.new(1, 0, 0)}); scene:finish(); assert(scene.writes == 0)
	scene:begin(); scene:frame({Size = "size"}); scene:finish(); assert(label.Visible == false and not scene.frames[1].stroke.object.Enabled)
	assert(label.ImageContent=='empty' and #scene.images==0,'Abandoned pages must release cached image content')
	scene:begin(); scene:frame({Size = "size"}); scene:finish(); assert(scene.writes == 0)
end)
test('image labels retain their atlas content when earlier draws disappear',function()
    local Scene=load('GpuScene');local scene=Scene.new({},function()return {Destroy=function()end}end,{imageRetentionFrames=0})
    scene:begin();local a=scene:image({ImageContent='a',Position='a1'});local b=scene:image({ImageContent='b',Position='b1'})
    local c=scene:image({ImageContent='c',Position='c1'});scene:finish()
    scene:begin();assert(scene:image({ImageContent='b',Position='b2'})==b);assert(scene:image({ImageContent='c',Position='c2'})==c);scene:finish()
    assert(a.ImageContent=='empty' and a.Visible==false)
    scene:begin();assert(scene:image({ImageContent='new',Position='new'})~=a);assert(scene:image({ImageContent='b',Position='b3'})==b)
    assert(scene:image({ImageContent='c',Position='c3'})==c);scene:finish()
    assert(#scene.images==3,'Abandoned content buckets must release their instances')
end)

test('crop bindings recycle within content buckets and retain bounded inactive pages',function()
    local Scene=load('GpuScene');local scene=Scene.new({},function()return {Destroy=function(self)self.destroyed=true end}end,
        {maxInactiveImages=2,imageRetentionFrames=4})
    local function props(x,w)return {ImageContent='atlas',ImageRectOffset=roblox.Vector2.new(x,1),ImageRectSize=roblox.Vector2.new(w,12)}end
    local body,hair=props(20,13),props(40,5)
    scene:begin();local a=scene:image(hair);local b=scene:image(body);scene:finish()
    scene:begin();assert(scene:image(body)==b);scene:finish();assert(not a.Visible and a.Parent==nil and a.ImageContent=='atlas')
    scene:begin();assert(scene:image(hair)==a);local flip=scene:image(props(33,-13));scene:finish()
    assert(flip~=b and not b.Visible and flip.ImageRectSize.X==-13,'A previous visible crop must cool down')
    scene:begin();local current=scene:image(body);scene:finish();assert(current.ImageRectSize.X==13)
    scene:begin();scene:image(body);scene:image(props(99,13));scene:finish()
    local created=scene.createdImages
    for i=1,180 do scene:begin();scene:image(body);scene:image(props(100+i,13));scene:finish();assert(#scene.images==3)end
    assert(scene.createdImages==created and scene.destroyedImages==0 and scene.recycledImages>=179)
    local other={ImageContent='other',ImageRectOffset=body.ImageRectOffset,ImageRectSize=body.ImageRectSize}
    scene:begin();assert(scene:image(other)~=current);scene:finish()
    scene:begin();scene:finish();assert(#scene.images>0,'One unused frame must retain cached animation pages')
    for i=1,5 do scene:begin();scene:finish()end
    assert(#scene.images==0 and next(scene.imageBuckets)==nil)
end)

test('scrolling crops use two visible high-water banks with a rendered cooldown',function()
    local Scene=load('GpuScene');local creates,destroys=0,0
    local s=Scene.new({},function()creates+=1;return {Destroy=function()destroys+=1 end}end)
    for frame=1,240 do
        s:begin()
        for i=1,12 do s:image({ImageContent='wrap',ImageRectOffset=roblox.Vector2.new(frame+i,frame-i),
            ImageRectSize=roblox.Vector2.new(1920-frame+i,1080+frame-i)})end
        s:finish()
        assert(#s.images==(if frame==1 then 12 else 24) and creates==#s.images and destroys==0)
        assert(next(s.imageBuckets.wrap.regions)~=nil)
        local regions=0;for _ in s.imageBuckets.wrap.regions do regions+=1 end
        assert(regions<=24,'Obsolete crop keys must remain bounded by the two banks')
        local shown=0;for _,e in s.images do if e.object.Visible then shown+=1;assert(e.object.Parent==s.parent)else assert(e.object.Parent==nil)end end
        assert(shown==12)
    end
    local created=creates
    s:begin();s:finish();for _,e in s.images do assert(not e.object.Visible and e.object.Parent==nil)end
    s:begin();s:image({ImageContent='wrap',ImageRectOffset=roblox.Vector2.new(10,20),ImageRectSize=roblox.Vector2.new(30,40)});s:finish()
    assert(creates==created and destroys==0 and s.imageCount==1)
    local attached=0;for _,e in s.images do if e.object.Parent==s.parent then attached+=1;assert(e.object.Visible)end end
    assert(attached==1,'Only active pooled labels belong in the rendered hierarchy')
end)

test('hidden pooled images publish complete geometry before visibility',function()
    local Scene=load('GpuScene');local expected;local publications=0
    local function factory()
        local values={}
        return setmetatable({Destroy=function()end},{__index=values,__newindex=function(_,key,value)
            if key=='Visible' and value then
                for _,field in {'Position','Size','ImageRectOffset','ImageRectSize'}do assert(values[field]==expected[field],'Visible preceded '..field)end
                publications+=1
            end
            values[key]=value
        end})
    end
    local s=Scene.new({},factory);local page={}
    expected={ImageContent=page,Position=1,Size=2,ImageRectOffset=roblox.Vector2.new(1,2),ImageRectSize=roblox.Vector2.new(3,4),Visible=true}
    s:begin();s:image(expected);s:finish();s:begin();s:finish()
    expected={ImageContent=page,Position=7,Size=9,ImageRectOffset=roblox.Vector2.new(1,2),ImageRectSize=roblox.Vector2.new(3,4),Visible=true}
    s:begin();s:image(expected);s:finish();assert(publications==2)
    expected={ImageContent=page,Position=11,Size=13,ImageRectOffset=roblox.Vector2.new(9,8),ImageRectSize=roblox.Vector2.new(7,6)}
    s:begin();s:image(expected);s:finish();assert(publications==3 and #s.images==2)
end)
test('bounded detached reserves absorb per-content visibility changes after warmup',function()
    local Scene=load('GpuScene');local s=Scene.new({},function()return {Destroy=function()end}end,{imageReserve=4})
    local function draw(a,b)
        s:begin()
        for _,pair in {{'a',a},{'b',b}}do for i=1,pair[2]do
            s:image({ImageContent=pair[1],ImageRectOffset=roblox.Vector2.new(s.generation+i,0),ImageRectSize=roblox.Vector2.new(i,1)})
        end end
        s:finish()
        local n=0;for _,e in s.images do if e.object.Parent==s.parent then n+=1;assert(e.object.Visible)end end
        assert(n==a+b)
    end
    draw(1,3);local created=s.createdImages
    for frame=1,240 do draw(if frame%2==0 then 3 else 1,if frame%2==0 then 1 else 3)end
    assert(s.createdImages==created and s.destroyedImages==0 and #s.images<=12)
end)
test('keepParented locks active animation crops through long idle pauses and consumes only hidden reserves',function()
    local Scene=load('GpuScene');local state={};local parent={}
    local function factory()
        local values={cropWrites=0,parentWrites=0};local object
        object=setmetatable({Destroy=function()values.destroyed=true end},{__index=values,__newindex=function(_,key,value)
            if key=='ImageRectOffset' or key=='ImageRectSize' then
                assert(not values.Visible,'A visible image must never be recropped in keepParented mode')
                values.cropWrites+=1
            elseif key=='Parent'then values.parentWrites+=1 end
            values[key]=value
        end})
        state[object]=values;return object
    end
    local s=Scene.new(parent,factory,{keepParented=true,imageReserve=2,cropRetentionFrames=180,maxInactiveImages=0,imageRetentionFrames=1})
    local function props(x,z,w)
        return {ImageContent='sprites',ImageRectOffset=roblox.Vector2.new(x,2),ImageRectSize=roblox.Vector2.new(w or 8,12),ZIndex=z}
    end
    s:begin();local a=s:image(props(1,10));local b=s:image(props(20,20));s:finish()
    local created=s.createdImages;assert(created==4)
    for _=1,180 do
        s:begin();assert(s:image(props(20,30))==b);s:finish()
        assert(a.Parent==parent and a.Visible and a.ImageTransparency==1 and state[a].cropWrites==2 and state[a].parentWrites==1)
        assert(not state[a].destroyed and state[b].cropWrites==2)
    end
    s:begin();assert(s:image(props(1,10))==a);assert(s:image(props(20,20))==b);s:finish()
    s:begin();local c=s:image(props(40,10,-8));local d=s:image(props(60,20));s:finish()
    assert(c~=a and c~=b and d~=a and d~=b and c~=d)
    assert(s.createdImages==created and s.recycledImages==2,'Only unbound reserves should be recycled')
    s:begin();local e=s:image(props(80,30));s:finish()
    assert(e~=a and e~=b and e~=c and e~=d and s.createdImages==created+1)
    s:begin();assert(s:image(props(1,40))==a);assert(s:image(props(20,10))==b)
    assert(s:image(props(40,20,-8))==c);assert(s:image(props(60,30))==d);s:finish()
    assert(a.ZIndex==40 and b.ZIndex==10 and c.ZIndex==20 and d.ZIndex==30,'Retained crops must follow current draw order')
    for object,values in state do assert(values.cropWrites==2 and values.parentWrites==1 and not values.destroyed)end
    for _=1,181 do s:begin();s:finish() end
    assert(#s.images==0 and next(s.imageBuckets)==nil,'Expired inactive crops must obey a zero image budget')
    for _,values in state do assert(values.destroyed and values.Parent==nil and not values.Visible and values.parentWrites==2)end
end)
test('crop retention expires by last draw even while its atlas remains active',function()
    local Scene=load('GpuScene')
    for _,retention in {0,2,180}do
        local s=Scene.new({},function()return {Destroy=function(self)self.destroyed=true end}end,
            {keepParented=true,cropRetentionFrames=retention,imageRetentionFrames=2,maxInactiveImages=2})
        local function props(x)return {ImageContent='sprites',ImageRectOffset=roblox.Vector2.new(x,0),ImageRectSize=roblox.Vector2.new(8,12)}end
        -- Out-of-packed-range integer keys must retain just like packed keys.
        s:begin();local idle=s:image(props(4096));local active=s:image(props(8));s:finish()
        for _=1,retention do
            s:begin();assert(s:image(props(8))==active);s:finish()
            assert(idle.Parent==s.parent and idle.Visible and idle.ImageTransparency==1 and not idle.destroyed,'Retained crops must stay parented through the inclusive window')
        end
        s:begin();s:image(props(8));s:finish()
        assert(idle.Parent==nil and not idle.Visible and not idle.destroyed,'Expired crops must detach from active buckets')
        s:begin();assert(s:image(props(16))==idle);s:image(props(8));s:finish()
        assert(s.createdImages==2 and s.recycledImages==1 and idle.Parent==s.parent)
        for _=1,retention+3 do s:begin();s:image(props(8));s:finish()end
        assert(idle.destroyed and #s.images==1,'Expired active-bucket crops must eventually release cached content')
    end
    for _,invalid in {-1,1.5,math.huge,0/0}do
        assert(not pcall(function()Scene.new({},function()return {}end,{cropRetentionFrames=invalid})end))
    end
end)

test('expired crops in active buckets obey the inactive image budget',function()
    local s=load('GpuScene').new({},function()return {Destroy=function(self)self.destroyed=true end}end,
        {keepParented=true,cropRetentionFrames=1,maxInactiveImages=0})
    local function props(x)return {ImageContent='sprites',ImageRectOffset=roblox.Vector2.new(x,0),ImageRectSize=roblox.Vector2.new(8,12)}end
    s:begin();local idle=s:image(props(0));local active=s:image(props(8));s:finish()
    s:begin();s:image(props(8));s:finish();assert(not idle.destroyed and idle.Parent==s.parent)
    s:begin();s:image(props(8));s:finish()
    assert(idle.destroyed and idle.Parent==nil and #s.images==1 and active.Parent==s.parent)
end)

test('fractional edge clips alternate cooled labels with exact crops and safe publication',function()
    for _,reserve in {0,4}do
        local expected;local publications=0;local parentWrites=0
        local s=load('GpuScene').new({},function()
            local values={}
            return setmetatable({Destroy=function()error('Moving edge clips must reuse their label')end},
                {__index=values,__newindex=function(_,key,value)
                    if key=='ImageRectOffset' or key=='ImageRectSize' then assert(not values.Visible,'Hide before recropping')end
                    if key=='Visible' and value then
                        for _,field in {'Position','Size','ImageRectOffset','ImageRectSize'}do assert(values[field]==expected[field],'Publish complete geometry before visibility')end
                        publications+=1
                    elseif key=='Parent' then parentWrites+=1 end
                    values[key]=value
                end})
        end,{keepParented=true,imageReserve=reserve,cropRetentionFrames=180,imageRetentionFrames=600,maxInactiveImages=1024})
        local label
        for frame=1,90 do
            -- RenderClip.texture for a 16x16 sprite at posX=-1-frame/100,
            -- clipped to x>=0, with source atlas offset (100,20).
            local left=1+frame/100
            expected={ImageContent='stable-atlas',ImageRectOffset=roblox.Vector2.new(100+left,20),
                ImageRectSize=roblox.Vector2.new(16-left,16),Position=frame,Size=16-left}
            s:begin();local current=s:image(expected);s:finish()
            assert(not label or current~=label);label=current
            assert(label.ImageRectOffset==expected.ImageRectOffset and label.ImageRectSize==expected.ImageRectSize)
            assert(s.createdImages<=(if reserve==0 then 3 else 6) and #s.images==s.createdImages)
            local regions=0;for _ in s.imageBuckets['stable-atlas'].regions do regions+=1 end
            assert(regions<=(if reserve==0 then 3 else 4),'Obsolete fractional keys must stay bounded')
        end
        assert(s.recycledImages>=87 and publications==90 and parentWrites==3, 'Crop cycle '..s.recycledImages..'/'..publications..'/'..parentWrites)
    end
end)

test('scrolling integer crops alternate cooled parented labels',function()
    local parent={};local parentWrites=0
    local s=load('GpuScene').new(parent,function()
        local values={}
        return setmetatable({Destroy=function()error('Unexpected destruction')end},{__index=values,__newindex=function(_,key,value)
            assert(key~='ScrollingCrop','Internal crop flag must not reach Roblox')
            if key=='Parent' then parentWrites+=1 end
            values[key]=value
        end})
    end,{keepParented=true,cropRetentionFrames=180})
    local label
    for frame=1,200 do
        s:begin();local current=s:image({ImageContent='scroll',ScrollingCrop=true,ImageRectOffset=roblox.Vector2.new(frame,0),ImageRectSize=roblox.Vector2.new(20,20)});s:finish()
        assert(not label or label~=current);label=current
        assert(current.Parent==parent and current.ImageRectOffset.X==frame and s.createdImages==math.min(frame,3))
    end
    assert(parentWrites==3)
end)

test('fractional churn preserves retained integer crops and simultaneous moving sprites',function()
    local s=load('GpuScene').new({},function()return {Destroy=function()end}end,
        {keepParented=true,imageReserve=4,cropRetentionFrames=180,maxInactiveImages=0})
    local function props(x,w)return {ImageContent='sprites',ImageRectOffset=roblox.Vector2.new(x,20),ImageRectSize=roblox.Vector2.new(w,16)}end
    s:begin();local idle=s:image(props(100,16));s:finish()
    local created
    for frame=1,90 do
        s:begin();local a=s:image(props(101+frame/100,15-frame/100))
        local b=s:image(props(201+frame/100,15-frame/100));s:finish()
        assert(a~=b and a~=idle and b~=idle and a.Visible and b.Visible)
        assert(idle.Parent==s.parent and idle.Visible and idle.ImageTransparency==1 and idle.ImageRectOffset==roblox.Vector2.new(100,20))
        if frame==3 then created=s.createdImages end
        assert((frame<3 or s.createdImages==created) and #s.images<=7,'Moving clips must reuse labels or reserves after warmup')
    end
    s:begin();assert(s:image(props(100,16))==idle);s:finish()
end)

test('keepParented inactive buckets detach, obey a global budget and expire by frame age',function()
    local Scene=load('GpuScene');local s=Scene.new({},function()return {Destroy=function(self)self.destroyed=true end}end,
        {keepParented=true,maxInactiveImages=2,imageRetentionFrames=2})
    s:begin();local a=s:image({ImageContent='a'});local b=s:image({ImageContent='b'});local c=s:image({ImageContent='c'});s:finish()
    s:begin();assert(s:image({ImageContent='a'})==a);s:finish()
    assert(a.Parent==s.parent and b.Parent==nil and c.Parent==nil and not b.Visible and not c.Visible and #s.images==3)
    s:begin();s:finish();assert(#s.images==2 and not a.Visible and a.Parent==nil)
    s:begin();assert(s:image({ImageContent='a'})==a);s:finish()
    assert(#s.images==1 and a.Parent==s.parent and b.destroyed and c.destroyed)
    for _=1,3 do s:begin();s:finish()end
    assert(a.destroyed and #s.images==0 and next(s.imageBuckets)==nil)
end)
test('crop keys distinguish packed boundaries, mirrored sizes and fractional rectangles',function()
    local Scene=load('GpuScene');local s=Scene.new({},function()return {Destroy=function()end}end,{keepParented=true})
    local crops={{-4096,-4096,-4096,-4096},{4095,4095,4095,4095},{4096,0,8,12},{0,4096,8,12},
        {0,0,8,12},{0,0,-8,12},{0,0,8,-12},{.5,.25,8.5,12.25},{.5001,.25,8.5,12.25}}
    local objects={};s:begin()
    for i,crop in crops do
        objects[i]=s:image({ImageContent='atlas',ImageRectOffset=roblox.Vector2.new(crop[1],crop[2]),ImageRectSize=roblox.Vector2.new(crop[3],crop[4])})
        for j=1,i-1 do assert(objects[i]~=objects[j])end
    end
    s:finish();s:begin()
    for i=#crops,1,-1 do local crop=crops[i]
        assert(s:image({ImageContent='atlas',ImageRectOffset=roblox.Vector2.new(crop[1],crop[2]),ImageRectSize=roblox.Vector2.new(crop[3],crop[4])})==objects[i])
    end
    s:finish();assert(s.writes==0 and s.createdImages==#crops)
end)
test("Fit PixelPerfect and Stretch scaling", function()
	local Shell = load("Shell")
	local s, w, h = Shell.computeScale(320, 180, roblox.Vector2.new(1000, 600), "Fit"); assert(s == 3.125 and w == 320 and h == 180)
	s = Shell.computeScale(320, 180, roblox.Vector2.new(1000, 600), "PixelPerfect"); assert(s == 3)
	s, w, h = Shell.computeScale(320, 180, roblox.Vector2.new(1000, 600), "Stretch"); assert(w * s == 1000 and h * s == 600)
	for _,size in {roblox.Vector2.new(1547,630),roblox.Vector2.new(1024,417),roblox.Vector2.new(844,390)} do
		s,w,h=Shell.computeScale(1920,1080,size,"Stretch")
		assert(math.abs(w*s-size.X)<1e-6 and math.abs(h*s-size.Y)<1e-6,'Stretch must fill both axes without cropping')
	end
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
	local Client = load("SaveClient"); local fail = false; local seen = {}; local applied;local busy={}
	local c = Client.new({isStudio = true, snapshot = function() return {value = 7} end, apply = function(data, sent) applied = sent end,
		onBusy=function(value)table.insert(busy,value)end,
		remote = {InvokeServer = function(_, request)
			table.insert(seen, request); if fail then error("offline") end
			return {ok = true, data = {}, revision = 2}
		end}})
	assert(c:sync()); fail = true; assert(not c:sync()); assert(c.lastStatus:match("Studio"))
	fail = false; assert(c:sync()); assert(seen[2] == seen[3] and applied.value == 7)
	assert(#busy==6 and busy[1] and not busy[2] and busy[3] and not busy[4] and busy[5] and not busy[6])
end)
test("rolling stats and native stripping", function()
	local Benchmark = load("Benchmark"); local b = Benchmark.new(3)
	for _, n in {10, 1, 2, 3} do b:record(n / 1000, 1 / 240) end
	local s = b:stats(); assert(s.samples == 3 and s.meanMs == 2 and s.p50Ms == 2 and s.p95Ms == 3 and s.maxMs == 3)
	assert(math.abs(s.observedRenderFPS - 240) < .001)
	assert(Benchmark.stripNative("--!native\nreturn 1") == "return 1")
end)
test('audio slices recycle, wrap and preserve silent timelines',function()
    local Pool=load('AudioPool');local now=0;local sounds={}
    local function factory()
        local s={TimePosition=0};function s:Play()self.playing=true end;function s:Stop()self.playing=false;self.TimePosition=0 end
        function s:Pause()self.playing=false end;function s:Resume()self.playing=true end;function s:Destroy()self.destroyed=true end
        table.insert(sounds,s);return s
    end
    local pool=Pool.new({parent={},factory=factory,clock=function()return now end,catalog={
        one={uri='rbxassetid://1',startSec=3,lengthSec=2,volume=.5},
        loop={uri='rbxassetid://1',startSec=10,lengthSec=2,loopStartSec=10.5,loop=true},
        silent={disabled=true}}})
    local h=pool:play('one',{});h:start();local sound=h.sound;assert(sound.TimePosition==3)
    h:volume(.4);h:pitch(1.5);assert(sound.Volume==.2 and sound.PlaybackSpeed==1.5)
    h:pause(true);assert(not sound.playing);h:pause(false);assert(sound.playing)
    sound.TimePosition=5;pool:update();assert(h:state()==2 and #pool.free==1)
    local loop=pool:play('loop',{});assert(loop.sound==sound);loop:start();sound.TimePosition=12.25;pool:update()
    assert(math.abs(sound.TimePosition-10.75)<.00001);loop:seek(1000);assert(sound.TimePosition==11)
    local count=#sounds;local ok,err=pcall(pool.play,pool,'missing',{})
    assert(ok and err.stopped and #pool.errors==1 and #sounds==count,'Missing bindings must report and stop before sound creation')
    local silent=pool:play('silent',{oneshot=true,lengthMs=1000});silent:start();now=.5;pool:update();assert(silent:state()==0)
    silent:pause(true);now=4;pool:update();assert(silent:state()==0);silent:pause(false);now=4.6;pool:update();assert(silent:state()==2)
    pool:destroy();assert(sound.destroyed)
end)
test("teleport gate allows direct joins, same-owner groups, explicit allowlists, and kicks unauthorized hubs", function()
	local TeleportGate = load("TeleportGate")
	local warnings = {}
	local lookups = 0
	local placeCreators = {
		[111111] = {Creator = {CreatorType = "Group", Id = 1, CreatorTargetId = 521478388}},
		[222222] = {Creator = {CreatorType = "Group", Id = 2, CreatorTargetId = 987654}},
		[333333] = {Creator = {CreatorType = "Group", Id = 3, CreatorTargetId = 666666}},
	}
	local gate = TeleportGate.new({
		isStudio = false,
		gameId = 10773605904,
		placeId = 131388266857137,
		creatorType = {Name = "Group"},
		creatorId = 521478388,
		allowedPlaceIds = {444444},
		allowedUniverseIds = {555555},
		allowedGroupIds = {987654},
		onWarn = function(msg) table.insert(warnings, msg) end,
		getPlaceInfo = function(placeId)
			lookups += 1
			if placeId == 777777 then error("http timeout") end
			return placeCreators[placeId]
		end,
	})
	local function mockPlayer(userId, joinData)
		local p = {UserId = userId, kicked = nil}
		function p:GetJoinData() return joinData end
		function p:Kick(reason) self.kicked = reason end
		return p
	end

	local directPlayer = mockPlayer(10, {TeleportData = nil})
	local ok1, reason1 = gate:checkPlayer(directPlayer)
	assert(ok1 and reason1 == "direct" and not directPlayer.kicked and gate:isAuthorized(directPlayer))

	local internalPlayer = mockPlayer(11, {SourceGameId = 10773605904, SourcePlaceId = 999999})
	local ok2, reason2 = gate:checkPlayer(internalPlayer)
	assert(ok2 and reason2 == "same_experience" and lookups == 0)

	local ownGroupPlayer1 = mockPlayer(12, {SourceGameId = 1001, SourcePlaceId = 111111})
	local ownGroupPlayer2 = mockPlayer(13, {SourceGameId = 1001, SourcePlaceId = 111111})
	assert(gate:checkPlayer(ownGroupPlayer1) and lookups == 1)
	assert(gate:checkPlayer(ownGroupPlayer2) and lookups == 1)

	assert(gate:checkPlayer(mockPlayer(14, {SourceGameId = 1002, SourcePlaceId = 222222})) and lookups == 2)
	assert(gate:checkPlayer(mockPlayer(15, {SourceGameId = 1003, SourcePlaceId = 444444})) and lookups == 2)
	assert(gate:checkPlayer(mockPlayer(16, {SourceGameId = 555555, SourcePlaceId = 888888})) and lookups == 2)

	local hubPlayer = mockPlayer(17, {SourceGameId = 6000, SourcePlaceId = 333333})
	local okHub, reasonHub = gate:checkPlayer(hubPlayer)
	assert(not okHub and reasonHub == "unauthorized_teleport" and hubPlayer.kicked and not gate:isAuthorized(hubPlayer))

	local errPlayer = mockPlayer(18, {SourceGameId = 7000, SourcePlaceId = 777777})
	local okErr = gate:checkPlayer(errPlayer)
	assert(not okErr and errPlayer.kicked and not gate:isAuthorized(errPlayer) and #warnings >= 2)
	gate:clearPlayer(errPlayer)
	assert(gate:isAuthorized(errPlayer))
end)
print("PortKit runtime checks:", total)
