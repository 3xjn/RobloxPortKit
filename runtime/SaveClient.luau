local SaveClient = {}
SaveClient.__index = SaveClient
function SaveClient.new(config)
	assert(config.remote and config.snapshot and config.apply, "SaveClient requires remote, snapshot and apply")
	return setmetatable({config = config, remote = config.remote, loaded = false, busy = false,
		alive = true, revision = 0, sequence = 0, pending = nil, errors = {}}, SaveClient)
end
function SaveClient:status(message)
	self.lastStatus = message
	if self.config.onStatus then self.config.onStatus(message) end
end
function SaveClient:setBusy(value)
	self.busy=value
	if self.config.onBusy then self.config.onBusy(value) end
end
function SaveClient:sync()
	if not self.alive or self.busy then return false end
	self:setBusy(true)
	local loading = not self.loaded
	if not loading and not self.pending then
		self.sequence += 1
		self.pending = {action = "save", sequence = self.sequence, revision = self.revision, data = self.config.snapshot()}
	end
	local request = if loading then {action = "load"} else self.pending
	local ok, result = pcall(function() return self.remote:InvokeServer(request) end)
	if not ok then
		local message = 'Cloud save request failed: '..tostring(result)
		self.errors[#self.errors+1] = message; warn(message)
	end
	if not self.alive then self:setBusy(false); return false end
	if ok and type(result) == "table" and result.ok then
		self.loaded = true; self.revision = result.revision or self.revision
		self.config.apply(result.data, if loading then nil else request.data)
		if not loading then self.pending = nil end
		self:status("Cloud saved")
	else
		self:status(if self.config.isStudio then "Offline — Studio cloud save unavailable. Sync Now to retry." else "Offline — Sync Now to retry.")
	end
	self:setBusy(false)
	return ok and type(result) == "table" and result.ok == true
end
function SaveClient:start()
	task.spawn(function()
		self:sync()
		while self.alive do
			task.wait(self.config.interval or 30)
			if self.alive and (not self.loaded or self.pending or not self.config.isDirty or self.config.isDirty()) then self:sync() end
		end
	end)
end
function SaveClient:destroy() self.alive = false end
return SaveClient
