--!optimize 2
local PortKit = {}
PortKit.Preloader = require(script.Preloader)
PortKit.Shell = require(script.Shell)
PortKit.Input = require(script.Input)
PortKit.MobileProfile = require(script.MobileProfile)
PortKit.Stepper = require(script.Stepper)
PortKit.AudioPool = require(script.AudioPool)
PortKit.AudioBusGraph = require(script.AudioBusGraph)
PortKit.AtlasPool = require(script.AtlasPool)
PortKit.EditableImagePolicy = require(script.EditableImagePolicy)
PortKit.StaticImagePool = require(script.StaticImagePool)
PortKit.GpuScene = require(script.GpuScene)
PortKit.RetainedTextMesh = require(script.RetainedTextMesh)
PortKit.SaveClient = require(script.SaveClient)
PortKit.TeleportGate = require(script.TeleportGate)
PortKit.FileStore = require(script.FileStore)
PortKit.Benchmark = require(script.Benchmark)
function PortKit.createApp(config)
	local shell = PortKit.Shell.new(config)
	local inputConfig = table.clone(config.input or {})
	inputConfig.canvas = shell.Canvas; inputConfig.canvasScale = shell.Scale; inputConfig.hud = shell.HudGui
	local input = PortKit.Input.new(inputConfig)
	shell:onModal(function(open) input:setEnabled(not open) end)
	local app = {shell = shell, input = input, benchmark = PortKit.Benchmark.new()}
	if config.stepper then app.stepper = PortKit.Stepper.new(config.stepper) end
	function app:destroy() self.input:destroy(); self.shell:destroy() end
	return app
end
return PortKit
