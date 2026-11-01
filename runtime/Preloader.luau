--!optimize 2
--!nonstrict
-- Minimalist black startup screen with bottom-right progress HUD, post-quit menu, asset preloading, and cooperative CPU yield checkpoints.
local Preloader = {}

local ignoredStartKeys = {
	Escape = true, LeftAlt = true, RightAlt = true, LeftSuper = true, RightSuper = true,
	LeftMeta = true, RightMeta = true, CapsLock = true, NumLock = true, ScrollLock = true,
	Print = true, Pause = true, Thumbstick1 = true, Thumbstick2 = true,
	F1 = true, F2 = true, F3 = true, F4 = true, F5 = true, F6 = true,
	F7 = true, F8 = true, F9 = true, F10 = true, F11 = true, F12 = true,
}

function Preloader.shouldTriggerStart(input, processed)
	if processed or not input then
		return false
	end
	local keyCode = input.KeyCode
	local keyName = if type(keyCode) == 'userdata' or type(keyCode) == 'table' then keyCode.Name else tostring(keyCode or '')
	if keyName and ignoredStartKeys[keyName] then
		return false
	end
	local kind = input.UserInputType
	if kind == Enum.UserInputType.Keyboard or kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
		return true
	end
	return tostring(kind):match('Gamepad') ~= nil
end

local function formatTitle(title)
	if type(title) == 'string' and title ~= '' and title ~= 'Loading' then
		if title:sub(1, 8):lower() == 'loading ' then
			return title
		end
		return 'Loading ' .. title
	end
	return 'Loading'
end

