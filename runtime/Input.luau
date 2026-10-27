local Input = {}
Input.__index = Input

function Input.new(config)
	config = config or {}
	local deadzone = config.dragDeadzone or 4
	assert(type(deadzone) == "number" and deadzone >= 0 and deadzone < math.huge, "Invalid drag deadzone")
	local self = setmetatable({bindings = config.bindings or {}, behaviors = config.behaviors or {},
		sources = {}, toggled = {}, presses = {}, touch = {}, stick = Vector2.zero,
		connections = {}, clock = config.clock or os.clock, enabled = true,
		pointer = {x = 0, y = 0, virtualX = 0, virtualY = 0, inside = false,
			down = false, dragging = false, startX = 0, startY = 0, deltaX = 0, deltaY = 0, cancelled = false},
		canvas = config.canvas, canvasScale = config.canvasScale, dragDeadzone = deadzone,
		layout = config.layout or "Platformer", pointerSecondary = false,
		touchMode = config.touchMode or "Auto", lastType = nil}, Input)
	if config.connect ~= false then self:connect(config) end
	return self
end

function Input:_raw(action)
	local sources = self.sources[action]
	if sources then for _, held in sources do if held then return true end end end
	return false
end
function Input:setSource(action, source, down)
	local before = self:_raw(action)
	self.sources[action] = self.sources[action] or {}
	self.sources[action][source] = if down and self.enabled then true else nil
	local after = self:_raw(action)
	if after and not before then
		self.presses[action] = self.clock()
		self.toggled[action] = not self.toggled[action]
	end
end
function Input:check(action)
	if not self.enabled then return false end
	local mode = self.behaviors[action] or "Hold"
	if mode == "Toggle" then return self.toggled[action] == true end
	if mode == "Invert" then return not self:_raw(action) end
	return self:_raw(action)
end
function Input:setBehavior(action, mode)
	assert(mode == "Hold" or mode == "Invert" or mode == "Toggle", "Unknown modifier behavior")
	self.behaviors[action] = mode; self.toggled[action] = nil
end
function Input:consumeBuffer(action, windowSeconds)
	local at = self.presses[action]
	self.presses[action] = nil
	return self.enabled and at ~= nil and self.clock() - at <= windowSeconds
end
function Input:reset()
	self:cancelPointer()
	table.clear(self.sources); table.clear(self.presses); table.clear(self.toggled); table.clear(self.touch)
	self.stick = Vector2.zero; self.moveTouch = nil; self.pointerTouch = nil
end
function Input:setEnabled(value) self:reset(); self.enabled = value; self:updateTouchVisibility() end
function Input:axis(negative, positive, component)
	local digital = (if self:check(positive) then 1 else 0) - (if self:check(negative) then 1 else 0)
	if not self.enabled then return 0 end
	local analog = if component == "Y" then self.stick.Y else self.stick.X
	return if digital ~= 0 then digital else (if math.abs(analog) >= .25 then analog else 0)
end

-- Same dispatch path is used for real events and deterministic regression tests.
function Input:process(phase, event, processed)
	local kind = event.UserInputType.Name
	if kind == "Touch" then
		if self.layout == "Pointer" then self:processTouchPointer(phase, event, processed) end
		return
	end
	if kind ~= "Keyboard" and kind ~= "Gamepad1" and not kind:match("^Mouse") then return end
	local key = if kind:match("^MouseButton") then kind else event.KeyCode.Name
	if phase == "Changed" and key == "Thumbstick1" and kind == "Gamepad1" then
		if self.enabled then self.stick = Vector2.new(event.Position.X, -event.Position.Y) end; return
	end
	if kind == "MouseMovement" then
		if not self.pointerTouch then self:updatePointer(event.Position) end
		return
	end
	if phase ~= "Ended" and (processed or not self.enabled) then return end
	if self.layout == "Pointer" and kind == "MouseButton1" and not self.pointerTouch then
		self:updatePointer(event.Position)
		if phase == "Began" then self:beginPointer("MouseButton1")
		elseif phase == "Ended" then self:endPointer("MouseButton1") end
	end
	local down = phase ~= "Ended"
	local trigger = key == "ButtonL2" or key == "ButtonR2"
	if phase == "Changed" then
		if not trigger then return end
		if event.Position.Z >= .25 then down = true
		elseif event.Position.Z < .18 then down = false else return end
	end
	for action, keys in self.bindings do
		for _, binding in keys do
			if binding == key then self:setSource(action, kind .. ":" .. key, down) end
		end
	end
end

