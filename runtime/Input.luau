--!optimize 2
local Input = {}
Input.__index = Input
local function geometry(self,object)
    if typeof(object)~='Instance' then return object.AbsolutePosition,object.AbsoluteSize end
    local cache=self.geometryCache
    if not cache then cache=setmetatable({},{__mode='k'});self.geometryCache=cache end
    local entry=cache[object]
    if not entry then
        entry={position=object.AbsolutePosition,size=object.AbsoluteSize};cache[object]=entry
        entry.connections={
            object:GetPropertyChangedSignal('AbsolutePosition'):Connect(function()entry.position=object.AbsolutePosition end),
            object:GetPropertyChangedSignal('AbsoluteSize'):Connect(function()entry.size=object.AbsoluteSize end),
            object.AncestryChanged:Connect(function()
                if not object:IsDescendantOf(game) then
                    for _,connection in entry.connections do connection:Disconnect()end
                    cache[object]=nil
                end
            end)}
    end
    return entry.position,entry.size
end

local function normalizeContexts(spec)
	if spec == nil then return nil end
	local contexts = {}
	for key, value in spec do
		if type(key) == "number" then contexts[value] = true else contexts[key] = value == true end
	end
	return contexts
end
local function writeChanged(object, property, value)
	if object[property] ~= value then object[property] = value end
end

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
		touchLayout = config.touchLayout or {}, touchContext = config.touchContext or "default",
		touchMode = config.touchMode or "Auto", lastType = nil, uis = config.uis,
		gamepadStyle = "xbox", gamepadStyleOverride = config.gamepadStyleOverride,
		ControllerHasFocus = false, Attached = false, hapticService = config.hapticService, vibration = {}}, Input)
	if config.connect ~= false then self:connect(config) else self:refreshGamepadStyle() end
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
	self:setTouchDirection(0, 0); self:resetMoveZone()
end
function Input:setEnabled(value) self:reset(); self.enabled = value; self:updateTouchVisibility() end
function Input:axis(negative, positive, component)
	local digital = (if self:check(positive) then 1 else 0) - (if self:check(negative) then 1 else 0)
	if not self.enabled then return 0 end
	local analog = if component == "Y" then self.stick.Y else self.stick.X
	return if digital ~= 0 then digital else (if math.abs(analog) >= .25 then analog else 0)
end

-- XNA player indices are zero-based; Roblox gamepad types are one-based.
function Input:setVibration(index, left, right)
    if type(index) ~= "number" or index % 1 ~= 0 or index < 0 or index > 3 then return false end
    local pad = Enum.UserInputType["Gamepad" .. (index + 1)]
    local state = self.vibration[index]
    if not state then
        local service = self.hapticService
        if not service then
            local ok, result = pcall(function() return game:GetService("HapticService") end)
            if not ok then return false end
            service = result; self.hapticService = service
        end
        local ok, supported = pcall(function() return service:IsVibrationSupported(pad) end)
        state = {supported = ok and supported == true, left = 0, right = 0}
        self.vibration[index] = state
    end
    if not state.supported then return false end
    left = math.clamp(left, 0, 1); right = math.clamp(right, 0, 1)
    if left ~= state.left then
        local ok = pcall(function() self.hapticService:SetMotor(pad, Enum.VibrationMotor.Large, left) end)
        if ok then state.left = left end
    end
    if right ~= state.right then
        local ok = pcall(function() self.hapticService:SetMotor(pad, Enum.VibrationMotor.Small, right) end)
        if ok then state.right = right end
    end
    return true
end
function Input:stopVibration(index)
    if index ~= nil then
        if self.vibration[index] then self:setVibration(index, 0, 0) end
    else
        for padIndex in self.vibration do self:setVibration(padIndex, 0, 0) end
    end
end

function Input:refreshGamepadStyle()
	local ok, value = pcall(function() return self.uis:GetStringForKeyCode(Enum.KeyCode.ButtonA) end)
	self.gamepadStyle = if ok and value == "ButtonCross" then "ps" elseif ok and value == "ButtonB" then "switch" else "xbox"
