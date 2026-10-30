local fs=require('@lune/fs')
local Source=require('../runtime/AudioPlayerSource')
local warnings={}
local create=assert(loadstring('return function(script,require,warn)\n'..fs.readFile('runtime/AudioPool.luau')..'\nend'))()
local Pool=create({Parent={AudioPlayerSource='source'}},function()return Source end,function(message)
    assert(message:sub(1,13)=='[PORT-ERROR] ')
    warnings[#warnings+1]=message
end)
local function stopped(h)
    assert(h.stopped==true and h:state()==2 and not h.playing)
    h:start();h:volume(.5);h:pitch(1.5);h:pan(.5);h:pause(true);h:pause(false)
    h:seek(50);h:position({});h:mixPitch(2);h:release();h:stop();h:start()
    assert(h.stopped==true and h:state()==2 and h:timeline()==0 and not h.playing)
end
for _,wireable in {false,true}do
    local made=0
    local function source()
        made+=1
        return {TimePosition=0,Play=function()end,Stop=function()end,Destroy=function(self)self.destroyed=true end}
    end
    local function options(factory)
        local result={parent={},wireable=wireable}
        if wireable then result.instanceFactory=factory else result.factory=factory end
        return result
    end
    local config=options(source)
    config.catalog={empty={uri=''},wrong={uri=42},noUri={},failed={uri='test://fixture',failed=true},malformed=false}
    local pool=Pool.new(config)
    for _,path in {'missing','empty','wrong','noUri','failed','malformed',''}do
        local count=#pool.errors;local warned=#warnings
        -- Any thrown error fails the test; each repeated message warns and records once.
        stopped(pool:play(path));assert(#pool.errors==count+1 and #warnings==warned+1)
        stopped(pool:play(path));assert(#pool.errors==count+1 and #warnings==warned+1)
    end
    stopped(pool:play(nil));assert(made==0 and next(pool.active)==nil)
    pool:destroy()

    for _,failure in {'throw','nil','binding'}do
        local broken
        local config=options(function()
            if failure=='throw'then error('source acquisition rejected')end
            if failure=='nil'then return nil end
            broken=setmetatable({Destroy=function(self)self.destroyed=true end},{__newindex=function(t,k,v)
                if k=='SoundId' or k=='Asset'then error('published binding rejected')end
                rawset(t,k,v)
            end})
            return broken
        end)
        config.catalog={event={uri='test://fixture'}}
        local pool=Pool.new(config)
        stopped(pool:play('event'));assert(#pool.errors>0 and next(pool.active)==nil and #pool.free==0)
        if broken then assert(broken.destroyed,'Rejected source must be destroyed')end
        pool:destroy()

        -- Preload acquisition uses the same source factory and must also clean up.
        config.contentProvider={PreloadAsync=function()error('Rejected source reached provider')end}
        config.scheduler={spawn=function(fn)fn()end};config.successStatus='ok'
        local preload=Pool.new(config)
        stopped(preload:play('event'));assert(#preload.errors>0 and next(preload.active)==nil)
        assert(preload.preloadJobs['test://fixture'].status=='failed')
        if broken then assert(broken.destroyed)end
        preload:destroy()
    end

    -- Keep fixture URIs accepted, and a failed event must not block healthy audio.
    local config=options(source)
    config.catalog={bad={uri='test://bad'},good={uri='test://fixture'}}
    local pool=Pool.new(config)
    pool.preloadFailures['test://bad']='synthetic asset failure'
    stopped(pool:play('bad'));assert(#pool.errors==1)
    local healthy=pool:play('good');healthy:start();pool:update();assert(healthy:state()==0)
    pool:destroy()
end
print('PASS Sound and AudioPlayer binding/acquisition failures: stopped no-op handles, deduplicated warnings/errors, cleanup and healthy playback')

