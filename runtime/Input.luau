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
local function wakeTouch(self)
	if self.lastType ~= "Touch" then
		self.lastType = "Touch"
		self:updateTouchVisibility()
	end
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
		canvas = config.canvas, canvasScale = config.canvasScale, virtualSize = config.virtualSize, dragDeadzone = deadzone,
		layout = config.layout or "Platformer", pointerSecondary = false,
		touchLayout = config.touchLayout or {}, touchContext = config.touchContext or "default",
		touchMode = config.touchMode or "Auto", lastType = nil, uis = config.uis,
		gamepadStyle = "xbox", gamepadStyleOverride = config.gamepadStyleOverride,
		ControllerHasFocus = false, Attached = false, hapticService = config.hapticService, vibration = {}}, Input)
	self.pointerContextSpec = self.touchLayout.pointerContexts
	self.pointerContexts = normalizeContexts(self.pointerContextSpec)
	self.moveMode = self:resolveMoveMode()
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
	if self.dpadTouches then table.clear(self.dpadTouches) end
	table.clear(self.sources); table.clear(self.presses); table.clear(self.toggled); table.clear(self.touch)
	self.stick = Vector2.zero; self.moveTouch = nil; self.pointerTouch = nil
	self:refreshActionVisuals(); self:refreshDpadVisuals()
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
		if phase == "Began" and self.enabled and self.touchMode ~= "Off" then wakeTouch(self) end
		if self:isTouchPointerEnabled() and event ~= self.moveTouch and self.touch[event] == nil
			and (not self.dpadTouches or self.dpadTouches[event] == nil) then
			self:processTouchPointer(phase, event, processed)
		end
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
	if self.virtualSize then
		pointer.virtualX = x * self.virtualSize.X; pointer.virtualY = y * self.virtualSize.Y
	else
		pointer.virtualX = (position.X - p.X) / math.max(1e-6, scale)
		pointer.virtualY = (position.Y - p.Y) / math.max(1e-6, scale)
	end
	pointer.inside = x >= 0 and x <= 1 and y >= 0 and y <= 1
	if pointer.down then
		pointer.deltaX = pointer.virtualX - pointer.startX; pointer.deltaY = pointer.virtualY - pointer.startY
		if pointer.deltaX ^ 2 + pointer.deltaY ^ 2 > self.dragDeadzone ^ 2 then pointer.dragging = true end
	end
end
function Input:beginPointer(owner)
	local pointer = self.pointer
	if not self.enabled or pointer.down or (not pointer.inside and (owner == "MouseButton1" or not self:allowsOutsidePointer())) then return end
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
function Input:isTouchPointerEnabled()
	return self.layout == "Pointer" or (self.pointerContexts ~= nil and self.pointerContexts[self.touchContext] == true)
end
function Input:allowsOutsidePointer()
	local spec = self.touchLayout.allowOutsidePointer
	if type(spec) == "boolean" then return spec end
	if type(spec) == "table" then return spec[self.touchContext] == true or (spec[self.touchContext] == nil and spec.default == true) end
	return false
end
-- GUI and service events can arrive in either order; a control owns its finger.
function Input:claimControlTouch(event)
	if self.pointerTouch == event then
		self:cancelPointer(); self:setSource(self.pointerAction, "TouchPointer", false); self.pointerTouch = nil
	end