end
function Input:getGamepadStyle() return self.gamepadStyleOverride or self.gamepadStyle end
function Input:setGamepadStyleOverride(style)
	assert(style == nil or style == "ps" or style == "xbox" or style == "switch", "Invalid gamepad style")
	self.gamepadStyleOverride = style
end
function Input:refreshGamepads()
	local ok, pads = pcall(function() return self.uis:GetConnectedGamepads() end)
	if ok then self.Attached = #pads > 0 end
	if not self.Attached then self.ControllerHasFocus = false end
	self:refreshGamepadStyle()
end

-- Same dispatch path is used for real events and deterministic regression tests.
function Input:process(phase, event, processed)
	local kind = event.UserInputType.Name
	if kind == "Touch" then
		if self.layout == "Pointer" then self:processTouchPointer(phase, event, processed) end
		return
	end
	local gamepad = kind:match("^Gamepad[1-8]$") ~= nil
	if kind ~= "Keyboard" and not gamepad and not kind:match("^Mouse") then return end
	if self.enabled and phase ~= "Ended" then
		if kind == "Keyboard" and phase == "Began" then self.ControllerHasFocus = false
		elseif gamepad then
			local keyName = event.KeyCode.Name
			local active = phase == "Began" or (phase == "Changed" and ((keyName:match("^Thumbstick") and (event.Position.X ^ 2 + event.Position.Y ^ 2 >= .25 ^ 2)) or ((keyName == "ButtonL2" or keyName == "ButtonR2") and event.Position.Z >= .25)))
			if active then self.ControllerHasFocus = true; self.Attached = true; self:refreshGamepadStyle() end
		end
	end
	-- Gameplay bindings remain assigned to the first gamepad.
	if gamepad and kind ~= "Gamepad1" then return end
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
	local p, size = geometry(self,self.canvas)
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
	writeChanged(self.overlay, "Visible", self.enabled and show)
	if not self.overlay.Visible then
		for action, sources in self.sources do
			for source in sources do if type(source) ~= "string" or source:match("^Touch") then self:setSource(action, source, false) end end
		end
		if self.pointerTouch then self:cancelPointer() end
		self.moveTouch = nil; self.pointerTouch = nil; table.clear(self.touch)
		self:setTouchDirection(0, 0); self:resetMoveZone()
	end
end
function Input:getTouchContext() return self.touchContext end
function Input:setTouchContext(context)
	assert(type(context) == "string" and context ~= "", "Invalid touch context")
	if self.touchContext == context then return end
	self.touchContext = context; self:applyTouchContext()
end
function Input:setActionVisible(action, visible)
	assert(visible == nil or type(visible) == "boolean", "Invalid visibility override")
	for _, entry in self.touchButtons or {} do
		if entry.action == action then entry.visibleOverride = visible end
	end
	self:applyTouchContext()
end
function Input:setActionLabel(action, label)
	assert(label == nil or type(label) == "string", "Invalid label override")
	for _, entry in self.touchButtons or {} do
		if entry.action == action then entry.labelOverride = label end
	end
	self:applyTouchContext()
end
function Input:resolveMoveAxes()
	local axes = self.touchLayout.moveAxes
	if type(axes) == "string" then return axes end
	if type(axes) == "table" then return axes[self.touchContext] or axes.default or "XY" end
	return "XY"
end
function Input:resetMoveZone()
	self.moveOrigin = nil
	if self.moveZone and self.touchLayout.moveMode == "Dynamic" then
		writeChanged(self.moveZone, "Position", self.moveHomePosition)
		writeChanged(self.moveZone, "BackgroundTransparency", .86)
		writeChanged(self.moveZone, "Visible", self.moveVisible == true and not self.touchLayout.hideIdleMove)
	end
