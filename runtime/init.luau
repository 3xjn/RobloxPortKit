local PortKit = {}
PortKit.Shell = require(script.Shell)
PortKit.Input = require(script.Input)
PortKit.AtlasPool = require(script.AtlasPool)
PortKit.GpuScene = require(script.GpuScene)
PortKit.SaveClient = require(script.SaveClient)
PortKit.Benchmark = require(script.Benchmark)
function PortKit.createApp(config)
	local shell = PortKit.Shell.new(config)
	local inputConfig = table.clone(config.input or {})
	inputConfig.canvas = shell.Canvas; inputConfig.hud = shell.HudGui
	local input = PortKit.Input.new(inputConfig)
	shell:onModal(function(open) input:setEnabled(not open) end)
	local app = {shell = shell, input = input, benchmark = PortKit.Benchmark.new()}
	function app:destroy() self.input:destroy(); self.shell:destroy() end
	return app
end
return PortKit