end
function Input:processTouchPointer(phase, event, processed)
	if phase == "Began" then
		if processed or not self.enabled or self.touchMode == "Off" or self.pointerTouch or self.pointer.down
			or (self.overlay and not self.overlay.Visible) then return end
		self:updatePointer(event.Position)
		if not self.pointer.inside and not self:allowsOutsidePointer() then return end
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
	local ignoreKeyboard = self.uis.KeyboardEnabled == false
	local ignoreMouse = self.uis.MouseEnabled == false
	local show = self.touchMode == "On" or (self.touchMode == "Auto" and self.uis.TouchEnabled
		and (ignoreKeyboard or kind ~= "Keyboard")
		and not kind:match("^Gamepad")
		and (ignoreMouse or not kind:match("^Mouse")))
	writeChanged(self.overlay, "Visible", self.enabled and show)
	if not self.overlay.Visible then
		for action, sources in self.sources do
			for source in sources do if type(source) ~= "string" or source:match("^Touch") then self:setSource(action, source, false) end end
		end
		if self.pointerTouch then self:cancelPointer() end
		self.moveTouch = nil; self.pointerTouch = nil; table.clear(self.touch)
		if self.dpadTouches then table.clear(self.dpadTouches) end
		self:refreshActionVisuals(); self:refreshDpadVisuals()
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
function Input:resolveMoveArrows()
	local arrows = self.touchLayout.moveArrows
	if type(arrows) == "string" then return arrows end
	if type(arrows) == "table" then return arrows[self.touchContext] or arrows.default or self:resolveMoveAxes() end
	return self:resolveMoveAxes()
end
function Input:resolveFreeThumb()
	local free = self.touchLayout.freeThumb
	if type(free) == "boolean" then return free end
	if type(free) == "table" then return free[self.touchContext] == true or (free[self.touchContext] == nil and free.default == true) end
	return false
end
function Input:resolveMoveMode()
	local modes = self.touchLayout.moveModes
	if type(modes) == "table" then return modes[self.touchContext] or modes.default or self.touchLayout.moveMode or "Fixed" end
	return self.touchLayout.moveMode or "Fixed"
end
function Input:refreshDpadVisuals()
	if not self.dpadArms or not self.theme then return end
	local t = self.theme
	local held = {}
	for _, dir in self.dpadTouches or {} do if dir then held[dir] = true end end
	for dir, arm in self.dpadArms do
		local active = held[dir] == true
		writeChanged(arm.cap, "BackgroundColor3", if active then t.glassActive else t.glassIdle)
		writeChanged(arm.cap, "BackgroundTransparency", if active then .10 else .28)
		writeChanged(arm.stroke, "Transparency", if active then .28 else .82)
		for _, bar in arm.bars do writeChanged(bar, "BackgroundTransparency", if active then .02 else .32) end
	end
end
function Input:refreshActionVisuals()
	if not self.touchButtons or not self.theme then return end
	local t = self.theme
	local held = {}
	for _, act in self.touch or {} do if act then held[act] = true end end
	for _, entry in self.touchButtons do
		local active = held[entry.action] == true
		writeChanged(entry.button, "BackgroundColor3", if active then t.glassActive else t.glassIdle)
		writeChanged(entry.button, "BackgroundTransparency", if active then .12 else .28)
		if entry.stroke then writeChanged(entry.stroke, "Transparency", if active then .26 else .82) end
		if entry.cap then writeChanged(entry.cap, "BackgroundTransparency", if active then .86 else .96) end
	end
end
function Input:refreshMoveVisuals(x, y)
	if not self.theme then return end
	local t = self.theme
	local grabbing = self.moveTouch ~= nil
	if self.moveZone and self:resolveMoveMode() ~= "Dynamic" then
		writeChanged(self.moveZone, "BackgroundColor3", t.glassIdle)
		writeChanged(self.moveZone, "BackgroundTransparency", if grabbing then .48 else .56)
	end
	if self.moveStroke then writeChanged(self.moveStroke, "Transparency", if grabbing then .74 else .86) end
	if self.thumb then
		writeChanged(self.thumb, "BackgroundColor3", if grabbing then t.thumbActive else t.thumbIdle)
		writeChanged(self.thumb, "BackgroundTransparency", if grabbing then .18 else .32)
	end
	if self.thumbStroke then writeChanged(self.thumbStroke, "Transparency", if grabbing then .50 else .74) end
	if self.moveArrowBars then
		local dirs = {left = (x or 0) < 0, right = (x or 0) > 0, up = (y or 0) < 0, down = (y or 0) > 0}
		for dir, bars in self.moveArrowBars do
			local tr = if dirs[dir] then .32 else .68
			for _, bar in bars do writeChanged(bar, "BackgroundTransparency", tr) end
		end
	end
