--!optimize 2
--!nonstrict
-- Minimalist black startup screen with bottom-right progress HUD, asset preloading, and cooperative CPU yield checkpoints.
local Preloader = {}

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
		if self.promptContainer then
			self.promptContainer.Visible = true
		end
		if self.promptButton then
			self.promptButton.Text = promptOptions.buttonText or 'Play Again'
			self.promptButton.Visible = true
		end
		local started = clock()
		self.promptStarted = started
		if not options.headless then
			self.startConnection = game:GetService('UserInputService').InputBegan:Connect(function(input)
				local kind = input.UserInputType
				if
					clock() - started >= (promptOptions.debounce or 0.2)
					and (
						kind == Enum.UserInputType.Keyboard
						or kind == Enum.UserInputType.MouseButton1
						or kind == Enum.UserInputType.MouseButton2
						or kind == Enum.UserInputType.Touch
						or tostring(kind):match('Gamepad')
					)
				then
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
		if self.hud and not self.failed then
			self.hud.Visible = true
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
	}, gui)
	self.group = group

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
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(360, 80),
		BackgroundTransparency = 1,
		Visible = false,
	}, group)
	self.promptContainer = promptContainer

	self.promptLabel = make('TextLabel', {
		Name = 'Message',
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(360, 22),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		TextColor3 = Color3.fromRGB(230, 230, 230),
		Text = self.stage,
	}, promptContainer)

	self.promptButton = make('TextButton', {
		Name = 'Action',
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 34),
		Size = UDim2.fromOffset(108, 30),
		BackgroundColor3 = Color3.fromRGB(28, 28, 28),
		BorderSizePixel = 0,
		Text = 'Play Again',
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = Color3.fromRGB(230, 230, 230),
	}, promptContainer)
	make('UICorner', { CornerRadius = UDim.new(0, 4) }, self.promptButton)
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
		end
	end)

	return self
end

return Preloader
