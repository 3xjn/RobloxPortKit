--!optimize 2
-- Sound-shaped source for AudioPool's native Wire graph mode. Playback stays
-- on AudioPlayer; no Sound or software audio substitute is created.
local Source={}
local aliases={SoundId='Asset',IsLoaded='IsReady',Looped='Looping'}
local methods={}
function methods:Play()self.audioNode:Play()end
function methods:Stop()self.audioNode:Stop()end
function methods:Pause()
    local time=self.audioNode.TimePosition
    self.audioNode:Stop();self.audioNode.TimePosition=time;rawset(self,'pausedAt',time)
end
function methods:Resume()
    if rawget(self,'pausedAt')then self.audioNode.TimePosition=self.pausedAt end
    self.audioNode:Play();rawset(self,'pausedAt',nil)
end
function methods:Destroy()self.audioNode:Destroy()end
function Source.new(factory)
    local node=(factory or Instance.new)('AudioPlayer');node.AutoLoad=true
    local self={audioNode=node,defaultRegion=node.PlaybackRegion,defaultLoopRegion=node.LoopRegion,regionsEnabled=false}
    return setmetatable(self,{
        __index=function(t,key)
            if methods[key] then return methods[key]end
            if key=='PlaybackRegionsEnabled'then return t.regionsEnabled end
            return node[aliases[key]or key]
        end,
        __newindex=function(t,key,value)
            if key=='PlaybackRegionsEnabled'then
                rawset(t,'regionsEnabled',value)
                if not value then node.PlaybackRegion=t.defaultRegion;node.LoopRegion=t.defaultLoopRegion end
            else node[aliases[key]or key]=value end
        end,
    })
end
return Source
