--!optimize 2
local MobileProfile = if script then require(script.Parent.MobileProfile) else nil
local originPosition = UDim2.fromOffset(0, 0)
local offscreen = UDim2.fromScale(-4, -4)
local function older(a,b) return a.lastUsed < b.lastUsed end
local GpuScene = {}
GpuScene.__index = GpuScene
GpuScene.poolVersion = 2
GpuScene.hiddenPosition = offscreen
local function property(self, entry, key, value)
	if entry.values[key] ~= value then
		entry.object[key] = value; entry.values[key] = value; self.writes += 1
	end
end
local function visible(self,entry,value)
	if not value and self.parked[entry] then self.parked[entry]=nil;self.parkedCount-=1 end
	if entry.values.Visible~=value then
        -- Roblox renders a label whose Visible/transparency/crop just changed with
        -- its previous quad for one frame, so a pooled crop re-shown elsewhere
        -- flashes at its old spot. Shown images stay Visible and hide off-screen:
        -- position-only changes apply in the same frame. publish rewrites Position
        -- on the next draw because the cached value differs.
        if entry.isImage and self.keepParented and not value and entry.object.Visible then
            entry.object.Position=offscreen;entry.values.Position=offscreen
        elseif entry.object.Visible~=value then entry.object.Visible=value end
        entry.values.Visible=value;self.writes+=1
        if not value then entry.hiddenGeneration=self.generation end
    end
end
local function park(self,entry)
    -- Hidden parented spares keep their asset loaded without UI render work.
    visible(self,entry,false)
end
local function publish(self,entry,properties)
    -- Hidden pooled objects must receive their complete geometry and crop
    -- before they can be made visible. Callers cannot publish early by passing
    -- Visible in the unordered property table.
    for key,value in properties do if key~='Visible' and key~='Parent' and key~='ScrollingCrop' and entry.values[key]~=value then
        entry.object[key]=value;entry.values[key]=value;self.writes+=1
    end end
    if entry.parked and properties.Position==nil then
        local position=entry.parkedPosition or originPosition
        if entry.values.Position~=position then entry.object.Position=position;entry.values.Position=position;self.writes+=1 end
    end
    if entry.isImage or entry.parked then
        local key=if entry.isImage then 'ImageTransparency' else 'BackgroundTransparency'
        local value=properties[key] or 0
        if entry.values[key]~=value then
            entry.object[key]=value;entry.values[key]=value;self.writes+=1
        end
    end
    if self.parked[entry] then self.parked[entry]=nil;self.parkedCount-=1 end
    entry.parked=nil;entry.parkedPosition=nil;entry.coldDetached=nil
    -- A recycled ImageLabel must not keep the prior draw's linear sampler
    -- when the next caller relies on this scene's pixelated default.
    if entry.isImage and properties.ResampleMode==nil and entry.values.ResampleMode~=Enum.ResamplerMode.Pixelated then
        entry.object.ResampleMode=Enum.ResamplerMode.Pixelated;entry.values.ResampleMode=Enum.ResamplerMode.Pixelated;self.writes+=1
    end
    if not entry.parented then
        entry.object.Parent=self.parent;entry.parented=true;self.writes+=1
    end
    visible(self,entry,true)
end

local function regionKey(properties)
	local offset,size=properties.ImageRectOffset,properties.ImageRectSize
	local x,y,w,h=offset and offset.X or 0,offset and offset.Y or 0,size and size.X or 0,size and size.Y or 0
	local fractional=properties.ScrollingCrop==true or x%1~=0 or y%1~=0 or w%1~=0 or h%1~=0
    if fractional then return "dynamic",true end
	-- Four signed 13-bit coordinates fit exactly in a Lua double. No string or
	-- table allocation for the usual integer atlas rectangles.
	if x>=-4096 and x<4096 and y>=-4096 and y<4096 and w>=-4096 and w<4096 and h>=-4096 and h<4096
        and not fractional then
		return (((x+4096)*8192+y+4096)*8192+w+4096)*8192+h+4096
	end
	-- Large integer rectangles retain exact static bucket isolation.
	return string.format('%.17g:%.17g:%.17g:%.17g',x,y,w,h),fractional
end
local function cropExpired(self,entry)
    -- Dynamic slots retain their texture binding; inactive pages still age out.
    return self.drawGeneration-entry.lastDrawn>self.cropRetentionFrames
end
local function detachRegion(entry)
	local region=entry.region;local last=table.remove(region.entries)
	if last~=entry then region.entries[entry.slot]=last;last.slot=entry.slot end
	if #region.entries==0 then
        region.bucket.regions[region.key]=nil
        if region.dynamic then region.bucket.dynamic=nil end
        if region.reserve then region.bucket.spareRegion=nil;region.bucket.spares=nil end
    end
