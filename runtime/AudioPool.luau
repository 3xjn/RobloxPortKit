-- Reusable event sounds. The host calls update once per frame to enforce atlas boundaries.
local AudioPool={};AudioPool.__index=AudioPool
local Handle={};Handle.__index=Handle
-- Failed voices stay stopped even if a caller tries to restart or configure them.
local Stopped={};Stopped.__index=Stopped
local function noop()end
for _,name in {'start','stop','pause','volume','pitch','pan','mixPitch','seek','position','release'}do Stopped[name]=noop end
function Stopped:state()return 2 end
function Stopped:timeline()return 0 end
function AudioPool:failedHandle(path,message)
    self:reportError(message)
    return setmetatable({pool=self,path=path,stopped=true,playing=false,paused=false},Stopped)
end
function Handle:_fail(message)
    self.pool:reportError(message);self:stop();self.pending=false;setmetatable(self,Stopped)
end
function AudioPool.new(options)
    options=options or {}
    local factory=options.factory
    if options.wireable then
        assert(not factory,'Use instanceFactory for wireable AudioPool sources')
        local Source=if script then require(script.Parent.AudioPlayerSource)else require('./AudioPlayerSource')
        factory=function()return Source.new(options.instanceFactory)end
    end
    local self=setmetatable({catalog=options.catalog or {},metadata=options.metadata or {},free={},active={},
        parent=options.parent or game:GetService('SoundService'),factory=factory or function()return Instance.new('Sound')end,
        clock=options.clock or os.clock,spatial=options.spatial,enabled=options.enabled~=false,wireable=options.wireable==true,errors=options.errors or {},audioGraph=options.audioGraph,
        contentProvider=options.contentProvider,scheduler=options.scheduler,
        successStatus=options.successStatus,loadTimeout=options.loadTimeout or 30,
        preloadJobs={},pendingPreloads={},preloadFailures={},reportedErrors={},disposed=false},AudioPool)
    assert(type(self.loadTimeout)=='number' and self.loadTimeout>0,'Audio load timeout must be positive')
    return self
