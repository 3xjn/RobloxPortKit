--!optimize 2
-- Detect once per session/scene; never query services in the draw loop.
local Profile = {}
function Profile.detect(options)
	options = options or {}
	local uis, viewport = options.uis, options.viewport
	if not uis then pcall(function() uis = game:GetService('UserInputService') end) end
	if not viewport then pcall(function() viewport = workspace.CurrentCamera.ViewportSize end) end
	local mobile = options.mobile == true or (uis ~= nil and uis.TouchEnabled and not uis.KeyboardEnabled)
		or (viewport ~= nil and math.min(viewport.X, viewport.Y) > 0 and math.min(viewport.X, viewport.Y) <= 540)
	return {isMobile = mobile == true, maxParkedNodes = options.maxParkedNodes or (if mobile then 384 else 2048),
		residencyWindow = options.residencyWindow or 5, touchControls = options.mobile == true or (uis ~= nil and uis.TouchEnabled == true)}
end
return Profile
