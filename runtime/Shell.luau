local Shell = {}
Shell.__index = Shell
function Shell.computeScale(width, height, viewport, mode)
	local fit = math.min(viewport.X / width, viewport.Y / height)
	if mode == "PixelPerfect" and fit >= 1 then fit = math.floor(fit) end
	return fit, if mode == "Stretch" then viewport.X / fit else width, if mode == "Stretch" then viewport.Y / fit else height
end
function Shell.button(parent, text, callback)
	local b = Instance.new("TextButton"); b.Text = text; b.TextSize = 16; b.Font = Enum.Font.GothamMedium
	b.BackgroundColor3 = Color3.fromRGB(45, 51, 76); b.TextColor3 = Color3.fromRGB(240, 242, 255)
	b.BorderSizePixel = 0; b.Selectable = true; b.ZIndex = 102; b.Parent = parent
	local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 6); corner.Parent = b
	b.Activated:Connect(callback)
	return b
end
function Shell.new(config)
	config = config or {}
	local self = setmetatable({connections = {}, width = config.width or 320, height = config.height or 180,
		scaleMode = config.scaleMode or "Fit", open = false, alive = true, modalListeners = {}, cleanup = {}}, Shell)
	local player = game:GetService("Players").LocalPlayer
	local gui = player:WaitForChild("PlayerGui")
	gui.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor
	local name = config.name or "PortKit"
	for _, suffix in {"", "Hud"} do local old = gui:FindFirstChild(name .. suffix); if old then old:Destroy() end end
	local viewport = Instance.new("ScreenGui"); viewport.Name = name; viewport.IgnoreGuiInset = true
	viewport.ScreenInsets = Enum.ScreenInsets.None; viewport.ClipToDeviceSafeArea = false
	viewport.ResetOnSpawn = false; viewport.DisplayOrder = 30; viewport.ZIndexBehavior = Enum.ZIndexBehavior.Global; viewport.Parent = gui
	self.ViewportGui = viewport
	local hud = Instance.new("ScreenGui"); hud.Name = name .. "Hud"; hud.IgnoreGuiInset = true
	hud.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets; hud.SafeAreaCompatibility = Enum.SafeAreaCompatibility.None
	hud.ResetOnSpawn = false; hud.DisplayOrder = 31; hud.ZIndexBehavior = Enum.ZIndexBehavior.Global; hud.Parent = gui
	self.HudGui = hud
	local matte = Instance.new("Frame"); matte.Name = "Letterbox"; matte.Size = UDim2.fromScale(1, 1)
	matte.BackgroundColor3 = Color3.new(); matte.BorderSizePixel = 0; matte.Parent = viewport
	local canvas = Instance.new("Frame"); canvas.Name = "Viewport"; canvas.AnchorPoint = Vector2.new(.5, .5)
	canvas.Position = UDim2.fromScale(.5, .5); canvas.ClipsDescendants = true
	canvas.BackgroundColor3 = Color3.fromRGB(12, 15, 32); canvas.BorderSizePixel = 0; canvas.Parent = matte
	self.Canvas = canvas; self.Scale = Instance.new("UIScale"); self.Scale.Parent = canvas
	local gear = Shell.button(hud, "⚙", function() self:toggleMenu() end)
	gear.Name = "Settings"; gear.Size = UDim2.fromOffset(44, 40); gear.Position = UDim2.new(1, -56, 0, 12); self.Gear = gear
	local badge = Instance.new("TextLabel"); badge.Name = "SaveBadge"; badge.Size = UDim2.fromOffset(68, 20); badge.Position = UDim2.new(1, -82, 0, 55); badge.BackgroundTransparency = 1; badge.TextColor3 = Color3.fromRGB(238, 197, 133); badge.TextSize = 12; badge.Font = Enum.Font.Gotham; badge.Text = ""; badge.Parent = hud; self.SaveBadge = badge
	local blocker = Instance.new("TextButton"); blocker.Name = "ModalBlocker"; blocker.Text = ""; blocker.AutoButtonColor = false
	blocker.Size = UDim2.fromScale(1, 1); blocker.BackgroundColor3 = Color3.new(); blocker.BackgroundTransparency = .35
	blocker.BorderSizePixel = 0; blocker.Visible = false; blocker.Active = true; blocker.Selectable = false; blocker.ZIndex = 100; blocker.Parent = hud; self.Blocker = blocker
	local modal = Instance.new("Frame"); modal.Name = "SettingsMenu"; modal.Size = UDim2.new(.94, 0, .9, 0)
	modal.AnchorPoint = Vector2.new(.5, .5); modal.Position = UDim2.fromScale(.5, .5)
	modal.BackgroundColor3 = Color3.fromRGB(21, 25, 43); modal.BorderSizePixel = 0; modal.ZIndex = 101; modal.Parent = blocker; self.Modal = modal
	local limit = Instance.new("UISizeConstraint"); limit.MaxSize = Vector2.new(660, 480); limit.Parent = modal
	local close = Shell.button(modal, "Resume", function() self:setOpen(false) end)
	close.Name = "Resume"; close.Size = UDim2.fromOffset(90, 32); close.Position = UDim2.new(1, -104, 0, 12); self.FirstButton = close
	local toast = Instance.new("TextLabel"); toast.Name = "Status"; toast.Size = UDim2.new(1, -120, 0, 28)
	toast.Position = UDim2.new(0, 12, 1, -34); toast.BackgroundTransparency = 1; toast.TextColor3 = Color3.new(1, 1, 1)
	toast.TextSize = 13; toast.TextXAlignment = Enum.TextXAlignment.Center; toast.TextXAlignment = Enum.TextXAlignment.Center; toast.Text = ""; toast.ZIndex = 120; toast.Parent = hud; self.Toast = toast
	local services = game:GetService("GuiService"); self.oldAutoSelect = services.AutoSelectGuiEnabled; services.AutoSelectGuiEnabled = false
	local function track(c) table.insert(self.connections, c) end
	local function hidePart(part)
		if part:IsA("BasePart") then part.LocalTransparencyModifier = 1; part.Transparency = 1; part.Anchored = true; part.CanCollide = false; part.CanTouch = false; part.CanQuery = false
		elseif part:IsA("Decal") then part.Transparency = 1
		elseif part:IsA("Humanoid") then part.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None; part.AutoRotate = false end
	end
	local characterConnection
	local function character(model)
		if characterConnection then characterConnection:Disconnect() end
		for _, part in model:GetDescendants() do hidePart(part) end
		characterConnection = model.DescendantAdded:Connect(hidePart)
	end
	track(player.CharacterAdded:Connect(character)); if player.Character then character(player.Character) end
	table.insert(self.cleanup, function() if characterConnection then characterConnection:Disconnect() end end)
	pcall(function() game:GetService("StarterPlayer").EnableMouseLockOption = false end)
	local uis = game:GetService("UserInputService"); uis.MouseBehavior = Enum.MouseBehavior.Default; uis.MouseIconEnabled = true
	task.spawn(function()
		local module = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10)
		if module and self.alive then local ok, controls = pcall(function() return require(module):GetControls() end); if ok then controls:Disable() end end
	end)
	task.spawn(function()
		local starter = game:GetService("StarterGui")
		for _ = 1, 10 do
			if not self.alive then return end
			local ok = pcall(function()
				for _, kind in {Enum.CoreGuiType.Backpack, Enum.CoreGuiType.Health, Enum.CoreGuiType.PlayerList, Enum.CoreGuiType.EmotesMenu} do starter:SetCoreGuiEnabled(kind, false) end
			end)
			if ok then break end; task.wait(.2)
		end
	end)
	local cameraConnection
	local function cameraChanged()
		if cameraConnection then cameraConnection:Disconnect() end
		local camera = workspace.CurrentCamera
		if camera then
			camera.CameraType = Enum.CameraType.Scriptable
			cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function() self:resize() end)
		end
		self:resize()
	end
	track(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(cameraChanged)); cameraChanged()
	table.insert(self.cleanup, function() if cameraConnection then cameraConnection:Disconnect() end end)
	track(viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() self:resize() end))
	track(uis.InputBegan:Connect(function(event, processed)
		local key = event.KeyCode
		if key == Enum.KeyCode.Escape then
			if self.open or not processed then self:toggleMenu() end
		end
	end))
	-- Capture gamepad cancel before default navigation; unbound on destruction.
	self.bindName = "PortKitMenu_" .. name
	game:GetService("ContextActionService"):BindActionAtPriority(self.bindName, function(_, state, event)
		if state == Enum.UserInputState.Begin then
			if event.KeyCode == Enum.KeyCode.ButtonStart then self:toggleMenu(); return Enum.ContextActionResult.Sink end
			if self.open then self:setOpen(false); return Enum.ContextActionResult.Sink end
		end
		return Enum.ContextActionResult.Pass
	end, false, 3000, Enum.KeyCode.ButtonB, Enum.KeyCode.ButtonStart)
	track(viewport.Destroying:Connect(function() self:destroy() end))
	return self
