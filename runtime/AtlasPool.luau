local Policy = require(script.Parent.EditableImagePolicy)
local AtlasPool = {}
AtlasPool.__index = AtlasPool

function AtlasPool.new(config)
	config = config or {}
	local maximum = config.maxPages or 32
	assert(maximum >= 1 and maximum % 1 == 0, "maxPages must be a positive integer")
	local maxBytes=config.maxBytes or math.huge
	assert(maxBytes>0,'maxBytes must be positive')
	return setmetatable({maxPages = maximum, maxBytes=maxBytes, bytes=0, images = {}, pins = {}, clock = 0,
		editableImagePolicy=config.editableImagePolicy or Policy.new(config),
		count = 0, uploads = 0, create = config.create or function(w, h)
			return game:GetService("AssetService"):CreateEditableImage({Size = Vector2.new(w, h)})
		end}, AtlasPool)
end

function AtlasPool:evict()
	local oldest, age = nil, math.huge
	for id, entry in self.images do
		if not self.pins[id] and entry.used < age then oldest, age = id, entry.used end
	end
	if oldest == nil then return false end
	local entry=self.images[oldest];entry.image:Destroy()
	self.bytes-=entry.bytes
	self.images[oldest] = nil
	self.count -= 1
	return true
end

function AtlasPool:acquire(id, width, height, pixels)
	assert(width >= 1 and height >= 1 and width <= 1024 and height <= 1024
		and width % 1 == 0 and height % 1 == 0, "Atlas pages must be <= 1024x1024")
	self.clock += 1
	local entry = self.images[id]
	if entry then entry.used = self.clock; return entry.image end
	self.editableImagePolicy:assertAllowed('Atlas image allocation')
	local size=width*height*4
	assert(size<=self.maxBytes,'Atlas page exceeds the byte budget')
	while self.count >= self.maxPages or self.bytes+size>self.maxBytes do assert(self:evict(), "Atlas residency limit reached: all pages pinned") end
	local ok, image = pcall(self.create, width, height)
	while (not ok or not image) and self:evict() do
		if not ok then warn('EditableImage allocation failed; retrying after eviction: '..tostring(image)) end
		ok, image = pcall(self.create, width, height)
	end
	assert(ok and image, 'EditableImage allocation failed; check image API access and device memory: '..tostring(image))
	self.editableImagePolicy:recordCreated()
	local uploaded, err = pcall(function()
		local raw = if type(pixels) == "function" then pixels() else pixels
		assert(buffer.len(raw) == width * height * 4, "Invalid RGBA page size")
		image:WritePixelsBuffer(Vector2.zero, Vector2.new(width, height), raw)
	end)
	if not uploaded then image:Destroy(); error(err) end
	self.uploads += 1
	self.count += 1
	self.bytes+=size
	self.images[id] = {image = image, used = self.clock, bytes=size, content = Content.fromObject(image)}
	return image
end

function AtlasPool:pin(id) self.pins[id] = true end
function AtlasPool:unpin(id) self.pins[id] = nil end
function AtlasPool:releasePins() table.clear(self.pins) end
function AtlasPool:remove(id)
	local entry = self.images[id]
	if entry then entry.image:Destroy(); self.images[id] = nil; self.count -= 1; self.bytes-=entry.bytes end
	self.pins[id] = nil
end
function AtlasPool:destroy()
	for _, entry in self.images do entry.image:Destroy() end
	table.clear(self.images); table.clear(self.pins); self.count = 0;self.bytes=0
end
return AtlasPool
