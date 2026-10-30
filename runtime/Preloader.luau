--!nonstrict
-- Startup asset warming and a self-contained loading screen.
local Preloader = {}

function Preloader.new(options)
	options = options or {}
	local self = {target=0, progress=0, stage='Preparing...', destroyed=false, failed=false, objects={}}
	local scheduler = options.scheduler or task
	local factory = options.instanceFactory or function(class) return Instance.new(class) end
	local provider = options.contentProvider or (not options.headless and game:GetService('ContentProvider'))
	function self:setStage(label, fraction)
		if self.destroyed then return end
		self.stage = label
		if fraction then self.target = math.max(self.target, math.clamp(fraction, 0, 1)) end
		if self.stageLabel then self.stageLabel.Text = label end
	end
	function self:destroy()
		if self.destroyed then return end
		self.destroyed = true
		if self.connection then self.connection:Disconnect() end
		if self.startConnection then self.startConnection:Disconnect(); self.startConnection=nil end
		if self.decorationCleanup then self.decorationCleanup(); self.decorationCleanup = nil end
		if self.layoutConnection then self.layoutConnection:Disconnect() end
		if self.gui then self.gui:Destroy() end
		for _, object in self.objects do object:Destroy() end
		table.clear(self.objects)
	end
	self.Destroy = self.destroy
	function self:fail(message)
		if self.destroyed then return end
		self.failed = true
		self:setStage(message or 'Check the output for details.')
		if self.titleLabel then self.titleLabel.Text = 'Unable to start'; self.titleLabel.TextColor3 = self.secondary end
		if self.skipButton then self.skipButton.Visible = false end
	end
	function self:finish()
		if self.destroyed or self.failed then return end
		self:setStage('Starting...', 1)
		if self.group and scheduler and scheduler.delay then
			self.fadeAt = os.clock()
			-- Also destroy if rendering stops or the GUI is removed during the fade.
			scheduler.delay(.2, function() self:destroy() end)
		else self:destroy() end
	end
	function self:skip() self.skipped = true end
	function self:triggerStart()
        if self.waitingForStart then self.startTriggered=true end
    end
    function self:waitForStart(promptOptions)
        promptOptions=promptOptions or {}
        self.startTriggered=false;self.waitingForStart=true
        self:setStage(promptOptions.message or 'Press any button or click to start')
        if self.stageLabel then self.stageLabel.TextXAlignment=Enum.TextXAlignment.Center;self.stageLabel.Position=UDim2.fromOffset(0,126);self.stageLabel.Size=UDim2.fromOffset(360,20) end
        if self.progressTrack then self.progressTrack.Visible=false;self.percentLabel.Visible=false end
        if self.skipButton then self.skipButton.Text=promptOptions.buttonText or 'Play Again';self.skipButton.Visible=true end
        local started=os.clock();self.promptStarted=started
        if not options.headless then
            self.startConnection=game:GetService('UserInputService').InputBegan:Connect(function(input)
                local kind=input.UserInputType
                if os.clock()-started >= (promptOptions.debounce or .2) and (kind==Enum.UserInputType.Keyboard or kind==Enum.UserInputType.MouseButton1 or kind==Enum.UserInputType.MouseButton2 or kind==Enum.UserInputType.Touch or tostring(kind):match('Gamepad')) then self:triggerStart() end
            end)
        end
        while not self.startTriggered and not self.destroyed do scheduler.wait() end
        self.waitingForStart=false
        if self.startConnection then self.startConnection:Disconnect();self.startConnection=nil end
        if self.skipButton then self.skipButton.Visible=false end
        if self.progressTrack then self.progressTrack.Visible=true;self.percentLabel.Visible=true end
        return self.startTriggered and not self.destroyed
    end
	function self:preload(assets)
		assets = assets or {}
		assert(provider, 'Preloader requires a contentProvider')
		local entries, seen = {}, {}
		for _, kind in {'sounds', 'images'} do
			for _, uri in assets[kind] or {} do
				if type(uri) == 'string' and uri ~= '' and not seen[uri] then
					seen[uri] = true; entries[#entries+1] = {uri=uri, kind=kind}
				end
			end
		end
		local total, completed, reported = #entries, 0, {}
		local batchSize = math.max(1, math.floor(assets.batchSize or options.batchSize or 10))
		local timeout = math.max(0, assets.timeoutSec or options.timeoutSec or 8)
		local start = os.clock()
		local result = {total=total, completed=0, failures=0, status='complete'}
		self.skipped = false
		self:setStage(assets.label or 'Loading assets...', self.target)
		if self.skipButton and options.skipAfterSec ~= false then
			scheduler.delay(options.skipAfterSec or 3, function()
				if not self.destroyed and self.loading then self.skipButton.Visible = true end
			end)
		end
		self.loading = true
		local active = true
		for first = 1, total, batchSize do
			if self.destroyed or self.skipped or os.clock()-start >= timeout then break end
			local batch, ids = {}, {}
			for index = first, math.min(total, first+batchSize-1) do
				local entry = entries[index]; local object = factory(entry.kind == 'sounds' and 'Sound' or 'ImageLabel')
				if entry.kind == 'sounds' then object.SoundId = entry.uri else object.Image = entry.uri; object.Visible = false end
				batch[#batch+1] = object; ids[entry.uri] = true; self.objects[#self.objects+1] = object
			end
			local done = false
			scheduler.spawn(function()
				local ok = pcall(function() provider:PreloadAsync(batch, function(uri, status)
					if not active or not ids[uri] or reported[uri] then return end
					reported[uri] = true; completed += 1; result.completed = completed
					if status and tostring(status):match('Success$') == nil then result.failures += 1 end
					self:setStage(assets.label or 'Loading assets...', (assets.progressEnd or .85)*completed/total)
				end) end)
				if not ok and active then result.failures += 1 end
				done = true
			end)
			while not done and not self.destroyed and not self.skipped and os.clock()-start < timeout do scheduler.wait() end
			if not done then break end
		end
		active = false; self.loading = false
		if self.skipButton then self.skipButton.Visible = false end
		if self.skipped then result.status = 'skipped'
		elseif self.destroyed then result.status = 'destroyed'
		elseif completed < total and os.clock()-start >= timeout then result.status = 'timeout'
		elseif result.failures > 0 or completed < total then result.status = 'failed' end
		return result
	end
	if options.headless then return self end
	local accent = options.accentColor or Color3.fromRGB(220, 224, 230)
	local secondary = options.secondaryColor or Color3.fromRGB(145, 151, 163); self.secondary = secondary
	local function make(class, props, parent)
		local object = factory(class); for key, value in props do object[key] = value end; object.Parent = parent; return object
	end
	local gui = make('ScreenGui', {Name='PortKitPreloader', IgnoreGuiInset=true, ResetOnSpawn=false, DisplayOrder=1000, ZIndexBehavior=Enum.ZIndexBehavior.Sibling}, options.parent or game:GetService('Players').LocalPlayer:WaitForChild('PlayerGui')); self.gui=gui
	local group=make('CanvasGroup', {Size=UDim2.fromScale(1,1), BackgroundTransparency=1}, gui); self.group=group
	make('Frame', {Size=UDim2.fromScale(1,1), BackgroundColor3=options.backgroundColor or Color3.fromRGB(8,10,16), BorderSizePixel=0}, group)
	-- Decorations are behind the content and may return a cleanup function for connections.
	local decoration=make('Frame', {Name='Decoration', Size=UDim2.fromScale(1,1), BackgroundTransparency=1}, group)
	if options.decorate then self.decorationCleanup=options.decorate(decoration) end
	local content=make('Frame', {AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.5,.5),Size=UDim2.fromOffset(360,220),BackgroundTransparency=1}, group)
	local fit=make('UIScale', {Scale=1}, content)
	local function layout() fit.Scale=math.min(1,gui.AbsoluteSize.X/400,gui.AbsoluteSize.Y/260) end
	self.layoutConnection=gui:GetPropertyChangedSignal('AbsoluteSize'):Connect(layout); layout()
	if options.icon and options.icon ~= '' then
		make('ImageLabel',{AnchorPoint=Vector2.new(.5,0),Position=UDim2.new(.5,0,0,0),Size=UDim2.fromOffset(48,48),BackgroundTransparency=1,Image=options.icon,ScaleType=Enum.ScaleType.Fit},content)
	elseif options.emblem == 'mountain' then
		local mark=make('Frame',{AnchorPoint=Vector2.new(.5,0),Position=UDim2.new(.5,0,0,8),Size=UDim2.fromOffset(52,36),BackgroundTransparency=1},content)
		make('Frame',{AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromOffset(16,19),Size=UDim2.fromOffset(36,2),Rotation=-55,BackgroundColor3=accent,BorderSizePixel=0},mark)
		make('Frame',{AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromOffset(36,19),Size=UDim2.fromOffset(36,2),Rotation=55,BackgroundColor3=accent,BorderSizePixel=0},mark)
	end
	self.titleLabel=make('TextLabel',{Position=UDim2.fromOffset(0,62),Size=UDim2.fromOffset(360,36),BackgroundTransparency=1,Font=Enum.Font.GothamBold,TextSize=24,TextColor3=Color3.fromRGB(235,238,242),Text=options.title or 'Loading',TextTruncate=Enum.TextTruncate.AtEnd},content)
	if options.subtitle and options.subtitle ~= '' then
		make('TextLabel',{Position=UDim2.fromOffset(0,100),Size=UDim2.fromOffset(360,18),BackgroundTransparency=1,Font=Enum.Font.Gotham,TextSize=12,TextColor3=secondary,Text=options.subtitle},content)
	end
	self.stageLabel=make('TextLabel',{Position=UDim2.fromOffset(40,126),Size=UDim2.fromOffset(220,20),BackgroundTransparency=1,Font=Enum.Font.Gotham,TextSize=12,TextColor3=secondary,TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd,Text=self.stage},content)
	local percent=make('TextLabel',{Position=UDim2.fromOffset(260,126),Size=UDim2.fromOffset(60,20),BackgroundTransparency=1,Font=Enum.Font.Gotham,TextSize=12,TextColor3=secondary,Text='0%',TextXAlignment=Enum.TextXAlignment.Right},content)
	self.percentLabel=percent
	local track=make('Frame',{Position=UDim2.fromOffset(40,153),Size=UDim2.fromOffset(280,2),BackgroundColor3=options.trackColor or Color3.fromRGB(48,52,61),BorderSizePixel=0},content)
	self.progressTrack=track
	local fill=make('Frame',{Size=UDim2.fromScale(0,1),BackgroundColor3=accent,BorderSizePixel=0},track)
	self.skipButton=make('TextButton',{Position=UDim2.new(.5,-50,0,172),Size=UDim2.fromOffset(100,32),BackgroundColor3=Color3.fromRGB(38,42,51),BorderSizePixel=0,Text='Skip',Font=Enum.Font.GothamMedium,TextSize=13,TextColor3=Color3.fromRGB(225,229,235),Visible=false},content)
	self.skipButton.Activated:Connect(function() if self.waitingForStart then if os.clock()-(self.promptStarted or 0)>=.2 then self:triggerStart() end else self:skip() end end)
	self.connection=game:GetService('RunService').RenderStepped:Connect(function(dt)
		self.progress+=(self.target-self.progress)*(1-math.exp(-dt*9))
		fill.Size=UDim2.fromScale(self.progress,1); percent.Text=string.format('%d%%',math.floor(self.progress*100+.5))
		if self.fadeAt then group.GroupTransparency=math.clamp((os.clock()-self.fadeAt)/.2,0,1) end
	end)
	return self
end
return Preloader