end
function AudioPool:reportError(message)
    message='[PORT-ERROR] '..tostring(message)
    if not self.reportedErrors[message]then
        self.reportedErrors[message]=true;self.errors[#self.errors+1]=message;warn(message)
    end
end
function AudioPool:describe(path)return self.metadata[path]end
function AudioPool:preload(uris)
    if not self.enabled then return end
    local provider=self.contentProvider or (game and game:GetService('ContentProvider'))
    local scheduler=self.scheduler or task
    assert(provider and scheduler and scheduler.spawn,'Audio preloading requires a content provider and scheduler')
    local success=self.successStatus or Enum.AssetFetchStatus.Success
    for _,uri in uris do
        assert(type(uri)=='string' and uri~='','Invalid configured audio preload URI')
        if not self.preloadJobs[uri] then
            local sound
            local acquired,acquireError=pcall(function()
                sound=self.factory();assert(sound,'Audio source factory returned no source')
                sound.SoundId=uri;sound.Parent=self.parent
            end)
            if not acquired then
                local message='Published audio preload source failed for '..uri..': '..tostring(acquireError)
                if sound then
                    local cleaned,cleanupError=pcall(function()sound:Destroy()end)
                    if not cleaned then self:reportError('Audio preload cleanup failed for '..uri..': '..tostring(cleanupError))end
                end
                self.preloadJobs[uri]={status='failed',uri=uri,error=message,events={}}
                self.preloadFailures[uri]=message;self:reportError(message)
                continue
            end
            local job={status='pending',uri=uri,sound=sound,started=self.clock(),events={}};self.preloadJobs[uri]=job;self.pendingPreloads[uri]=job
            scheduler.spawn(function()
                if self.disposed then job.status='cancelled';self.pendingPreloads[uri]=nil;return end
                local seen,failed=false,nil
                local ok,err=pcall(function()
                    provider:PreloadAsync({if self.wireable then sound.audioNode else sound},function(_,status)
                        seen=true
                        if status~=success then failed=tostring(status)end
                    end)
                    assert(seen,'no asset fetch status was reported')
                    assert(not failed,'asset fetch status '..tostring(failed))
                end)
                local cleaned,cleanupError=true,nil
                if job.sound then cleaned,cleanupError=pcall(function()job.sound:Destroy()end);job.sound=nil end
                self.pendingPreloads[uri]=nil
                if not cleaned and ok then ok=false;err=cleanupError end
                if self.disposed then job.status='cancelled';return end
                if ok then job.status='ready'
                else
                    local message='Published audio preload failed for '..uri..': '..tostring(err)
                    job.status='failed';job.error=message;self.preloadFailures[uri]=message
                    self:reportError(message)
                end
            end)
        end
    end
end
function AudioPool:play(path,info)
    if type(path)~='string' or path=='' then return self:failedHandle(path,'Invalid audio event path: '..tostring(path))end
    local entry=if self.enabled then self.catalog[path] else {disabled=true}
    if type(entry)~='table' then return self:failedHandle(path,'Missing published audio binding for event '..path)end
    if entry.failed then return self:failedHandle(path,'Audio slice load failed for event '..path..': '..tostring(entry.failed))end
    if entry.disabled~=true then
        if type(entry.uri)~='string' or entry.uri=='' then
            return self:failedHandle(path,'Invalid published audio binding for event '..path)
        end
        local failure=self.preloadFailures[entry.uri]
        if failure then return self:failedHandle(path,'Audio event '..path..': '..failure)end
    end
    local h=setmetatable({pool=self,entry=entry,path=path,info=info or {},playing=false,paused=false,elapsed=0,speed=1,gain=1},Handle)
    -- Source creation, property binding and graph routing can all reject a backend.
    -- Never leak a partially configured source into the reusable pool.
    local ok,err=pcall(function()
        if entry.disabled~=true then
            if self.contentProvider or game then self:preload({entry.uri})end
            local job=self.preloadJobs[entry.uri]
            if job then
                job.events[path]=true
                if job.status=='failed'then error(job.error,0)end
            end
            local sound=table.remove(self.free) or self.factory();h.sound=sound
            assert(sound,'Audio source factory returned no source')
            if self.wireable then h.audioNode=sound.audioNode end
            sound.Parent=self.parent;sound.SoundId=entry.uri;sound.Looped=entry.loop==true
        end
        if self.audioGraph and h.audioNode then
            self.audioGraph:route(h,assert(h.info.bus,'Missing explicit native audio bus for '..path))
        end
    end)
    if not ok then
        if self.audioGraph and h.audioNode then
            local detached,detachError=pcall(function()self.audioGraph:detach(h)end)
            if not detached then self:reportError('Audio route cleanup failed for '..path..': '..tostring(detachError))end
        end
        if h.sound then
            local cleaned,cleanupError=pcall(function()h.sound:Destroy()end)
            if not cleaned then self:reportError('Audio source cleanup failed for '..path..': '..tostring(cleanupError))end
        end
        return self:failedHandle(path,'Audio event '..path..': '..tostring(err))
    end
    self.active[h]=true
    return h
end
function Handle:start()
    self.playing=true;self.stopped=false;self.elapsed=0;self.started=self.pool.clock()
    self.pending=self.sound~=nil
    self.pendingSince=self.pool.clock()
    if self.pending and not self.paused and self:_ready() then self:_startLoaded()end
end
function Handle:_ready()
    local pool=self.pool;local uri=self.entry.uri
    local failed=pool.preloadFailures[uri]
    if failed then
        self:_fail('Audio event '..self.path..': '..failed);return false
    end
    local job=pool.preloadJobs[uri]
    if job and job.status=='pending' then
        if pool.clock()-job.started>=pool.loadTimeout then
            local message='Audio event '..self.path..' ('..uri..') preload exceeded '..tostring(pool.loadTimeout)..' seconds'
            self:_fail(message);return false
        end
        return false
    end
    if self.sound.IsLoaded~=false then return true end
    if pool.clock()-self.pendingSince>=pool.loadTimeout then
        local message='Audio event '..self.path..' ('..uri..') did not load within '..tostring(pool.loadTimeout)..' seconds'
        self:_fail(message);return false
    end
    return false
end
function Handle:_startLoaded()
    local sound=self.sound;local entry=self.entry;local start=entry.startSec or 0
    self.hardwareRegions=false
    if NumberRange then
        local ok,err=pcall(function()
            sound.PlaybackRegionsEnabled=entry.lengthSec~=nil and entry.lengthSec>0
            if sound.PlaybackRegionsEnabled then
                local finish=start+entry.lengthSec
                sound.PlaybackRegion=NumberRange.new(start,finish)
                sound.LoopRegion=NumberRange.new(entry.loopStartSec or start,finish)
            end
        end)
        self.hardwareRegions=ok and entry.lengthSec~=nil and entry.lengthSec>0
        if not ok then
            if self.audioNode then
                self.pool:reportError('Native audio playback regions failed for '..self.path..': '..tostring(err));self:stop();return
            end
            warn('Audio playback region configuration failed: '..tostring(err))
            local resetOk,resetErr=pcall(function() sound.PlaybackRegionsEnabled=false end)
            if not resetOk then warn('Audio playback region reset failed: '..tostring(resetErr)) end
        end
    end
    sound.PlaybackSpeed=self.speed;sound.Volume=self.gain*(entry.volume or 1)
    if not entry.loop and sound.Ended then
        self.endedConnection=sound.Ended:Connect(function()self:stop()end)
    end
    sound.TimePosition=start+self.elapsed;sound:Play();self.pending=false;self.started=self.pool.clock()
end
function Handle:stop()
    if self.stopped then return end
    self.playing=false;self.stopped=true;self.pool.active[self]=nil
    if self.audioGraph then self.audioGraph:detach(self)end
    if self.endedConnection then self.endedConnection:Disconnect();self.endedConnection=nil end
    if self.sound then self.sound:Stop();self.sound.Parent=nil;table.insert(self.pool.free,self.sound);self.sound=nil end
    if self.emitter then self.emitter:Destroy();self.emitter=nil end
end
function Handle:release()end
function Handle:pause(value)
    value=not not value;if value==self.paused then return end
    if self.playing and not self.paused and not self.pending then self.elapsed+=(self.pool.clock()-self.started)*self.speed end
    self.started=self.pool.clock();self.paused=value
    if self.sound then
        if self.pending then if not value and self:_ready()then self:_startLoaded()end
        elseif value then self.sound:Pause() else self.sound:Resume() end
    end
end
function Handle:volume(value)
    local effective=value*(self.entry.volume or 1)
    if self.audioNode then assert(effective==effective and effective>=0 and effective<=10,'Native audio volume outside [0,10]')end
    self.gain=value;if self.sound then self.sound.Volume=effective end
end
function Handle:pitch(value)
    local effective=value*(self.busPitch or 1)
    if self.audioNode then assert(effective==effective and effective>=0 and effective<=20,'Native audio speed outside [0,20]')end
    if self.playing and not self.paused and not self.pending then self.elapsed+=(self.pool.clock()-self.started)*self.speed;self.started=self.pool.clock() end
    self.userPitch=value;self.speed=effective
    if self.sound then self.sound.PlaybackSpeed=self.speed end
end
function Handle:mixPitch(value)self.busPitch=value;self:pitch(self.userPitch or 1)end
function Handle:timeline()
    if self.sound and not self.pending then return (self.sound.TimePosition-(self.entry.startSec or 0))*1000 end
    return (self.elapsed+((self.playing and not self.paused and not self.pending)and (self.pool.clock()-self.started)*self.speed or 0))*1000
end
function Handle:seek(ms)
    self.elapsed=ms/1000;self.started=self.pool.clock()
    if self.sound and not self.pending then self.sound.TimePosition=(self.entry.startSec or 0)+self.elapsed end
end
function Handle:position(attributes)self.attributes=attributes;self.pool:_position(self)end
function AudioPool:listener(attributes)self.listenerAttributes=attributes;for h in self.active do self:_position(h)end end
function AudioPool:_position(h)
    if not h.sound or not h.attributes or not self.listenerAttributes then return end
    if self.spatial then self.spatial(h,self.listenerAttributes);return end
    assert(not h.audioNode,'Wireable spatial audio requires an authored AudioEmitter/AudioListener route')
    -- Place a point source relative to the actual camera listener. Roblox applies
    -- its normal distance rolloff and stereo panning to a Sound under a Part.
    local camera=workspace.CurrentCamera;if not camera then return end
    local p=h.attributes.position;local l=self.listenerAttributes.position
    if not p or not l then return end
    if not h.emitter then
        local part=Instance.new('Part');part.Name='AudioEmitter';part.Anchored=true;part.CanCollide=false
        part.CanQuery=false;part.CanTouch=false;part.Transparency=1;part.Size=Vector3.new(.05,.05,.05);part.Parent=workspace
        h.emitter=part;h.sound.Parent=part
    end
    local dx,dy,dz=p.x-l.x,p.y-l.y,p.z-l.z
    local forward=self.listenerAttributes.forward;local up=self.listenerAttributes.up
    local x,y,z=dx,dy,dz
    if forward and up then
        local fx,fy,fz=forward.x,forward.y,forward.z
        local ux,uy,uz=up.x,up.y,up.z
        local rx,ry,rz=uy*fz-uz*fy,uz*fx-ux*fz,ux*fy-uy*fx
        if rx*rx+ry*ry+rz*rz>0 and fx*fx+fy*fy+fz*fz>0 then
            x=dx*rx+dy*ry+dz*rz;y=dx*ux+dy*uy+dz*uz;z=-(dx*fx+dy*fy+dz*fz)
        end
    end
    h.emitter.Position=camera.CFrame:PointToWorldSpace(Vector3.new(x,y,z))
end
function Handle:state()
    if not self.playing or self.stopped then return 2 end
    return 0
end
function AudioPool:update()
    local failedUri,failure=next(self.preloadFailures)
    if failure then
        local job=self.preloadJobs[failedUri];local event=job and next(job.events)
        local message=(if event then 'Audio event '..event..': ' else '')..failure
        self:reportError(message)
    end
    local now=self.clock()
    for uri,job in self.pendingPreloads do
        if job.status=='pending' and now-job.started>=self.loadTimeout then
            local event=next(job.events)
            local message=(if event then 'Audio event '..event..': ' else '')..'Published audio preload for '..uri..' exceeded '..tostring(self.loadTimeout)..' seconds'
            self:reportError(message);job.status='failed';job.error=message
            self.preloadFailures[uri]=message;self.pendingPreloads[uri]=nil
            if job.sound then
                local ok,err=pcall(function()job.sound:Destroy()end);job.sound=nil
                if not ok then self:reportError('Audio preload cleanup failed for '..uri..': '..tostring(err))end
            end
        end
    end
    for h in self.active do
        if h.pending and h.playing and h:_ready() and not h.paused then h:_startLoaded()end
        if h.playing and not h.paused and not h.pending then
            local length=h.entry.lengthSec or ((h.info.oneshot and (h.info.lengthMs or 0)>0) and h.info.lengthMs/1000 or nil)
            local pos=if h.sound then h.sound.TimePosition-(h.entry.startSec or 0) else h.elapsed+(now-h.started)*h.speed
            if length and length>0 and pos>=length then
                if h.entry.loop and not h.hardwareRegions then
                    local start=(h.entry.loopStartSec or h.entry.startSec or 0)-(h.entry.startSec or 0)
                    local span=length-start
                    local wrapped=if span>0 then start+(pos-length)%span else start
                    h.elapsed=wrapped;h.started=now;if h.sound then h.sound.TimePosition=(h.entry.startSec or 0)+wrapped end
                elseif not h.entry.loop then h:stop() end
            end
            if h.emitter then self:_position(h)end
        end
    end
end
function AudioPool:destroy()
    self.disposed=true
    for _,job in self.pendingPreloads do
        if job.sound then job.sound:Destroy();job.sound=nil end
        job.status='cancelled'
    end
    table.clear(self.pendingPreloads)
    for h in self.active do h:stop()end
    for _,sound in self.free do sound:Destroy()end;table.clear(self.free)
end
return AudioPool
