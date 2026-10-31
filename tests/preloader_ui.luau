local F = require('./mobile_fixture')
local Preloader = F.load('runtime/Preloader.luau')

local renderSignal = F.signal()
local runService = { RenderStepped = renderSignal }
local now = 10.0
local yields = 0
local delayed = {}
local scheduler = {
	wait = function()
		yields += 1
	end,
	delay = function(sec, fn)
		delayed[#delayed + 1] = { sec = sec, fn = fn }
	end,
	spawn = function(fn)
		fn()
	end,
}

local parent = F.factory('PlayerGui')
local p = Preloader.new({
	parent = parent,
	scheduler = scheduler,
	runService = runService,
	clock = function()
		return now
	end,
	instanceFactory = F.factory,
	contentProvider = {
		PreloadAsync = function(_, batch, cb)
			for _, obj in batch do
				cb(obj.SoundId or obj.Image, 'Success')
			end
		end,
	},
})

assert(p.gui and p.gui.Name == 'PortKitPreloader')
assert(p.hud and p.hud.Visible == true)
assert(p.titleLabel.Text == 'Loading')
assert(p.percentLabel.Text == '0%')

p:setTitle('Sonic Dimensions')
assert(p.titleLabel.Text == 'Loading Sonic Dimensions')

p:checkpoint('Unpacking...', 0.25, 0.025)
assert(yields == 0 and p.percentLabel.Text == '25%')
now += 0.030
p:checkpoint('Unpacking...', 0.50, 0.025)
assert(yields == 1 and p.percentLabel.Text == '50%')

local res = p:preload({ images = { 'rbxassetid://1', 'rbxassetid://2' }, progressEnd = 0.90 })
assert(res.status == 'complete' and res.completed == 2)
assert(p.percentLabel.Text == '90%')

p:finish()
assert(p.percentLabel.Text == '100%')
now += 0.07
renderSignal:fire(0.016)
assert(not p.destroyed and math.abs(p.group.GroupTransparency - 0.5) < 0.05)
now += 0.10
renderSignal:fire(0.016)
assert(p.destroyed)

-- Verify error state hides bottom-right HUD and displays clean centered message
local pErr = Preloader.new({
	title = 'Mari0',
	parent = parent,
	scheduler = scheduler,
	runService = runService,
	clock = function()
		return now
	end,
	instanceFactory = F.factory,
})
pErr:fail('Missing save configuration')
assert(pErr.failed and pErr.hud.Visible == false)
assert(pErr.errorTitle.Visible == true and pErr.errorSub.Visible == true)
assert(pErr.errorSub.Text == 'Missing save configuration')
pErr:destroy()

print('PASS preloader minimal black HUD, setTitle, checkpoint budget yield, preload range, fade, and fail state')
