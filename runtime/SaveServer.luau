-- Server-only service. Domain validation and merge rules are supplied by each port.
local SaveServer = {}
function SaveServer.new(config)
	assert(config.store and config.blank and config.validate and config.merge, "Missing save schema")
	local self = {config = config, sessions = {}, clock = config.clock or os.clock}
	function self:load(key)
		local session = self.sessions[key]
		if session and session.loaded then return {ok = true, data = session.data, revision = session.data.revision or 0} end
		if session and (session.busy or self.clock() - session.last < (config.retrySeconds or 5)) then return {ok = false, error = "retry shortly"} end
		session = session or {id = config.guid(), last = -math.huge, sequence = 0}
		self.sessions[key] = session; session.busy = true; session.last = self.clock()
		local ok, data = pcall(function() return config.store:GetAsync(key) end)
		session.busy = false
		if not ok then return {ok = false, error = tostring(data)} end
		session.loaded = true; session.data = data or config.blank(); session.last = -math.huge
		return {ok = true, data = session.data, revision = session.data.revision or 0}
	end
	function self:commit(key, request, force)
		local session = self.sessions[key]
		if not session or not session.loaded then return {ok = false, error = "save not loaded"} end
		if session.busy then return {ok = false, error = "save busy"} end
		if type(request.sequence) ~= "number" or request.sequence % 1 ~= 0 or request.sequence < 1 or request.sequence > 1e9
			or type(request.revision) ~= "number" or request.revision % 1 ~= 0 or request.revision < 0 or request.revision > 1e12 then return {ok = false, error = "invalid revision"} end
		local valid, payload = config.validate(request.data)
		if not valid then return {ok = false, error = payload or "invalid save"} end
		if request.sequence <= session.sequence then return {ok = true, data = session.data, revision = session.data.revision or 0} end
		if not force and self.clock() - session.last < (config.retrySeconds or 5) then return {ok = false, error = "retry shortly"} end
		session.last = self.clock(); session.busy = true
		-- Keep failed requests for PlayerRemoving/BindToClose. Never save following a failed load.
		session.pending = {action = "save", sequence = request.sequence, revision = request.revision, data = payload}
		local ok, data = pcall(function()
			return config.store:UpdateAsync(key, function(old)
				old = old or config.blank()
				old._portkit = old._portkit or {}
				local receipt = old._portkit[session.id] or 0
				if request.sequence <= receipt then return old end
				local revision = old.revision or 0
				local merged = config.merge(old, payload, session.id)
				merged._portkit = merged._portkit or {}; merged._portkit[session.id] = request.sequence
				-- Client revisions never overwrite newer server state.
				merged.revision = revision + 1
				return merged
			end)
		end)
		session.busy = false
		if not ok then return {ok = false, error = tostring(data)} end
		session.data = data; session.sequence = request.sequence; session.pending = nil
		return {ok = true, data = data, revision = data.revision}
	end
	function self:handle(key, request)
		if type(request) ~= "table" then return {ok = false, error = "invalid request"} end
		if request.action == "load" then return self:load(key) end
		if request.action == "save" then return self:commit(key, request, false) end
		return {ok = false, error = "unknown action"}
	end
	function self:flush(key)
		local session = self.sessions[key]
		local deadline = self.clock() + 20
		while session and session.busy and self.clock() < deadline do task.wait(.05) end
		if session and session.pending and not session.busy then return self:commit(key, session.pending, true) end
	end
	return self
end
function SaveServer.start(config)
	local players = game:GetService("Players")
	local http = game:GetService("HttpService")
	config.store = config.store or game:GetService("DataStoreService"):GetDataStore(assert(config.storeName))
	config.guid = config.guid or function() return http:GenerateGUID(false) end
	local service = SaveServer.new(config)
	local remote = config.parent:FindFirstChild(config.remoteName or "Save") or Instance.new("RemoteFunction")
	assert(remote:IsA("RemoteFunction"), "Save remote name conflicts with a non-RemoteFunction")
	remote.Name = config.remoteName or "Save"; remote.Parent = config.parent
	remote.OnServerInvoke = function(player, request) return service:handle("u" .. player.UserId, request) end
	players.PlayerRemoving:Connect(function(player) local key = "u" .. player.UserId; service:flush(key); service.sessions[key] = nil end)
	game:BindToClose(function()
		local waiting = 0
		for key in service.sessions do waiting += 1; task.spawn(function() service:flush(key); waiting -= 1 end) end
		local deadline = os.clock() + 25
		while waiting > 0 and os.clock() < deadline do task.wait(.05) end
	end)
	return service
end
return SaveServer