end
local function makeImage(self,bucket,region,slot,content,reserve)
    local object=self.factory('ImageLabel');object.Name='ImageLabel';object.BorderSizePixel=0
    object.BackgroundTransparency=1;object.ResampleMode=Enum.ResamplerMode.Pixelated
    object.ImageContent=content;object.Visible=false
    local entry={object=object,isImage=true,values={ImageContent=content,Visible=false,ResampleMode=Enum.ResamplerMode.Pixelated},region=region,slot=slot,
        reserve=reserve,lastUsed=self.drawGeneration-1,lastDrawn=0,hiddenGeneration=self.drawGeneration}
    if reserve and self.keepParented then object.Parent=self.parent;entry.parented=true;self.writes+=1 end
    self.images[#self.images+1]=entry;entry.index=#self.images
    bucket.entries[#bucket.entries+1]=entry;entry.bucketIndex=#bucket.entries
    region.entries[slot]=entry;self.createdImages+=1
    return entry
end
-- A spare belongs to no crop. Claiming it cannot alias another region.
local function warmImage(self,bucket,region,slot,content)
    for _,entry in bucket.spares or {} do
        if not entry.values.Visible and entry.parented and entry.hiddenGeneration<self.generation then
            detachRegion(entry)
            entry.region=region;entry.slot=slot;entry.reserve=nil
            region.entries[slot]=entry;self.recycledImages+=1
            return entry
        end
    end
    return makeImage(self,bucket,region,slot,content)
end
local function refill(self,bucket,content)
    if not self.keepParented or self.imageReserve==0 then return end
    local region=bucket.spareRegion
    if not region then
        region={entries={},key='spares',bucket=bucket,reserve=true}
        bucket.spareRegion=region;bucket.spares=region.entries;bucket.regions.spares=region
    end
    while #region.entries<self.imageReserve do
        local entry=makeImage(self,bucket,region,#region.entries+1,content,true)
        entry.hiddenGeneration=self.generation
    end
end
function GpuScene.new(parent, factory, config)
	config=config or {}
	local profile=config.mobileProfile or (MobileProfile and MobileProfile.detect(config)) or {isMobile=config.mobile==true,maxParkedNodes=config.maxParkedNodes or (if config.mobile then 384 else 2048)}
	assert(profile.maxParkedNodes>=0 and profile.maxParkedNodes<math.huge and profile.maxParkedNodes%1==0,'Invalid parked node budget')
	assert((config.maxInactiveImages or 512)>=0 and (config.maxInactiveImages or 512)%1==0,'Invalid inactive image budget')
	assert((config.imageRetentionFrames or 120)>=0 and (config.imageRetentionFrames or 120)%1==0,'Invalid image retention window')
    assert((config.cropRetentionFrames or 0)>=0 and (config.cropRetentionFrames or 0)%1==0,'Invalid crop retention window')
    assert((config.imageReserve or 0)>=0 and (config.imageReserve or 0)%1==0,'Invalid image reserve')
	return setmetatable({parent = parent, factory = factory or Instance.new,
		mobileProfile=profile,maxParkedNodes=profile.maxParkedNodes,parked={},parkedCount=0,nextParkedPrune=0,prunedParkedNodes=0,localProperties={},
		images = {}, imageBuckets = {}, inactiveImages={}, maxInactiveImages=config.maxInactiveImages or 512,
		imageRetentionFrames=config.imageRetentionFrames or 120,
		cropRetentionFrames=config.cropRetentionFrames or 0,
		keepParented=config.keepParented==true,
        imageReserve=config.imageReserve or 0,
		drawnImages=if config.trackImageOrder then {}else nil,positionOrigin=config.positionOrigin,sourcePositions=if config.positionOrigin then {} else nil,
		frames = {}, imageCount = 0, frameCount = 0, generation = 0, drawGeneration = 0, writes = 0,
		createdImages=0,destroyedImages=0,recycledImages=0}, GpuScene)
end
-- begin stages a presentation; only finish advances the committed generation.
function GpuScene:begin()
    self.imageCount = 0; self.frameCount = 0; self.writes = 0; self.drawGeneration = self.generation + 1
    if self.sourcePositions then table.clear(self.sourcePositions)end
    if self.drawnImages then table.clear(self.drawnImages)end
end
function GpuScene:draw(kind, properties, radius, stroke)
	if kind=='ImageLabel' and self.positionOrigin and properties.Position then
		-- A retained run owns a full-size transparent Frame positioned at its
		-- origin. Keep each child in that Frame's local coordinate space.
		local original=properties.Position;local origin=self.positionOrigin
		local localProperties=self.localProperties;table.clear(localProperties)
		for key,value in properties do localProperties[key]=value end
		localProperties.Position=UDim2.new(original.X.Scale-origin.X.Scale,original.X.Offset-origin.X.Offset,
			original.Y.Scale-origin.Y.Scale,original.Y.Offset-origin.Y.Offset)
		self.sourcePositions[#self.sourcePositions+1]=original;properties=localProperties
	end
	local entry, bucket, region, content
	if kind == 'ImageLabel' then
		self.imageCount+=1
		content=assert(properties.ImageContent,'Image draws require ImageContent')
		bucket=self.imageBuckets[content]
		if not bucket then bucket={regions={},entries={}};self.imageBuckets[content]=bucket end
		bucket.generation=self.drawGeneration;bucket.nextMaintenance=nil
        local key,fractional=regionKey(properties)
        region=if fractional then bucket.dynamic else bucket.regions[key]
        if not region then
            region={entries={},key=key,bucket=bucket,dynamic=fractional}
            bucket.regions[key]=region
            if fractional then
                bucket.dynamic=region
                -- Adopt already loaded fractional labels when updating a live scene.
                local prior={}
                for oldKey,old in bucket.regions do
                    if old~=region and old.fractional then prior[#prior+1]=old end
                end
                for _,old in prior do
                    for _,candidate in old.entries do
                        candidate.region=region;candidate.slot=#region.entries+1
                        region.entries[candidate.slot]=candidate
                    end
                    bucket.regions[old.key]=nil
                end
            end
        end
        if region.generation~=self.drawGeneration then region.used=0;region.generation=self.drawGeneration end
        region.used+=1
        if region.dynamic then
            -- Never steal a node from static crops or another draw this frame.
            -- Re-crop only after a committed hidden presentation.
            local chosen
            for i=region.used,#region.entries do
                local candidate=region.entries[i]
                if not candidate.values.Visible and candidate.hiddenGeneration<self.generation then chosen=i;break end
            end
            if not chosen then
                warmImage(self,bucket,region,#region.entries+1,content)
                chosen=#region.entries
            end
            entry=region.entries[chosen]
            local displaced=region.entries[region.used]
            region.entries[region.used]=entry;entry.slot=region.used
            region.entries[chosen]=displaced;displaced.slot=chosen
        else
            entry=region.entries[region.used]
        end
	else
        self.frameCount+=1;entry=self.frames[self.frameCount]
    end
	if not entry then
		if region then
            entry=warmImage(self,bucket,region,region.used,content)
		else
            local object=self.factory(kind);object.Name=kind;object.BorderSizePixel=0
            entry={object=object,values={}};self.frames[self.frameCount]=entry
        end
	end
	if not entry.parented then
		visible(self,entry,false)
	end
	publish(self, entry, properties)
	entry.lastUsed=self.drawGeneration;entry.lastDrawn=self.drawGeneration
    if entry.isImage and self.drawnImages then self.drawnImages[#self.drawnImages+1]=entry end
	if kind == "Frame" then
		if radius ~= nil or entry.corner then
			if not entry.corner then entry.corner = {object = self.factory("UICorner"), values = {}}; entry.corner.object.Parent = entry.object end
			local wantedRadius=radius or 0
			if entry.radius~=wantedRadius then
				property(self,entry.corner,'CornerRadius',UDim.new(0,wantedRadius));entry.radius=wantedRadius
			end
		end
		if stroke or entry.stroke then
			if not entry.stroke then entry.stroke = {object = self.factory("UIStroke"), values = {}}; entry.stroke.object.Parent = entry.object end
			if not self.clearStrokeColor then self.clearStrokeColor=Color3.new() end
			property(self,entry.stroke,'Enabled',stroke~=nil)
			property(self,entry.stroke,'Color',if stroke then stroke.color else self.clearStrokeColor)
			property(self,entry.stroke,'Thickness',if stroke then stroke.thickness or 1 else 0)
		end
	end
	return entry.object
end
function GpuScene:image(properties) return self:draw("ImageLabel", properties) end
function GpuScene:frame(properties, radius, stroke) return self:draw("Frame", properties, radius, stroke) end
function GpuScene:removeImage(entry)
	if self.parked[entry] then self.parked[entry]=nil;self.parkedCount-=1 end
	entry.object.ImageContent=Content.none;entry.values.ImageContent=nil;self.writes+=1
	entry.object:Destroy()
	self.destroyedImages+=1
	local bucket=entry.region.bucket;bucket.nextMaintenance=nil;detachRegion(entry)
	local last=table.remove(bucket.entries)
	if last~=entry then bucket.entries[entry.bucketIndex]=last;last.bucketIndex=entry.bucketIndex end
	last=table.remove(self.images)
	if last~=entry then self.images[entry.index]=last;last.index=entry.index end
end
function GpuScene:finish()
	local inactive=self.inactiveImages;table.clear(inactive)
	for content,bucket in self.imageBuckets do
        if bucket.generation~=self.drawGeneration and bucket.nextMaintenance and self.drawGeneration<bucket.nextMaintenance then
            -- Fully idle buckets have no visibility or age transition before
            -- their next deadline. Bulk-copy their inactive references instead
            -- of revisiting every retained crop on every presentation.
            table.move(bucket.inactive,1,#bucket.inactive,#inactive+1,inactive)
            continue
        end
        local bucketInactive=bucket.inactive or {};bucket.inactive=bucketInactive;table.clear(bucketInactive)
        local nextMaintenance=if bucket.generation==self.drawGeneration then self.drawGeneration+1 else math.huge
		for _,region in bucket.regions do
			local used=if region.generation==self.drawGeneration then region.used else 0
			for i=#region.entries,used+1,-1 do
				local entry=region.entries[i]
                -- Retain idle animation crops only through their draw-age window.
                -- Expired crops join the bounded detached pool even on active pages.
                local active=bucket.generation==self.drawGeneration
                if entry.retainedUntil then
                    entry.lastUsed=math.max(entry.lastUsed,math.min(self.drawGeneration-1,entry.retainedUntil))
                    entry.retainedUntil=nil
                end
                local retained=not entry.coldDetached and ((entry.region.dynamic and active) or (entry.reserve and active) or (not entry.reserve and not cropExpired(self,entry))
                    or (entry.region.dynamic and active and self.drawGeneration-entry.lastDrawn<=1))
                visible(self,entry,false)
                if (self.keepParented and retained) or (active and not self.keepParented) then entry.lastUsed=self.drawGeneration end
                if self.keepParented and retained and not entry.reserve then
                    entry.retainedUntil=entry.lastDrawn+self.cropRetentionFrames
                    nextMaintenance=math.min(nextMaintenance,entry.retainedUntil+1)
                else nextMaintenance=math.min(nextMaintenance,entry.lastUsed+self.imageRetentionFrames+1)end
                if self.drawGeneration-entry.lastUsed>self.imageRetentionFrames then self:removeImage(entry)
				else
                    -- Bounded warm spares retain their sheet and parent. Only
                    -- callers that opted out of warm parenting detach nodes.
                    if entry.parented and not self.keepParented then entry.object.Parent=nil;entry.parented=false;self.writes+=1 end
                    do
                        inactive[#inactive+1]=entry;bucketInactive[#bucketInactive+1]=entry
                    end
                end
			end
		end
        if bucket.generation==self.drawGeneration then refill(self,bucket,content)end
        if next(bucket.regions)==nil then self.imageBuckets[content]=nil
        else bucket.nextMaintenance=nextMaintenance end
	end
	-- Bound hidden exact-crop spares without moving entries between crop buckets.
	if #inactive>self.maxInactiveImages then
		table.sort(inactive,older)
		for i=1,#inactive-self.maxInactiveImages do self:removeImage(inactive[i])end
	end
    for content,bucket in self.imageBuckets do if next(bucket.regions)==nil then self.imageBuckets[content]=nil end end
	table.clear(inactive)
	for i = self.frameCount + 1, #self.frames do
        local entry=self.frames[i]
        if self.keepParented and entry.parented and not entry.coldDetached then park(self,entry)else visible(self,entry,false)end
    end
    -- Cold retained crops need no C++ layout participation. Keep their immutable
    -- crop binding for reuse, hidden for a committed presentation before recycle.
    if self.parkedCount>self.maxParkedNodes and self.drawGeneration>=self.nextParkedPrune then
        self.nextParkedPrune=math.huge
        for entry in self.parked do
            if self.drawGeneration-(entry.lastDrawn or 0)>=180 then
                visible(self,entry,false)
                if entry.parented and not self.keepParented then entry.object.Parent=nil;entry.parented=false;self.writes+=1 end
                entry.coldDetached=true;entry.lastUsed=entry.lastDrawn or 0;entry.retainedUntil=nil
                self.prunedParkedNodes+=1
                if entry.region then entry.region.bucket.nextMaintenance=nil end
                if self.parkedCount<=self.maxParkedNodes then break end
            else
                self.nextParkedPrune=math.min(self.nextParkedPrune,(entry.lastDrawn or 0)+180)
            end
        end
    end
    if self.parkedCount<=self.maxParkedNodes then self.nextParkedPrune=0 end
    self.generation=self.drawGeneration
end
function GpuScene:destroy()
	for _, pool in {self.images, self.frames} do for _, entry in pool do entry.object:Destroy() end; table.clear(pool) end
	table.clear(self.imageBuckets);table.clear(self.inactiveImages)
	table.clear(self.parked);self.parkedCount=0
end
return GpuScene