function Input:updatePointer(position)
	if not self.canvas then return end
	local p, size = self.canvas.AbsolutePosition, self.canvas.AbsoluteSize
	local x, y = (position.X - p.X) / math.max(1, size.X), (position.Y - p.Y) / math.max(1, size.Y)
	local scale = if self.canvasScale then self.canvasScale.Scale else 1
	local pointer = self.pointer
	pointer.x = math.clamp(x, 0, 1); pointer.y = math.clamp(y, 0, 1)
	pointer.virtualX = (position.X - p.X) / math.max(1e-6, scale)
	pointer.virtualY = (position.Y - p.Y) / math.max(1e-6, scale)
	pointer.inside = x >= 0 and x <= 1 and y >= 0 and y <= 1
	if pointer.down then
		pointer.deltaX = pointer.virtualX - pointer.startX; pointer.deltaY = pointer.virtualY - pointer.startY
		if pointer.deltaX ^ 2 + pointer.deltaY ^ 2 > self.dragDeadzone ^ 2 then pointer.dragging = true end
	end
end
function Input:beginPointer(owner)
	local pointer = self.pointer
	if not self.enabled or not pointer.inside or pointer.down then return end
	self.pointerOwner = owner
	pointer.down = true; pointer.dragging = false; pointer.cancelled = false
	pointer.startX = pointer.virtualX; pointer.startY = pointer.virtualY
	pointer.deltaX = 0; pointer.deltaY = 0
end
function Input:endPointer(owner)
	local pointer = self.pointer
	if self.pointerOwner ~= owner or not pointer.down then return end
	-- Keep one pending release, like consumeBuffer; unused input cannot grow a queue.
	self.drop = {startX = pointer.startX, startY = pointer.startY,
		x = pointer.virtualX, y = pointer.virtualY, wasDrag = pointer.dragging, inside = pointer.inside}
	pointer.down = false; pointer.dragging = false; self.pointerOwner = nil
end
function Input:cancelPointer()
	local pointer = self.pointer
	if pointer.down then pointer.cancelled = true end
	pointer.down = false; pointer.dragging = false; self.pointerOwner = nil
	self.drop = nil
end
function Input:consumeDrop()
	local drop = self.drop; self.drop = nil; return drop
end
function Input:processTouchPointer(phase, event, processed)
	if phase == "Began" then
		if processed or not self.enabled or self.touchMode == "Off" or self.pointerTouch or self.pointer.down
			or (self.overlay and not self.overlay.Visible) then return end
		self:updatePointer(event.Position)
		if not self.pointer.inside then return end
		self.pointerTouch = event; self.pointerAction = if self.pointerSecondary then "secondary" else "primary"
		self:setSource(self.pointerAction, "TouchPointer", true)
		if self.pointerAction == "primary" then self:beginPointer(event) end
	elseif event == self.pointerTouch then
		self:updatePointer(event.Position)
		if phase == "Ended" then
			self:endPointer(event)
			self:setSource(self.pointerAction, "TouchPointer", false); self.pointerTouch = nil
		end
	end
end
function Input:setTouchMode(mode)
	assert(mode == "Auto" or mode == "On" or mode == "Off", "Invalid touch mode")
	if mode == "Off" and self.pointerTouch then
		self:cancelPointer(); self:setSource(self.pointerAction, "TouchPointer", false); self.pointerTouch = nil
	end
	self.touchMode = mode; self:updateTouchVisibility()
end
function Input:updateTouchVisibility()
	if not self.overlay then return end
	local kind = self.lastType or "Touch"
	local show = self.touchMode == "On" or (self.touchMode == "Auto" and self.uis.TouchEnabled and kind ~= "Keyboard" and not kind:match("^Gamepad") and not kind:match("^Mouse"))
	self.overlay.Visible = self.enabled and show
	if not self.overlay.Visible then
		for action, sources in self.sources do
			for source in sources do if type(source) ~= "string" or source:match("^Touch") then self:setSource(action, source, false) end end
		end
		if self.pointerTouch then self:cancelPointer() end
		self.moveTouch = nil; self.pointerTouch = nil
	end
end
function Input:setTouchDirection(dx, dy)
	local angle = math.atan2(dy, dx)
	local sector = math.floor(angle / (math.pi / 4) + .5)
	local x, y = 0, 0
	if dx * dx + dy * dy >= 14 * 14 then x = math.round(math.cos(sector * math.pi / 4)); y = math.round(math.sin(sector * math.pi / 4)) end
	if self.thumb then
        local distance = math.sqrt(dx * dx + dy * dy)
        local factor = if distance > 0 then math.min(distance, 38) / distance else 0
        self.thumb.Position = UDim2.new(.5, dx * factor, .5, dy * factor)
    end
    self:setSource("left", "TouchMove", x < 0); self:setSource("right", "TouchMove", x > 0)
	self:setSource("up", "TouchMove", y < 0); self:setSource("down", "TouchMove", y > 0)
end
function Input:_track(connection) table.insert(self.connections, connection) end
function Input:connect(config)
	self.uis = config.uis or game:GetService("UserInputService")
	local uis = self.uis
	for _, spec in {{"InputBegan", "Began"}, {"InputChanged", "Changed"}, {"InputEnded", "Ended"}} do
		self:_track(uis[spec[1]]:Connect(function(event, processed) self:process(spec[2], event, processed) end))
	end
	self:_track(uis.WindowFocusReleased:Connect(function() self:reset() end))
	self:_track(uis.GamepadDisconnected:Connect(function() self:reset() end))
	self.lastType = uis:GetLastInputType().Name
	self:_track(uis.LastInputTypeChanged:Connect(function(kind) self.lastType = kind.Name; self:updateTouchVisibility() end))
	if config.hud then self:mountTouch(config.hud, config.layout or "Platformer", config.actions or {{action = "jump", label = "Jump"}, {action = "dash", label = "Dash"}, {action = "grab", label = "Grab"}}) end
