local GpuScene = {}
GpuScene.__index = GpuScene
local function apply(self, entry, properties)
	for key, value in properties do
		if entry.values[key] ~= value then
			entry.object[key] = value; entry.values[key] = value; self.writes += 1
		end
	end
end

function GpuScene.new(parent, factory)
	return setmetatable({parent = parent, factory = factory or Instance.new,
		images = {}, frames = {}, imageCount = 0, frameCount = 0, writes = 0}, GpuScene)
end
function GpuScene:begin() self.imageCount = 0; self.frameCount = 0; self.writes = 0 end
function GpuScene:draw(kind, properties, radius, stroke)
	local pool = if kind == "ImageLabel" then self.images else self.frames
	local counter = if kind == "ImageLabel" then "imageCount" else "frameCount"
	self[counter] += 1
	local index = self[counter]
	local entry = pool[index]
	if not entry then
		local object = self.factory(kind)
		object.Name = kind; object.BorderSizePixel = 0
		if kind == "ImageLabel" then object.BackgroundTransparency = 1; object.ResampleMode = Enum.ResamplerMode.Pixelated end
		object.Parent = self.parent
		entry = {object = object, values = {}}; pool[index] = entry
	end
	apply(self, entry, properties)
	apply(self, entry, {Visible = true})
	if kind == "Frame" then
		if radius ~= nil or entry.corner then
			if not entry.corner then entry.corner = {object = self.factory("UICorner"), values = {}}; entry.corner.object.Parent = entry.object end
			apply(self, entry.corner, {CornerRadius = UDim.new(0, radius or 0)})
		end
		if stroke or entry.stroke then
			if not entry.stroke then entry.stroke = {object = self.factory("UIStroke"), values = {}}; entry.stroke.object.Parent = entry.object end
			apply(self, entry.stroke, {Enabled = stroke ~= nil, Color = if stroke then stroke.color else Color3.new(), Thickness = if stroke then stroke.thickness or 1 else 0})
		end
	end
	return entry.object
end
function GpuScene:image(properties) return self:draw("ImageLabel", properties) end
function GpuScene:frame(properties, radius, stroke) return self:draw("Frame", properties, radius, stroke) end
function GpuScene:finish()
	for i = self.imageCount + 1, #self.images do apply(self, self.images[i], {Visible = false}) end
	for i = self.frameCount + 1, #self.frames do apply(self, self.frames[i], {Visible = false}) end
end
function GpuScene:destroy()
	for _, pool in {self.images, self.frames} do for _, entry in pool do entry.object:Destroy() end; table.clear(pool) end
end
return GpuScene