end
function Input:applyTouchContext()
	for _, entry in self.touchButtons or {} do
		local visible = if entry.visibleOverride ~= nil then entry.visibleOverride else (entry.contexts == nil or entry.contexts[self.touchContext] == true)
		local text = entry.labelOverride or (entry.labels and entry.labels[self.touchContext]) or entry.defaultLabel
		writeChanged(entry.button, "Visible", visible)
		writeChanged(entry.button, "Text", text)
		if not visible then
			for ev, action in self.touch do
				if action == entry.action then self:setTouchAction(ev, nil) end
			end
		end
	end
	local moveVisible = self.moveContexts == nil or self.moveContexts[self.touchContext] == true
	self.moveVisible = moveVisible
	if self.moveArea then writeChanged(self.moveArea, "Visible", moveVisible) end
	if self.moveZone then
		writeChanged(self.moveZone, "Visible", moveVisible and (self.touchLayout.moveMode ~= "Dynamic" or self.moveTouch ~= nil or not self.touchLayout.hideIdleMove))
	end
	local axes = self:resolveMoveAxes()
	for direction, arrow in self.moveArrows or {} do
		local vertical = direction == "up" or direction == "down"
		writeChanged(arrow, "Visible", if vertical then axes ~= "X" else axes ~= "Y")
	end
	if not moveVisible then
		self.moveTouch = nil; self:setTouchDirection(0, 0); self:resetMoveZone()
	else
		self:setTouchDirection(self.lastMoveDx or 0, self.lastMoveDy or 0)
	end
end
function Input:setTouchDirection(dx, dy)
	self.lastMoveDx, self.lastMoveDy = dx, dy
	local axes = self:resolveMoveAxes()
	local deadzone, radius = self.touchLayout.moveDeadzone or 14, self.touchLayout.moveRadius or 38
	local x, y, tx, ty = 0, 0, 0, 0
	if axes == "X" then
		x = if math.abs(dx) >= deadzone then (if dx > 0 then 1 else -1) else 0
		tx = math.clamp(dx, -radius, radius)
	elseif axes == "Y" then
		y = if math.abs(dy) >= deadzone then (if dy > 0 then 1 else -1) else 0
		ty = math.clamp(dy, -radius, radius)
	else
		local angle = math.atan2(dy, dx)
		local sector = math.floor(angle / (math.pi / 4) + .5)
		if dx * dx + dy * dy >= deadzone * deadzone then x = math.round(math.cos(sector * math.pi / 4)); y = math.round(math.sin(sector * math.pi / 4)) end
		local distance = math.sqrt(dx * dx + dy * dy)
		local factor = if distance > 0 then math.min(distance, radius) / distance else 0
		tx, ty = dx * factor, dy * factor
	end
	if self.thumb then writeChanged(self.thumb, "Position", UDim2.new(.5, tx, .5, ty)) end
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
	if uis.GamepadConnected then self:_track(uis.GamepadConnected:Connect(function(pad)
        local index = pad and tonumber(pad.Name:match("^Gamepad([1-4])$"))
        if index then self.vibration[index - 1] = nil end
        self:refreshGamepads()
    end)) end
	self:_track(uis.GamepadDisconnected:Connect(function(pad)
        local index = pad and tonumber(pad.Name:match("^Gamepad([1-4])$"))
        if index then self:stopVibration(index - 1); self.vibration[index - 1] = nil end
        self:reset(); self:refreshGamepads()
    end))
	self:refreshGamepads()
	self.lastType = uis:GetLastInputType().Name
	self:_track(uis.LastInputTypeChanged:Connect(function(kind) self.lastType = kind.Name; if self.lastType:match("^Gamepad[1-8]$") then self:refreshGamepadStyle() end; self:updateTouchVisibility() end))
	if config.hud then self:mountTouch(config.hud, config.layout or "Platformer", config.actions or {{action = "jump", label = "Jump"}, {action = "dash", label = "Dash"}, {action = "grab", label = "Grab"}}) end