end
function Input:mountTouch(hud, layout, actions)
	self.layout = layout
	local overlay = Instance.new("Frame"); overlay.Name = "TouchControls"; overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundTransparency = 1; overlay.Parent = hud; self.overlay = overlay
	local function button(name, label, position, size)
		local b = Instance.new("TextButton"); b.Name = name; b.Text = label; b.TextSize = 12; b.Font = Enum.Font.GothamMedium
		b.TextColor3 = Color3.new(1, 1, 1); b.BackgroundColor3 = Color3.fromRGB(13, 20, 31)
		b.BackgroundTransparency = .35; b.BorderSizePixel = 0; b.Position = position; b.Size = size
		b.Selectable = false; b.ZIndex = 110; b.Parent = overlay
		local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(.5, 0); corner.Parent = b
        local border = Instance.new("UIStroke"); border.Color = Color3.fromRGB(211, 226, 240); border.Transparency = .55; border.Thickness = 1; border.Parent = b
        return b
	end
	if layout == "Pointer" then
		local toggle = button("RightClick", "Right click: off", UDim2.new(1, -150, 1, -64), UDim2.fromOffset(138, 50))
		self:_track(toggle.Activated:Connect(function()
			self.pointerSecondary = not self.pointerSecondary
			toggle.Text = if self.pointerSecondary then "Right click: on" else "Right click: off"
		end))
	else
		local zone = button("Move", "", UDim2.new(0, 18, 1, -158), UDim2.fromOffset(140, 140))
        zone.BackgroundTransparency = .8
        for _, cue in {{"▲", .5, .13}, {"▼", .5, .87}, {"◀", .13, .5}, {"▶", .87, .5}} do
            local arrow = Instance.new("TextLabel"); arrow.BackgroundTransparency = 1; arrow.Text = cue[1]
            arrow.TextSize = 12; arrow.TextColor3 = Color3.fromRGB(216, 228, 241); arrow.TextTransparency = .3
            arrow.Size = UDim2.fromOffset(20, 20); arrow.AnchorPoint = Vector2.new(.5, .5); arrow.Position = UDim2.fromScale(cue[2], cue[3]); arrow.ZIndex = 111; arrow.Parent = zone
        end
        local thumb = Instance.new("Frame"); thumb.Size = UDim2.fromOffset(42, 42); thumb.AnchorPoint = Vector2.new(.5, .5); thumb.Position = UDim2.fromScale(.5, .5)
        thumb.BackgroundColor3 = Color3.fromRGB(202, 224, 239); thumb.BackgroundTransparency = .5; thumb.BorderSizePixel = 0; thumb.ZIndex = 112; thumb.Parent = zone
        local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(1, 0); corner.Parent = thumb; self.thumb = thumb
		self:_track(zone.InputBegan:Connect(function(event)
			if event.UserInputType == Enum.UserInputType.Touch and overlay.Visible and not self.moveTouch then
				self.moveTouch = event
				local center = zone.AbsolutePosition + zone.AbsoluteSize / 2
				self:setTouchDirection(event.Position.X - center.X, event.Position.Y - center.Y)
			end
		end))
		self.moveZone = zone
		for i, spec in actions do
            local positions = {{-18, -20, 64}, {-82, -88, 58}, {-150, -34, 52}}
            local pos = positions[i] or {-18 - (i - 1) * 68, -20, 54}
            local b = button(spec.action, spec.label or spec.action, UDim2.new(1, pos[1], 1, pos[2]), UDim2.fromOffset(pos[3], pos[3]))
            b.AnchorPoint = Vector2.new(1, 1)

			self:_track(b.InputBegan:Connect(function(event)
				if event.UserInputType == Enum.UserInputType.Touch and overlay.Visible then
					self.touch[event] = spec.action; self:setSource(spec.action, event, true)
				end
			end))
		end
	end
	self:_track(self.uis.TouchMoved:Connect(function(event)
		if event == self.moveTouch then local center = self.moveZone.AbsolutePosition + self.moveZone.AbsoluteSize / 2; self:setTouchDirection(event.Position.X - center.X, event.Position.Y - center.Y) end
	end))
	self:_track(self.uis.TouchEnded:Connect(function(event)
		if event == self.moveTouch then self.moveTouch = nil; self:setTouchDirection(0, 0) end
		if self.touch[event] then self:setSource(self.touch[event], event, false); self.touch[event] = nil end
	end))
	self:updateTouchVisibility()
end
function Input:destroy()
	self:reset(); for _, connection in self.connections do connection:Disconnect() end; table.clear(self.connections)
	if self.overlay then self.overlay:Destroy() end
end
return Input