end
function Input:setDpadTouch(event, direction)
	local previous = self.dpadTouches[event]
	if previous == direction then return end
	if previous then self:setSource(previous, event, false) end
	self.dpadTouches[event] = direction
	if direction then self:claimControlTouch(event); self:setSource(direction, event, true) end
	self:refreshDpadVisuals()
end
function Input:moveDpadTouch(event)
	for direction, button in self.dpadButtons do
		if self.dpad.Visible and button.Visible then
			local p, size = geometry(self, button)
			if event.Position.X >= p.X and event.Position.X < p.X + size.X and event.Position.Y >= p.Y and event.Position.Y < p.Y + size.Y then
				self:setDpadTouch(event, direction); return
			end
		end
	end
	self:setDpadTouch(event, false)
end
function Input:resetMoveZone()
	self.moveOrigin = nil
	if self.moveZone and self:resolveMoveMode() == "Dynamic" then
		writeChanged(self.moveZone, "Position", self.moveHomePosition)
		writeChanged(self.moveZone, "BackgroundTransparency", .86)
		writeChanged(self.moveZone, "Visible", self.moveVisible == true and not self.touchLayout.hideIdleMove)
	end
end
function Input:applyTouchContext()
	-- Normalize only when the configuration reference changes, not per gesture.
	if self.pointerContextSpec ~= self.touchLayout.pointerContexts then
		self.pointerContextSpec = self.touchLayout.pointerContexts
		self.pointerContexts = normalizeContexts(self.pointerContextSpec)
	end
	if not self:isTouchPointerEnabled() and self.pointerTouch ~= nil then
		self:cancelPointer(); self:setSource(self.pointerAction, "TouchPointer", false); self.pointerTouch = nil
	end
	for _, entry in self.touchButtons or {} do
		local visible = if entry.visibleOverride ~= nil then entry.visibleOverride else (entry.contexts == nil or entry.contexts[self.touchContext] == true)
		local text = entry.labelOverride or (entry.labels and entry.labels[self.touchContext]) or entry.defaultLabel
		writeChanged(entry.button, "Visible", visible)
		writeChanged(entry.button, "Text", text)
		if entry.pauseIcon then
			local isPauseGlyph = text == "II" or text == "?"
			writeChanged(entry.pauseIcon, "Visible", isPauseGlyph)
			writeChanged(entry.button, "TextTransparency", if isPauseGlyph then 1 else 0)
		end
		if not visible then
			for ev, action in self.touch do
				if action == entry.action then self:setTouchAction(ev, nil) end
			end
		end
	end
	local moveVisible = self.moveContexts == nil or self.moveContexts[self.touchContext] == true
	local mode, axes = self:resolveMoveMode(), self:resolveMoveAxes()
	local changedMode = self.moveMode ~= mode
	self.moveVisible = moveVisible
	if changedMode then
		self.moveMode = mode; self.moveTouch = nil; self.moveOrigin = nil
		self:setTouchDirection(0, 0)
		if self.moveZone then
			local dynamic = mode == "Dynamic"
			self.moveHomePosition = self.touchLayout.movePosition or (if dynamic then UDim2.new(0, 88, 1, -88) else UDim2.new(0, 18, 1, -158))
			writeChanged(self.moveZone, "Position", self.moveHomePosition)
			writeChanged(self.moveZone, "Size", self.touchLayout.moveSize or UDim2.fromOffset(if dynamic then 128 else 140, if dynamic then 128 else 140))
			writeChanged(self.moveZone, "AnchorPoint", if dynamic then Vector2.new(.5, .5) else Vector2.zero)
			writeChanged(self.moveZone, "Active", not dynamic)
			writeChanged(self.moveZone, "BackgroundTransparency", if dynamic then .86 else .56)
		end
	end
	if self.moveArea then writeChanged(self.moveArea, "Visible", moveVisible and mode == "Dynamic") end
	if self.moveZone then
		writeChanged(self.moveZone, "Visible", moveVisible and mode ~= "Dpad" and (mode ~= "Dynamic" or self.moveTouch ~= nil or not self.touchLayout.hideIdleMove))
	end
	if self.dpad then writeChanged(self.dpad, "Visible", moveVisible and mode == "Dpad") end
	for direction, button in self.dpadButtons or {} do
		local vertical = direction == "up" or direction == "down"
		local visible = moveVisible and mode == "Dpad" and (if vertical then axes ~= "X" else axes ~= "Y")
		writeChanged(button, "Visible", visible)
		if self.dpadArms and self.dpadArms[direction] then writeChanged(self.dpadArms[direction].clip, "Visible", visible) end
		if not visible then
			for event, held in self.dpadTouches do if held == direction then self:setDpadTouch(event, nil) end end
		end
	end
	if self.dpadHubEdges then
		local showH = moveVisible and mode == "Dpad" and axes == "X"
		local showV = moveVisible and mode == "Dpad" and axes == "Y"
		writeChanged(self.dpadHubEdges.top, "Visible", showH); writeChanged(self.dpadHubEdges.bottom, "Visible", showH)
		writeChanged(self.dpadHubEdges.left, "Visible", showV); writeChanged(self.dpadHubEdges.right, "Visible", showV)
	end
	if changedMode or not moveVisible or mode ~= "Dpad" then
		for event in self.dpadTouches or {} do self:setDpadTouch(event, nil) end
	end
	local arrowAxes = self:resolveMoveArrows()
	for direction, arrow in self.moveArrows or {} do
		local vertical = direction == "up" or direction == "down"
		writeChanged(arrow, "Visible", if vertical then arrowAxes ~= "X" else arrowAxes ~= "Y")
	end
	if not moveVisible or mode == "Dpad" then
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
	elseif axes == "Cardinal" then
		if dx * dx + dy * dy >= deadzone * deadzone then
			if math.abs(dx) >= math.abs(dy) then x = if dx > 0 then 1 else -1; tx = math.clamp(dx, -radius, radius)
			else y = if dy > 0 then 1 else -1; ty = math.clamp(dy, -radius, radius) end
		end
	else
		local angle = math.atan2(dy, dx)
		local sector = math.floor(angle / (math.pi / 4) + .5)
		if dx * dx + dy * dy >= deadzone * deadzone then x = math.round(math.cos(sector * math.pi / 4)); y = math.round(math.sin(sector * math.pi / 4)) end
		local distance = math.sqrt(dx * dx + dy * dy)
		local factor = if distance > 0 then math.min(distance, radius) / distance else 0
		tx, ty = dx * factor, dy * factor
	end
	if self:resolveFreeThumb() then
		local distance = math.sqrt(dx * dx + dy * dy)
		local factor = if distance > 0 then math.min(distance, radius) / distance else 0
		tx, ty = dx * factor, dy * factor
	end
	if self.thumb then writeChanged(self.thumb, "Position", UDim2.new(.5, tx, .5, ty)) end
	self:setSource("left", "TouchMove", x < 0); self:setSource("right", "TouchMove", x > 0)
	self:setSource("up", "TouchMove", y < 0); self:setSource("down", "TouchMove", y > 0)
	self:refreshMoveVisuals(x, y)
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
	if action then self:claimControlTouch(event); self:setSource(action, event, true) end
	self:refreshActionVisuals()
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
	self.pointerContextSpec = self.touchLayout.pointerContexts
	self.pointerContexts = normalizeContexts(self.pointerContextSpec)
	local t = {
		glassIdle = Color3.fromRGB(18, 18, 21),
		glassActive = Color3.fromRGB(48, 50, 58),
		text = Color3.fromRGB(246, 247, 250),
		white = Color3.new(1, 1, 1),
		thumbIdle = Color3.fromRGB(34, 36, 42),
		thumbActive = Color3.fromRGB(52, 55, 64),
	}
	self.theme = t; self.touchTheme = "SmokedGlass"
	local boldFont = (Enum.Font and Enum.Font.GothamBold) or Enum.Font.GothamMedium
	local borderMode = Enum.ApplyStrokeMode and Enum.ApplyStrokeMode.Border
	local overlay = Instance.new("Frame"); overlay.Name = "TouchControls"; overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundTransparency = 1; overlay.Parent = hud; self.overlay = overlay
	local function addStroke(parent, color, transparency, thickness)
		local s = Instance.new("UIStroke"); s.Color = color; s.Transparency = transparency; s.Thickness = thickness or 1
		if borderMode then s.ApplyStrokeMode = borderMode end
		s.Parent = parent; return s
	end
	local chevronSpecs = {
		up = {{.375, .5, -45}, {.625, .5, 45}},
		down = {{.375, .5, 45}, {.625, .5, -45}},
		left = {{.5, .375, -45}, {.5, .625, 45}},
		right = {{.5, .375, 45}, {.5, .625, -45}},
	}
	local function makeChevron(parent, direction, pos, zIndex, barTrans)
		local holder = Instance.new("Frame"); holder.Name = "Chevron_" .. direction; holder.BackgroundTransparency = 1
		holder.Size = UDim2.fromOffset(20, 20); holder.AnchorPoint = Vector2.new(.5, .5); holder.Position = pos
		holder.ZIndex = zIndex; holder.Parent = parent
		local bars = {}
		for _, arm in chevronSpecs[direction] do
			local bar = Instance.new("Frame"); bar.Size = UDim2.fromOffset(8, 2); bar.AnchorPoint = Vector2.new(.5, .5)
			bar.Position = UDim2.fromScale(arm[1], arm[2]); bar.Rotation = arm[3]
			bar.BackgroundColor3 = t.text; bar.BackgroundTransparency = barTrans; bar.BorderSizePixel = 0
			bar.ZIndex = zIndex; bar.Parent = holder
			local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = bar
			bars[#bars + 1] = bar
		end
		return holder, bars
	end
	local function button(name, label, position, size)
		local h = size.Y.Offset
		local defaultTextSize = if h >= 84 then 16 elseif h >= 60 then 14 elseif h >= 50 then 13 else 12
		local b = Instance.new("TextButton"); b.Name = name; b.Text = label; b.TextSize = defaultTextSize; b.Font = boldFont
		b.AutoButtonColor = false; b.TextColor3 = t.text; b.BackgroundColor3 = t.glassIdle
		b.BackgroundTransparency = .28; b.BorderSizePixel = 0; b.Position = position; b.Size = size
		b.Selectable = false; b.ZIndex = 110; b.Parent = overlay
		local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(.5, 0); corner.Parent = b
		local stroke = addStroke(b, t.white, .82, 1)
		local cap = Instance.new("Frame"); cap.Name = "InnerCap"; cap.Size = UDim2.new(1, -6, 1, -6)
		cap.Position = UDim2.fromScale(.5, .5); cap.AnchorPoint = Vector2.new(.5, .5)
		cap.BackgroundColor3 = t.white; cap.BackgroundTransparency = .96; cap.BorderSizePixel = 0; cap.ZIndex = 110; cap.Parent = b
		local capCorner = Instance.new("UICorner"); capCorner.CornerRadius = UDim.new(.5, 0); capCorner.Parent = cap
		return b, stroke, cap
	end
	if layout == "Pointer" then
		local toggle = button("RightClick", "Right click: off", UDim2.new(1, -150, 1, -64), UDim2.fromOffset(138, 50))
		self:_track(toggle.Activated:Connect(function()
			self.pointerSecondary = not self.pointerSecondary
			toggle.Text = if self.pointerSecondary then "Right click: on" else "Right click: off"
		end))
	else
		local dynamic = self:resolveMoveMode() == "Dynamic"
		local hasDynamic, hasDpad = self.touchLayout.moveMode == "Dynamic", self.touchLayout.moveMode == "Dpad"
		if type(self.touchLayout.moveModes) == "table" then
			for _, mode in self.touchLayout.moveModes do
				hasDynamic = hasDynamic or mode == "Dynamic"; hasDpad = hasDpad or mode == "Dpad"
			end
		end
		self.moveContexts = normalizeContexts(self.touchLayout.moveContexts)
		local zone, zoneStroke, zoneCap = button("Move", "", self.touchLayout.movePosition or (if dynamic then UDim2.new(0, 88, 1, -88) else UDim2.new(0, 18, 1, -158)), self.touchLayout.moveSize or UDim2.fromOffset(if dynamic then 128 else 140, if dynamic then 128 else 140))
		zoneCap:Destroy(); zoneStroke.Transparency = .86; self.moveStroke = zoneStroke
		zone.BackgroundTransparency = if dynamic then .86 else .56
		if dynamic then zone.AnchorPoint = Vector2.new(.5, .5); zone.Active = false end
		self.moveHomePosition = zone.Position
		if hasDynamic then
			local moveArea = Instance.new("TextButton"); moveArea.Name = "MoveArea"; moveArea.Text = ""; moveArea.AutoButtonColor = false
			moveArea.BackgroundTransparency = 1; moveArea.BorderSizePixel = 0
			moveArea.Position = self.touchLayout.moveAreaPosition or UDim2.new(0, 0, .16, 0)
			moveArea.Size = self.touchLayout.moveAreaSize or UDim2.new(.48, 0, .84, 0)
			moveArea.ZIndex = 109; moveArea.Selectable = false; moveArea.Parent = overlay
			self.moveArea = moveArea
		end
		self.moveArrows = {}; self.moveArrowBars = {}
		for _, cue in {{.5, .12, "up"}, {.5, .88, "down"}, {.12, .5, "left"}, {.88, .5, "right"}} do
			local holder, bars = makeChevron(zone, cue[3], UDim2.fromScale(cue[1], cue[2]), 111, .68)
			self.moveArrows[cue[3]] = holder; self.moveArrowBars[cue[3]] = bars
		end
		local thumb = Instance.new("Frame"); thumb.Name = "Thumb"; thumb.Size = UDim2.fromOffset(44, 44); thumb.AnchorPoint = Vector2.new(.5, .5); thumb.Position = UDim2.fromScale(.5, .5)
		thumb.BackgroundColor3 = t.thumbIdle; thumb.BackgroundTransparency = .32; thumb.BorderSizePixel = 0; thumb.ZIndex = 112; thumb.Parent = zone
		local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(1, 0); corner.Parent = thumb; self.thumb = thumb
		self.thumbStroke = addStroke(thumb, t.white, .74, 1)
		local function beginMove(event, capture, dynamic)
			if event.UserInputType == Enum.UserInputType.Touch and self.enabled and self.touchMode ~= "Off" then wakeTouch(self) end
			if event.UserInputType == Enum.UserInputType.Touch and overlay.Visible and capture.Visible ~= false and not self.moveTouch then
				self:claimControlTouch(event); self.moveTouch = event
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
		end
		self:_track(zone.InputBegan:Connect(function(event)
			if self:resolveMoveMode() == "Fixed" then beginMove(event, zone, false) end
		end))
		if self.moveArea then self:_track(self.moveArea.InputBegan:Connect(function(event)
			if self:resolveMoveMode() == "Dynamic" then beginMove(event, self.moveArea, true) end
		end)) end
		if hasDpad then
			local dpad = Instance.new("Frame"); dpad.Name = "Dpad"; dpad.BackgroundTransparency = 1
			dpad.Position = self.touchLayout.dpadPosition or UDim2.new(0, 18, 1, -158)
			dpad.Size = self.touchLayout.dpadSize or UDim2.fromOffset(140, 140); dpad.Parent = overlay
			self.dpad = dpad; self.dpadTouches = {}; self.dpadButtons = {}; self.dpadArms = {}
			local hub = Instance.new("Frame"); hub.Name = "CrossHub"; hub.Position = UDim2.new(.5, -23, .5, -23)
			hub.Size = UDim2.fromOffset(46, 46); hub.BackgroundColor3 = t.glassIdle; hub.BackgroundTransparency = .28
			hub.BorderSizePixel = 0; hub.ZIndex = 109; hub.Parent = dpad
			local pivot = Instance.new("Frame"); pivot.Name = "Pivot"; pivot.Size = UDim2.fromOffset(14, 14)
			pivot.Position = UDim2.fromScale(.5, .5); pivot.AnchorPoint = Vector2.new(.5, .5)
			pivot.BackgroundColor3 = t.white; pivot.BackgroundTransparency = .93; pivot.BorderSizePixel = 0; pivot.ZIndex = 110; pivot.Parent = hub
			local pivotCorner = Instance.new("UICorner"); pivotCorner.CornerRadius = UDim.new(1, 0); pivotCorner.Parent = pivot
			addStroke(pivot, t.white, .86, 1)
			local function hubEdge(name, pos, sz)
				local e = Instance.new("Frame"); e.Name = name; e.Position = pos; e.Size = sz
				e.BackgroundColor3 = t.white; e.BackgroundTransparency = .82; e.BorderSizePixel = 0; e.Visible = false; e.ZIndex = 110; e.Parent = hub
				return e
			end
			self.dpadHubEdges = {
				top = hubEdge("EdgeTop", UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 1)),
				bottom = hubEdge("EdgeBottom", UDim2.new(0, 0, 1, -1), UDim2.new(1, 0, 0, 1)),
				left = hubEdge("EdgeLeft", UDim2.fromOffset(0, 0), UDim2.new(0, 1, 1, 0)),
				right = hubEdge("EdgeRight", UDim2.new(1, -1, 0, 0), UDim2.new(0, 1, 1, 0)),
			}
			local armGeometry = {
				up = {UDim2.new(.5, -23, .5, -68), UDim2.fromOffset(46, 45), UDim2.fromOffset(0, 0), UDim2.fromOffset(46, 59)},
				down = {UDim2.new(.5, -23, .5, 23), UDim2.fromOffset(46, 45), UDim2.fromOffset(0, -14), UDim2.fromOffset(46, 59)},
				left = {UDim2.new(.5, -68, .5, -23), UDim2.fromOffset(45, 46), UDim2.fromOffset(0, 0), UDim2.fromOffset(59, 46)},
				right = {UDim2.new(.5, 23, .5, -23), UDim2.fromOffset(45, 46), UDim2.fromOffset(-14, 0), UDim2.fromOffset(59, 46)},
			}
			for _, cue in {{"Up", .5, 0}, {"Down", .5, 1}, {"Left", 0, .5}, {"Right", 1, .5}} do
				local direction = string.lower(cue[1])
				local g = armGeometry[direction]
				local clip = Instance.new("Frame"); clip.Name = "Arm_" .. cue[1]; clip.Position = g[1]; clip.Size = g[2]
				clip.BackgroundTransparency = 1; clip.ClipsDescendants = true; clip.ZIndex = 109; clip.Parent = dpad
				local cap = Instance.new("Frame"); cap.Name = "Cap"; cap.Position = g[3]; cap.Size = g[4]
				cap.BackgroundColor3 = t.glassIdle; cap.BackgroundTransparency = .28; cap.BorderSizePixel = 0; cap.ZIndex = 109; cap.Parent = clip
				local capCorner = Instance.new("UICorner"); capCorner.CornerRadius = UDim.new(0, 12); capCorner.Parent = cap
				local armStroke = addStroke(cap, t.white, .82, 1)
				local b = Instance.new("TextButton"); b.Name = "Dpad" .. cue[1]; b.Text = ""; b.AutoButtonColor = false
				b.BackgroundTransparency = 1; b.BorderSizePixel = 0; b.Selectable = false
				b.Position = UDim2.fromScale(cue[2], cue[3]); b.Size = UDim2.fromOffset(44, 44)
				b.AnchorPoint = Vector2.new(cue[2], cue[3]); b.ZIndex = 111; b.Parent = dpad
				local _, bars = makeChevron(b, direction, UDim2.fromScale(.5, .5), 112, .32)
				self.dpadButtons[direction] = b
				self.dpadArms[direction] = {clip = clip, cap = cap, stroke = armStroke, bars = bars}
				self:_track(b.InputBegan:Connect(function(event)
					if event.UserInputType == Enum.UserInputType.Touch and self.enabled and self.touchMode ~= "Off" then wakeTouch(self) end
					if event.UserInputType == Enum.UserInputType.Touch and overlay.Visible and dpad.Visible and b.Visible then
						self:setDpadTouch(event, direction)
					end
				end))
			end
		end
		self.moveZone = zone
		self.touchButtons = {}
		local positions = {{-18, -20, 64}, {-82, -88, 58}, {-150, -34, 52}, {-18, -158, 46}}
		for i, spec in actions do
			local pos = positions[i] or {-18 - (i - 1) * 68, -20, 54}
			local btnSize = spec.size or UDim2.fromOffset(pos[3], pos[3])
			local b, stroke, cap = button(spec.action, spec.label or spec.action, spec.position or UDim2.new(1, pos[1], 1, pos[2]), btnSize)
			b.AnchorPoint = spec.anchorPoint or Vector2.new(1, 1)
			if spec.textSize then b.TextSize = spec.textSize end
			local pauseIcon
			local initText = b.Text
			local mayPause = initText == "II" or initText == "?" or (spec.labels and (spec.labels.gameplay == "II" or spec.labels.default == "II"))
			if mayPause then
				pauseIcon = Instance.new("Frame"); pauseIcon.Name = "PauseIcon"; pauseIcon.Size = UDim2.fromOffset(16, 16)
				pauseIcon.Position = UDim2.fromScale(.5, .5); pauseIcon.AnchorPoint = Vector2.new(.5, .5)
				pauseIcon.BackgroundTransparency = 1; pauseIcon.ZIndex = 112; pauseIcon.Parent = b
				for _, sx in {.3125, .6875} do
					local bar = Instance.new("Frame"); bar.Size = UDim2.fromOffset(3, 12); bar.AnchorPoint = Vector2.new(.5, .5)
					bar.Position = UDim2.fromScale(sx, .5); bar.BackgroundColor3 = t.text; bar.BackgroundTransparency = .06
					bar.BorderSizePixel = 0; bar.ZIndex = 112; bar.Parent = pauseIcon
					local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(1, 0); bc.Parent = bar
				end
			end
			table.insert(self.touchButtons, {button = b, stroke = stroke, cap = cap, pauseIcon = pauseIcon,
				action = spec.action, defaultLabel = spec.label or spec.action,
				labels = spec.labels, contexts = normalizeContexts(spec.contexts), visibleOverride = spec.visible, labelOverride = nil})
			self:_track(b.InputBegan:Connect(function(event)
				if event.UserInputType == Enum.UserInputType.Touch and self.enabled and self.touchMode ~= "Off" then wakeTouch(self) end
				if event.UserInputType == Enum.UserInputType.Touch and overlay.Visible and b.Visible ~= false then
					self:setTouchAction(event, spec.action)
				end
			end))
		end
	end
	self:_track(self.uis.TouchMoved:Connect(function(event)
		if event == self.moveTouch then
			if self:resolveMoveMode() == "Dynamic" then
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
		elseif self.dpadTouches and self.dpadTouches[event] ~= nil then self:moveDpadTouch(event)
		elseif self.touch[event] ~= nil then self:moveTouchAction(event) end
	end))
	self:_track(self.uis.TouchEnded:Connect(function(event)
		if event == self.moveTouch then self.moveTouch = nil; self:setTouchDirection(0, 0); self:resetMoveZone() end
		if self.touch[event] ~= nil then self:setTouchAction(event, nil) end
		if self.dpadTouches and self.dpadTouches[event] ~= nil then self:setDpadTouch(event, nil) end
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