end
function Input:setTouchAction(event, action)
	local previous = self.touch[event]
	if previous == action then return end
	if previous then self:setSource(previous, event, false) end
	self.touch[event] = action
	if action then self:setSource(action, event, true) end
end
function Input:moveTouchAction(event)
	if self.touch[event] == nil then return end
	local action
	for _, entry in self.touchButtons or {} do
		if entry.button.Visible == false then continue end
		local p, size = geometry(self,entry.button)
		if event.Position.X >= p.X and event.Position.X < p.X + size.X and event.Position.Y >= p.Y and event.Position.Y < p.Y + size.Y then
			action = entry.action; break
		end
	end
	-- Retain ownership after leaving a button so sliding back onto one works.
	self:setTouchAction(event, action or false)
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
		local dynamic = self.touchLayout.moveMode == "Dynamic"
		self.moveContexts = normalizeContexts(self.touchLayout.moveContexts)
		local zone = button("Move", "", self.touchLayout.movePosition or (if dynamic then UDim2.new(0, 88, 1, -88) else UDim2.new(0, 18, 1, -158)), self.touchLayout.moveSize or UDim2.fromOffset(if dynamic then 128 else 140, if dynamic then 128 else 140))
		zone.BackgroundTransparency = if dynamic then .86 else .8
		if dynamic then zone.AnchorPoint = Vector2.new(.5, .5); zone.Active = false end
		self.moveHomePosition = zone.Position
		local capture = zone
		if dynamic then
			local moveArea = Instance.new("TextButton"); moveArea.Name = "MoveArea"; moveArea.Text = ""
			moveArea.BackgroundTransparency = 1; moveArea.BorderSizePixel = 0
			moveArea.Position = self.touchLayout.moveAreaPosition or UDim2.new(0, 0, .16, 0)
			moveArea.Size = self.touchLayout.moveAreaSize or UDim2.new(.48, 0, .84, 0)
			moveArea.ZIndex = 109; moveArea.Selectable = false; moveArea.Parent = overlay
			self.moveArea = moveArea; capture = moveArea
		end
		self.moveArrows = {}
		for _, cue in {{"▲", .5, .13, "up"}, {"▼", .5, .87, "down"}, {"◀", .13, .5, "left"}, {"▶", .87, .5, "right"}} do
			local arrow = Instance.new("TextLabel"); arrow.BackgroundTransparency = 1; arrow.Text = cue[1]
			arrow.TextSize = 12; arrow.TextColor3 = Color3.fromRGB(216, 228, 241); arrow.TextTransparency = .3
			arrow.Size = UDim2.fromOffset(20, 20); arrow.AnchorPoint = Vector2.new(.5, .5); arrow.Position = UDim2.fromScale(cue[2], cue[3]); arrow.ZIndex = 111; arrow.Parent = zone
			self.moveArrows[cue[4]] = arrow
		end
        local thumb = Instance.new("Frame"); thumb.Size = UDim2.fromOffset(42, 42); thumb.AnchorPoint = Vector2.new(.5, .5); thumb.Position = UDim2.fromScale(.5, .5)
        thumb.BackgroundColor3 = Color3.fromRGB(202, 224, 239); thumb.BackgroundTransparency = .5; thumb.BorderSizePixel = 0; thumb.ZIndex = 112; thumb.Parent = zone
        local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(1, 0); corner.Parent = thumb; self.thumb = thumb
		self:_track(capture.InputBegan:Connect(function(event)
			if event.UserInputType == Enum.UserInputType.Touch and overlay.Visible and capture.Visible ~= false and not self.moveTouch then
				self.moveTouch = event
				if dynamic then
					self.moveOrigin = Vector2.new(event.Position.X, event.Position.Y)
					local overlayPos = geometry(self, overlay)
					writeChanged(zone, "Position", UDim2.fromOffset(self.moveOrigin.X - overlayPos.X, self.moveOrigin.Y - overlayPos.Y))
					writeChanged(zone, "BackgroundTransparency", .72); writeChanged(zone, "Visible", true)
					self:setTouchDirection(0, 0)
				else
					local position, size = geometry(self, zone); local center = position + size / 2
					self:setTouchDirection(event.Position.X - center.X, event.Position.Y - center.Y)
				end
			end
		end))
		self.moveZone = zone
		self.touchButtons = {}
		local positions = {{-18, -20, 64}, {-82, -88, 58}, {-150, -34, 52}, {-18, -158, 46}}
		for i, spec in actions do
            local pos = positions[i] or {-18 - (i - 1) * 68, -20, 54}
            local b = button(spec.action, spec.label or spec.action, spec.position or UDim2.new(1, pos[1], 1, pos[2]), spec.size or UDim2.fromOffset(pos[3], pos[3]))
            b.AnchorPoint = spec.anchorPoint or Vector2.new(1, 1)
			b.TextSize = spec.textSize or 12
			table.insert(self.touchButtons, {button = b, action = spec.action, defaultLabel = spec.label or spec.action,
				labels = spec.labels, contexts = normalizeContexts(spec.contexts), visibleOverride = spec.visible, labelOverride = nil})

			self:_track(b.InputBegan:Connect(function(event)
				if event.UserInputType == Enum.UserInputType.Touch and overlay.Visible and b.Visible ~= false then
					self:setTouchAction(event, spec.action)
				end
			end))
		end
	end
	self:_track(self.uis.TouchMoved:Connect(function(event)
		if event == self.moveTouch then
			if self.touchLayout.moveMode == "Dynamic" then
				local ox, oy = self.moveOrigin.X, self.moveOrigin.Y
				local dx, dy = event.Position.X - ox, event.Position.Y - oy
				if self.touchLayout.dynamicFollow ~= false then
					local radius, axes = self.touchLayout.moveRadius or 38, self:resolveMoveAxes()
					if axes == "X" then
						if math.abs(dx) > radius then ox = event.Position.X - (if dx > 0 then radius else -radius) end
						oy = event.Position.Y
					elseif axes == "Y" then
						if math.abs(dy) > radius then oy = event.Position.Y - (if dy > 0 then radius else -radius) end
						ox = event.Position.X
					else
						local dist = math.sqrt(dx * dx + dy * dy)
						if dist > radius then local scale = radius / dist; ox = event.Position.X - dx * scale; oy = event.Position.Y - dy * scale end
					end
					if ox ~= self.moveOrigin.X or oy ~= self.moveOrigin.Y then
						self.moveOrigin = Vector2.new(ox, oy)
						local overlayPos = geometry(self, self.overlay)
						writeChanged(self.moveZone, "Position", UDim2.fromOffset(ox - overlayPos.X, oy - overlayPos.Y))
					end
					dx, dy = event.Position.X - ox, event.Position.Y - oy
				end
				self:setTouchDirection(dx, dy)
			else
				local position, size = geometry(self, self.moveZone); local center = position + size / 2
				self:setTouchDirection(event.Position.X - center.X, event.Position.Y - center.Y)
			end
		elseif self.touch[event] ~= nil then self:moveTouchAction(event) end
	end))
	self:_track(self.uis.TouchEnded:Connect(function(event)
		if event == self.moveTouch then self.moveTouch = nil; self:setTouchDirection(0, 0); self:resetMoveZone() end
		if self.touch[event] ~= nil then self:setTouchAction(event, nil) end
	end))
	self:applyTouchContext()
	self:updateTouchVisibility()
end
function Input:destroy()
	for _,entry in self.geometryCache or {} do for _,connection in entry.connections do connection:Disconnect()end end
	self.geometryCache=nil
	self:stopVibration(); self:reset(); for _, connection in self.connections do connection:Disconnect() end; table.clear(self.connections)
	if self.overlay then self.overlay:Destroy() end
end
return Input
