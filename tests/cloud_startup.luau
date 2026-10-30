local F = require('./mobile_fixture')
local fs = require('@lune/fs')
local signal = F.signal()
local inputSignal = F.signal()
local pad = {GamepadCursorEnabled = true, calls = 0}
function pad:DisableGamepadCursor() self.calls += 1; self.GamepadCursorEnabled = false end
function pad:GetPropertyChangedSignal(name) assert(name == 'GamepadCursorEnabled'); return signal end
local uis = {LastInputTypeChanged = inputSignal}
function uis:GetLastInputType() return F.rbx.Enum.UserInputType.Gamepad1 end
local nav = {}
local Shell = F.load('runtime/Shell.luau')
local config = {gamepadService = pad, userInputService = uis, guiService = nav}
local cleanup = Shell.configureCoreGui(config)
assert(pad.calls == 1 and not pad.GamepadCursorEnabled and not uis.MouseIconEnabled)
assert(nav.AutoSelectGuiEnabled == false and nav.GuiNavigationEnabled == false)
pad.GamepadCursorEnabled = true; signal:fire(); assert(pad.calls == 2 and not pad.GamepadCursorEnabled)
inputSignal:fire(F.rbx.Enum.UserInputType.MouseMovement); assert(uis.MouseIconEnabled)
inputSignal:fire(F.rbx.Enum.UserInputType.Touch); assert(not uis.MouseIconEnabled)
config.mouseIconEnabled = false
inputSignal:fire(F.rbx.Enum.UserInputType.MouseButton1); assert(not uis.MouseIconEnabled)
cleanup(); pad.GamepadCursorEnabled = true; signal:fire(); assert(pad.calls == 2)
config.disableControllerCursor = false
Shell.configureCoreGui(config); assert(pad.calls == 2)

local Scheduler = F.load('../xna2luau/runtime/CooperativeScheduler.luau', {
    debug = {traceback = function() error('Traceback must not be needed for tracked suspension') end},
})
local scheduler = Scheduler.new()
local completed = false
local thread = coroutine.create(function() scheduler.wait(); completed = true end)
assert(coroutine.resume(thread)); assert(scheduler.isSuspended(thread))
scheduler.defer(thread); scheduler.step(0)
assert(completed and not scheduler.isSuspended(thread))
assert(not fs.isFile('runtime/SaveServer.server.luau'))
assert(fs.isFile('runtime/SaveServerAuto.server.luau') and fs.isFile('runtime/SaveServer.luau'))
assert(loadstring(fs.readFile('runtime/SaveServerAuto.server.luau')))
print('PASS controller cursor initial/re-enable/input/opt-out/cleanup and scheduler suspension without traceback')
