--!optimize 2
-- Optional standalone launcher: explicit adjacent config is required.
-- Games with their own save server must never launch a second service.
local servers = game:GetService("ServerScriptService")
for _, child in servers:GetChildren() do
    if child ~= script and (child.Name == "JumpKingServer" or child.Name == "CelesteServer" or child.Name == "CelesteSave") then return end
end
local config = script.Parent:FindFirstChild("PortKitSaveConfig")
if not config or not config:IsA("ModuleScript") then return end
local module = script.Parent:WaitForChild("SaveServer", 8)
assert(module and module:IsA("ModuleScript"), "[PORT-ERROR] SaveServer ModuleScript unavailable")
require(module).start(require(config))