end
function Shell:resize()
	local camera = workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else self.ViewportGui.AbsoluteSize
	if viewport.X <= 0 or viewport.Y <= 0 then return end
	local scale, w, h = Shell.computeScale(self.width, self.height, viewport, self.scaleMode)
	self.Scale.Scale = scale; self.Canvas.Size = UDim2.fromOffset(w, h)
end
function Shell:setScaleMode(mode)
	assert(mode == "Fit" or mode == "PixelPerfect" or mode == "Stretch", "Unknown scale mode")
	self.scaleMode = mode; self:resize()
end
function Shell:onModal(callback) table.insert(self.modalListeners, callback) end
function Shell:toggleMenu()
	if self.pauseHandler then self.pauseHandler() else self:setOpen(not self.open) end
end
function Shell:setOpen(value)
	if self.open == value then return end
	self.open = value; self.Blocker.Visible = value
	local service = game:GetService("GuiService")
	service.SelectedObject = nil
	if value then
		-- Newly shown UI is not selectable until Roblox has laid out a frame.
		task.spawn(function()
			game:GetService("RunService").RenderStepped:Wait()
			game:GetService("RunService").RenderStepped:Wait()
			if self.alive and self.open then service.SelectedObject = self.FirstButton end
		end)
	end
	for _, callback in self.modalListeners do callback(value) end
end
function Shell:setStatus(message)
    self.statusGeneration = (self.statusGeneration or 0) + 1
    local generation = self.statusGeneration
    local offline = string.find(message, "Offline", 1, true) or string.find(message, "offline", 1, true)
    self.SaveBadge.Text = if offline then "Offline" else ""
    self.Toast.Text = if offline then "Save offline" else message
    task.delay(4, function() if self.alive and generation == self.statusGeneration then self.Toast.Text = "" end end)
end
function Shell:destroy()
	if not self.alive then return end; self.alive = false
	game:GetService("ContextActionService"):UnbindAction(self.bindName)
	local service = game:GetService("GuiService"); service.SelectedObject = nil; service.AutoSelectGuiEnabled = self.oldAutoSelect
	for _, c in self.connections do c:Disconnect() end
	for _, callback in self.cleanup do callback() end
	self.HudGui:Destroy(); self.ViewportGui:Destroy()
end
return Shell