function Preloader.new(options)
	options = options or {}
	local scheduler = options.scheduler or task
	local clock = options.clock or os.clock
	local factory = options.instanceFactory or function(class)
		return Instance.new(class)
	end
	local provider = options.contentProvider or (not options.headless and game and game:GetService('ContentProvider'))

	local self = {
		target = 0,
		progress = 0,
		stage = 'Preparing...',
		displayTitle = options.title,
		destroyed = false,
		failed = false,
		objects = {},
		lastYield = clock(),
	}

	local function refreshVisuals()
		if options.headless or self.destroyed or not self.gui or self.failed then
			return
		end
		if self.titleLabel then
			self.titleLabel.Text = formatTitle(self.displayTitle)
		end
		if self.percentLabel then
			self.percentLabel.Text = string.format('%d%%', math.min(100, math.floor(self.progress * 100 + 0.5)))
		end
		if self.fill then
			self.fill.Size = UDim2.fromScale(self.progress, 1)
		end
	end

	function self:setTitle(title)
		if self.destroyed then
			return
		end
		self.displayTitle = title
		if self.promptTitle then
			self.promptTitle.Text = if type(title) == 'string' and title ~= '' then title else 'Session Ended'
		end
		refreshVisuals()
	end

	function self:resetProgress()
		if self.destroyed then
			return
		end
		self.target = 0
		self.progress = 0
		refreshVisuals()
	end

	function self:setStage(label, fraction)
		if self.destroyed then
			return
		end
		if label ~= nil then
			self.stage = label
		end
		if self.errorSub and self.failed and label ~= nil then
			self.errorSub.Text = label
		end
		if self.promptLabel and self.waitingForStart and label ~= nil then
			self.promptLabel.Text = label
		end
		if fraction then
			self.target = math.max(self.target, math.clamp(fraction, 0, 1))
			self.progress = math.max(self.progress, self.target)
		end
		refreshVisuals()
	end

	function self:checkpoint(label, fraction, budgetSec)
		if self.destroyed then
			return
		end
		if label ~= nil or fraction ~= nil then
			self:setStage(label or self.stage, fraction)
		end
		local now = clock()
		if now - self.lastYield >= (budgetSec or 0.025) then
			if scheduler and scheduler.wait then
				scheduler.wait()
			end
			self.lastYield = clock()
		end
	end

	function self:destroy()
		if self.destroyed then
			return
		end
		self.destroyed = true
		if self.connection then
			self.connection:Disconnect()
			self.connection = nil
		end
		if self.startConnection then
			self.startConnection:Disconnect()
			self.startConnection = nil
		end
		if self.decorationCleanup then
			self.decorationCleanup()
			self.decorationCleanup = nil
		end
		if self.gui then
			self.gui:Destroy()
			self.gui = nil
		end
		for _, object in self.objects do
			object:Destroy()
		end
		table.clear(self.objects)
	end
	self.Destroy = self.destroy

	function self:fail(message)
		if self.destroyed then
			return
		end
		self.failed = true
		self:setStage(message or 'Check Output for details.')
		if self.hud then
			self.hud.Visible = false
		end
		if self.promptContainer then
			self.promptContainer.Visible = false
		end
		if self.skipButton then
			self.skipButton.Visible = false
		end
		if self.errorTitle then
			self.errorTitle.Visible = true
		end
		if self.errorSub then
			self.errorSub.Text = self.stage
			self.errorSub.Visible = true
		end
	end

	function self:finish()
		if self.destroyed or self.failed then
			return
		end
		self:setStage('Starting...', 1)
		self.progress = 1
		refreshVisuals()
		if self.group and scheduler and scheduler.delay then
			self.fadeInAt = nil
			self.fadeAt = clock()
			-- Also destroy if rendering stops or the GUI is removed during the fade.
			scheduler.delay(0.16, function()
				self:destroy()
			end)
		else
			self:destroy()
		end
	end

	function self:skip()
		self.skipped = true
	end

	function self:triggerStart()
		if self.waitingForStart then
			self.startTriggered = true
		end
	end

	function self:waitForStart(promptOptions)
		promptOptions = promptOptions or {}
		self.startTriggered = false
		self.waitingForStart = true
		self:setStage(promptOptions.message or 'Press any button or click to start')
		if self.hud then
			self.hud.Visible = false
		end
		if self.promptTitle then
			local title = promptOptions.title or self.displayTitle
			self.promptTitle.Text = if type(title) == 'string' and title ~= '' and title ~= 'Loading' then title else 'Session Ended'
		end
		if self.promptButton then
			self.promptButton.Text = ''
			self.promptButton.Visible = true
		end
		if self.promptHint then
			local hint = promptOptions.hint
			self.promptHint.Text = if type(hint) == 'string' then hint else ''
			self.promptHint.Visible = type(hint) == 'string' and hint ~= ''
		end
		if self.promptContainer then
			self.promptContainer.Visible = true
		end
		local started = clock()
		self.promptStarted = started
		local debounce = promptOptions.debounce or 0.2
		if not options.headless then
			local uis = options.userInputService or game:GetService('UserInputService')
			self.startConnection = uis.InputBegan:Connect(function(input, processed)
				if clock() - started >= debounce and Preloader.shouldTriggerStart(input, processed) then
					self:triggerStart()
				end
			end)
		end
		while not self.startTriggered and not self.destroyed do
			scheduler.wait()
		end
		self.waitingForStart = false
		if self.startConnection then
			self.startConnection:Disconnect()
			self.startConnection = nil
		end
		if self.promptContainer then
			self.promptContainer.Visible = false
		end
		if self.startTriggered and not self.destroyed and not self.failed then
			self.target = 0
			self.progress = 0
			if self.hud then
				self.hud.Visible = true
			end
			refreshVisuals()
		end
		return self.startTriggered and not self.destroyed
	end

	function self:preload(assets)
		assets = assets or {}
		assert(provider, 'Preloader requires a contentProvider')
		local entries, seen = {}, {}
		for _, kind in { 'sounds', 'images' } do
			for _, uri in assets[kind] or {} do
				if type(uri) == 'string' and uri ~= '' and not seen[uri] then
					seen[uri] = true
					entries[#entries + 1] = { uri = uri, kind = kind }
				end
			end
		end
		local total, completed, reported = #entries, 0, {}
		local batchSize = math.max(1, math.floor(assets.batchSize or options.batchSize or 10))
		local timeout = math.max(0, assets.timeoutSec or options.timeoutSec or 8)
		local start = clock()
		local result = { total = total, completed = 0, failures = 0, status = 'complete' }
		local startFraction = self.target
		local endFraction = assets.progressEnd or 0.85
		self.skipped = false
		self:setStage(assets.label or 'Loading assets...', self.target)
		if self.skipButton and options.skipAfterSec ~= false and scheduler and scheduler.delay then
			scheduler.delay(options.skipAfterSec or 3, function()
				if not self.destroyed and self.loading then
					self.skipButton.Visible = true
				end
			end)
		end
		self.loading = true
		local active = true
		for first = 1, total, batchSize do
			if self.destroyed or self.skipped or clock() - start >= timeout then
				break
			end
			local batch, ids = {}, {}
			for index = first, math.min(total, first + batchSize - 1) do
				local entry = entries[index]
				local object = factory(entry.kind == 'sounds' and 'Sound' or 'ImageLabel')
				if entry.kind == 'sounds' then
					object.SoundId = entry.uri
				else
					object.Image = entry.uri
					object.Visible = false
				end
				batch[#batch + 1] = object
				ids[entry.uri] = true
				self.objects[#self.objects + 1] = object
			end
			local done = false
			scheduler.spawn(function()
				local ok = pcall(function()
					provider:PreloadAsync(batch, function(uri, status)
						if not active or not ids[uri] or reported[uri] then
							return
						end
						reported[uri] = true
						completed += 1
						result.completed = completed
						if status and tostring(status):match('Success$') == nil then
							result.failures += 1
						end
						local frac = if endFraction > startFraction
							then startFraction + (endFraction - startFraction) * (completed / total)
							else endFraction * (completed / total)
						self:setStage(assets.label or 'Loading assets...', frac)
					end)
				end)
				if not ok and active then
					result.failures += 1
				end
				done = true
			end)
			while not done and not self.destroyed and not self.skipped and clock() - start < timeout do
				scheduler.wait()
			end
			if not done then
				break
			end
		end
		active = false
		self.loading = false
		if self.skipButton then
			self.skipButton.Visible = false
		end
		if self.skipped then
			result.status = 'skipped'
		elseif self.destroyed then
			result.status = 'destroyed'
		elseif completed < total and clock() - start >= timeout then
			result.status = 'timeout'
		elseif result.failures > 0 or completed < total then
			result.status = 'failed'
		end
		return result
	end

	if options.headless then
		return self
	end

	local accent = options.accentColor or Color3.fromRGB(232, 232, 232)
	local secondary = options.secondaryColor or Color3.fromRGB(145, 145, 145)
	self.secondary = secondary

	local function make(class, props, parent)
		local object = factory(class)
		for key, value in props do
			object[key] = value
		end
		object.Parent = parent
		return object
	end

	local gui = make('ScreenGui', {
		Name = 'PortKitPreloader',
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		DisplayOrder = 1000,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, options.parent or game:GetService('Players').LocalPlayer:WaitForChild('PlayerGui'))
	self.gui = gui

	local group = make('CanvasGroup', {
		Name = 'Splash',
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		GroupTransparency = if options.fadeIn then 1 else 0,
	}, gui)
	self.group = group
	if options.fadeIn then
		self.fadeInAt = clock()
	end

	make('Frame', {
		Name = 'Curtain',
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = options.backgroundColor or Color3.new(0, 0, 0),
		BorderSizePixel = 0,
	}, group)

	if options.decorate then
		local decoration = make('Frame', {
			Name = 'Decoration',
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
		}, group)
		self.decorationCleanup = options.decorate(decoration)
	end

	local hud = make('Frame', {
		Name = 'Hud',
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -36, 1, -30),
		Size = UDim2.fromOffset(200, 26),
		BackgroundTransparency = 1,
		Visible = true,
	}, group)
	self.hud = hud

	self.titleLabel = make('TextLabel', {
		Name = 'GameTitle',
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(152, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		TextColor3 = Color3.fromRGB(230, 230, 230),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = formatTitle(self.displayTitle),
	}, hud)

	self.percentLabel = make('TextLabel', {
		Name = 'Percentage',
		Position = UDim2.fromOffset(152, 1),
		Size = UDim2.fromOffset(48, 15),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = secondary,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = '0%',
	}, hud)

	local track = make('Frame', {
		Name = 'Progress',
		Position = UDim2.fromOffset(0, 23),
		Size = UDim2.fromOffset(200, 3),
		BackgroundColor3 = options.trackColor or Color3.fromRGB(44, 44, 44),
		BorderSizePixel = 0,
	}, hud)
	make('UICorner', { CornerRadius = UDim.new(0, 1) }, track)
	self.progressTrack = track

	self.fill = make('Frame', {
		Name = 'Fill',
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = accent,
		BorderSizePixel = 0,
	}, track)
	make('UICorner', { CornerRadius = UDim.new(0, 1) }, self.fill)

	self.skipButton = make('TextButton', {
		Name = 'Skip',
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 0, -6),
		Size = UDim2.fromOffset(48, 18),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = 'Skip',
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = secondary,
		TextXAlignment = Enum.TextXAlignment.Right,
		Visible = false,
	}, hud)
	self.skipButton.Activated:Connect(function()
		self:skip()
	end)

	local promptContainer = make('Frame', {
		Name = 'Prompt',
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Visible = false,
	}, group)
	self.promptContainer = promptContainer

	local initialPromptTitle = if type(self.displayTitle) == 'string' and self.displayTitle ~= '' and self.displayTitle ~= 'Loading'
		then self.displayTitle
		else 'Session Ended'
	self.promptTitle = make('TextLabel', {
		Name = 'PromptTitle',
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -10),
		Size = UDim2.fromOffset(420, 22),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 15,
		TextColor3 = Color3.fromRGB(230, 230, 230),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = initialPromptTitle,
	}, promptContainer)

	self.promptLabel = make('TextLabel', {
		Name = 'Message',
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 12),
		Size = UDim2.fromOffset(420, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextColor3 = Color3.fromRGB(136, 136, 136),
		Text = self.stage,
	}, promptContainer)

	self.promptHint = make('TextLabel', {
		Name = 'Hint',
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 32),
		Size = UDim2.fromOffset(420, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextColor3 = Color3.fromRGB(92, 92, 92),
		Text = '',
		Visible = false,
	}, promptContainer)

	self.promptButton = make('TextButton', {
		Name = 'Action',
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = '',
		TextTransparency = 1,
	}, promptContainer)
	self.promptButton.Activated:Connect(function()
		if self.waitingForStart and clock() - (self.promptStarted or 0) >= 0.2 then
			self:triggerStart()
		end
	end)

	self.errorTitle = make('TextLabel', {
		Name = 'ErrorTitle',
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -10),
		Size = UDim2.fromOffset(420, 22),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 15,
		TextColor3 = Color3.fromRGB(230, 230, 230),
		Text = 'Could not start game',
		Visible = false,
	}, group)

	self.errorSub = make('TextLabel', {
		Name = 'ErrorDetail',
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 12),
		Size = UDim2.fromOffset(420, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextColor3 = Color3.fromRGB(136, 136, 136),
		Text = self.stage,
		Visible = false,
	}, group)

	local runService = options.runService or game:GetService('RunService')
	self.connection = runService.RenderStepped:Connect(function(dt)
		if self.progress < self.target then
			self.progress += (self.target - self.progress) * (1 - math.exp(-dt * 18))
			refreshVisuals()
		end
		if self.fadeAt then
			local alpha = math.clamp((clock() - self.fadeAt) / 0.14, 0, 1)
			group.GroupTransparency = alpha
			if alpha >= 1 then
				self:destroy()
			end
		elseif self.fadeInAt then
			local alpha = math.clamp((clock() - self.fadeInAt) / 0.18, 0, 1)
			group.GroupTransparency = 1 - alpha
			if alpha >= 1 then
				self.fadeInAt = nil
			end
		end
	end)

	return self
end

return Preloader
