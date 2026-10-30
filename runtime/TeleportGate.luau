-- Server-side inbound teleport gate (Mode 1 default: allow direct joins, reject unapproved third-party teleports).
local TeleportGate = {}

local DEFAULT_KICK_MESSAGE = "Incoming teleports from unauthorized experiences are not permitted. Please join this experience directly from Roblox."

local function toIdSet(values)
	local set = {}
	if type(values) ~= "table" then return set end
	for k, v in pairs(values) do
		if type(k) == "number" and k > 0 and math.floor(k) == k then
			if type(v) == "number" and v > 0 and math.floor(v) == v then
				set[v] = true
			elseif v == true then
				set[k] = true
			end
		end
	end
	return set
end

local function hasEntries(tbl)
	return next(tbl) ~= nil
end

local function normalizePositiveInt(value)
	if type(value) == "number" and value > 0 and math.floor(value) == value then
		return value
	end
	return nil
end

function TeleportGate.new(config)
	config = config or {}
	local allowedPlaces = toIdSet(config.allowedPlaceIds)
	local allowedUniverses = toIdSet(config.allowedUniverseIds)
	local allowedGroups = toIdSet(config.allowedGroupIds)
	local allowedUsers = toIdSet(config.allowedCreatorUserIds)

	local allowDirectJoin = config.allowDirectJoin ~= false
	local allowStudio = config.allowStudio ~= false
	local allowSameCreator = config.allowSameCreator ~= false
	local gameId = normalizePositiveInt(config.gameId)
	local placeId = normalizePositiveInt(config.placeId)

	if allowSameCreator then
		local creatorId = normalizePositiveInt(config.creatorId)
		local creatorType = config.creatorType
		if creatorId then
			if creatorType == "Group" or (typeof and typeof(creatorType) == "EnumItem" and creatorType.Name == "Group") or (type(creatorType) == "table" and creatorType.Name == "Group") then
				allowedGroups[creatorId] = true
			elseif creatorType == "User" or (typeof and typeof(creatorType) == "EnumItem" and creatorType.Name == "User") or (type(creatorType) == "table" and creatorType.Name == "User") then
				allowedUsers[creatorId] = true
			end
		end
	end

	local self = {
		config = config,
		kickMessage = config.kickMessage or DEFAULT_KICK_MESSAGE,
		creatorCache = {},
		blockedUsers = {},
	}

	local function resolvePlaceCreator(sourcePlaceId)
		local cached = self.creatorCache[sourcePlaceId]
		if cached then return cached end
		local lookup = config.getPlaceInfo
		if not lookup then return nil end
		local ok, info = pcall(lookup, sourcePlaceId)
		if not ok or type(info) ~= "table" or type(info.Creator) ~= "table" then
			local detail = not ok and tostring(info) or "missing Creator metadata"
			if config.onWarn then
				config.onWarn(("TeleportGate failed to inspect source place %d: %s"):format(sourcePlaceId, detail))
			else
				warn(("TeleportGate failed to inspect source place %d: %s"):format(sourcePlaceId, detail))
			end
			return nil
		end
		local ctype = info.Creator.CreatorType
		local targetId = normalizePositiveInt(info.Creator.CreatorTargetId)
			or (ctype == "User" and normalizePositiveInt(info.Creator.Id) or nil)
		if (ctype == "Group" or ctype == "User") and targetId then
			local record = {creatorType = ctype, creatorId = targetId}
			self.creatorCache[sourcePlaceId] = record
			return record
		end
		return nil
	end

	function self:evaluate(joinData, context)
		if allowStudio and (context and context.isStudio or config.isStudio) then
			return true, "studio"
		end
		if type(joinData) ~= "table" then
			if allowDirectJoin then return true, "direct" end
			return false, "join_data_unavailable"
		end

		local sourcePlaceId = normalizePositiveInt(joinData.SourcePlaceId)
		local sourceGameId = normalizePositiveInt(joinData.SourceGameId)

		if not sourcePlaceId and not sourceGameId then
			if allowDirectJoin then return true, "direct" end
			return false, "direct_join_disallowed"
		end

		if (gameId and sourceGameId == gameId) or (placeId and sourcePlaceId == placeId) then
			return true, "same_experience"
		end
		if sourcePlaceId and allowedPlaces[sourcePlaceId] then
			return true, "allowed_place"
		end
		if sourceGameId and allowedUniverses[sourceGameId] then
			return true, "allowed_universe"
		end

		if sourcePlaceId and (hasEntries(allowedGroups) or hasEntries(allowedUsers)) then
			local creator = resolvePlaceCreator(sourcePlaceId)
			if creator then
				if creator.creatorType == "Group" and allowedGroups[creator.creatorId] then
					return true, "allowed_group"
				end
				if creator.creatorType == "User" and allowedUsers[creator.creatorId] then
					return true, "allowed_creator_user"
				end
			end
		end

		return false, "unauthorized_teleport"
	end

	function self:checkPlayer(player)
		local ok, joinData = pcall(function() return player:GetJoinData() end)
		if not ok then
			local detail = tostring(joinData)
			if config.onWarn then
				config.onWarn(("TeleportGate GetJoinData failed for user %s: %s"):format(tostring(player.UserId), detail))
			else
				warn(("TeleportGate GetJoinData failed for user %s: %s"):format(tostring(player.UserId), detail))
			end
			self.blockedUsers[player.UserId] = true
			pcall(function() player:Kick(self.kickMessage) end)
			return false, "join_data_error"
		end

		local allowed, reason = self:evaluate(joinData)
		if allowed then
			self.blockedUsers[player.UserId] = nil
			return true, reason
		end

		self.blockedUsers[player.UserId] = true
		local srcPlace = type(joinData) == "table" and tostring(joinData.SourcePlaceId) or "nil"
		local srcGame = type(joinData) == "table" and tostring(joinData.SourceGameId) or "nil"
		local msg = ("TeleportGate blocked user %s (reason=%s, SourcePlaceId=%s, SourceGameId=%s)"):format(
			tostring(player.UserId), tostring(reason), srcPlace, srcGame
		)
		if config.onWarn then config.onWarn(msg) else warn(msg) end
		pcall(function() player:Kick(self.kickMessage) end)
		return false, reason
	end

	function self:isAuthorized(player)
		if not player then return false end
		return not self.blockedUsers[player.UserId]
	end

	function self:clearPlayer(player)
		if player and player.UserId then
			self.blockedUsers[player.UserId] = nil
		end
	end

	return self
end

function TeleportGate.start(config)
	config = table.clone(config or {})
	local players = config.players or game:GetService("Players")
	local runService = config.runService or game:GetService("RunService")
	local marketplace = config.marketplace or game:GetService("MarketplaceService")

	if config.isStudio == nil then config.isStudio = runService:IsStudio() end
	if config.gameId == nil then config.gameId = game.GameId end
	if config.placeId == nil then config.placeId = game.PlaceId end
	if config.creatorId == nil then config.creatorId = game.CreatorId end
	if config.creatorType == nil then config.creatorType = game.CreatorType end
	if not config.getPlaceInfo then
		config.getPlaceInfo = function(placeId)
			return marketplace:GetProductInfo(placeId, Enum.InfoType.Asset)
		end
	end

	local gate = TeleportGate.new(config)
	local addedConn = players.PlayerAdded:Connect(function(player)
		gate:checkPlayer(player)
	end)
	local removingConn = players.PlayerRemoving:Connect(function(player)
		gate:clearPlayer(player)
	end)
	for _, player in players:GetPlayers() do
		task.spawn(function() gate:checkPlayer(player) end)
	end
	function gate:destroy()
		addedConn:Disconnect()
		removingConn:Disconnect()
	end
	return gate
end

return TeleportGate
