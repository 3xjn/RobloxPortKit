-- Optional standalone launcher. Place beside PortKitSaveConfig, a ModuleScript
-- returning the same config accepted by SaveServer.start. Ports may call start directly.
local config = script.Parent:WaitForChild("PortKitSaveConfig")
local kit = game:GetService("ReplicatedStorage"):WaitForChild("RobloxPortKit")
require(kit.SaveServer).start(require(config))
