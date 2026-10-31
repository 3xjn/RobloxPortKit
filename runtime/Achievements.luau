--!optimize 2
-- Platform-neutral monotonic achievement ledger. Games provide stable IDs and
-- call unlock from their original achievement conditions; save backends merge it.
local Achievements={};Achievements.__index=Achievements
function Achievements.new(definitions,onUnlock)
    local known={};for _,definition in definitions do assert(type(definition.id)=='string' and not known[definition.id],'Duplicate achievement ID');known[definition.id]=definition end
    return setmetatable({known=known,unlocked={},onUnlock=onUnlock},Achievements)
end
function Achievements:has(id)return self.unlocked[id]==true end
function Achievements:unlock(id)
    assert(self.known[id],'Unknown achievement: '..tostring(id))
    if self:has(id) then return false end
    self.unlocked[id]=true;if self.onUnlock then self.onUnlock(self.known[id])end;return true
end
function Achievements:merge(saved)
    for id,value in saved or {} do if value==true and self.known[id] then self.unlocked[id]=true end end
end
function Achievements:snapshot()return table.clone(self.unlocked)end
function Achievements.validate(claims,definitions)
    if type(claims)~='table' then return false end
    local known={};for _,definition in definitions do known[definition.id]=true end
    local result={};for id,value in claims do if not known[id] or value~=true then return false end;result[id]=true end
    return true,result
end
return Achievements
