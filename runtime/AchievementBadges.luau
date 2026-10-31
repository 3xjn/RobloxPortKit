--!optimize 2
-- Call only after game progress has passed the port's server validation.
local Badges={}
function Badges.new(mapping,service)
    service=service or game:GetService('BadgeService')
    local self={mapping=mapping,awarded={},pending={},errors={}}
    function self:sync(userId,unlocked)
        local receipts=self.awarded[userId] or {};self.awarded[userId]=receipts
        local result={awarded={},unmapped={},failed={}}
        for id,value in unlocked do
            if value~=true then continue end
            local badgeId=self.mapping[id]
            if not badgeId then table.insert(result.unmapped,id);continue end
            if receipts[id] then continue end
            local ok,awarded=pcall(function()
                if service:UserHasBadgeAsync(userId,badgeId) then return true end
                return service:AwardBadgeAsync(userId,badgeId)
            end)
            if ok and awarded then receipts[id]=true;table.insert(result.awarded,id)
            else
                table.insert(result.failed,id)
                if not ok then
                    local message='Badge '..tostring(id)..' failed: '..tostring(awarded)
                    self.errors[#self.errors+1]=message;warn(message)
                end
            end
        end
        return result
    end
    return self
end
return Badges
