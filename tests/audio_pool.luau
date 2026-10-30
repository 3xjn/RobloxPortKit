local Pool=require('../runtime/AudioPool')
local now=0
local sound={TimePosition=0}
function sound:Play()end
function sound:Pause()end
function sound:Resume()end
function sound:Stop()end
function sound:Destroy()end
local pool=Pool.new({parent={},clock=function()return now end,factory=function()return sound end,
 catalog={loop={uri='rbxassetid://1',startSec=10,lengthSec=4,loop=true,loopStartSec=11},shot={uri='rbxassetid://1',startSec=20,lengthSec=1}}})
local h=pool:play('loop',{});h:start();assert(sound.TimePosition==10)
sound.TimePosition=14.5;pool:update();assert(math.abs(sound.TimePosition-11.5)<.001)
h:pause(true);sound.TimePosition=15;pool:update();assert(sound.TimePosition==15)
h:pause(false);pool:update();assert(sound.TimePosition==12)
h:stop();local s=pool:play('shot',{});s:start();sound.TimePosition=21;pool:update();assert(s:state()==2)
pool:destroy();print('audio pool slice checks passed')
local cold={IsLoaded=false,TimePosition=0,plays=0}
function cold:Play()self.plays+=1 end
function cold:Stop()end
function cold:Pause()end
function cold:Resume()end
function cold:Destroy()end
local coldPool=Pool.new({parent={},clock=function()return now end,factory=function()return cold end,
 catalog={ambient={uri='rbxassetid://2',startSec=160.702,lengthSec=12,loop=true}}})
local pending=coldPool:play('ambient',{});pending:start();pending:seek(500);coldPool:update()
assert(cold.plays==0 and cold.TimePosition==0)
pending:pause(true);cold.IsLoaded=true;coldPool:update();assert(cold.plays==0)
pending:pause(false);assert(cold.plays==1 and math.abs(cold.TimePosition-161.202)<.001)
pending:stop();cold.IsLoaded=false;local cancelled=coldPool:play('ambient',{});cancelled:start();cancelled:stop()
cold.IsLoaded=true;coldPool:update();assert(cold.plays==1)
coldPool:destroy()

-- Supply Roblox's NumberRange in a fresh module environment to exercise both
-- successful engine regions and a rejected LoopRegion property in headless Lune.
local fs=require('@lune/fs')
local fn=assert(loadstring(fs.readFile('runtime/AudioPool.luau')))
setfenv(fn,setmetatable({NumberRange={new=function(a,b)return {Min=a,Max=b}end}}, {__index=getfenv()}))
local RegionPool=fn()
local regionSound={TimePosition=0}
function regionSound:Play()end
function regionSound:Stop()end
function regionSound:Destroy()end
local regions=RegionPool.new({parent={},factory=function()return regionSound end,
    catalog={loop={uri='rbxassetid://1',startSec=10,lengthSec=4,loop=true,loopStartSec=11}}})
local native=regions:play('loop',{});native:start();assert(native.hardwareRegions)
regionSound.TimePosition=14.5;regions:update();assert(regionSound.TimePosition==14.5)
native:stop();regions:destroy()
local rejected=setmetatable({TimePosition=0,Play=function()end,Stop=function()end,Destroy=function()end},
    {__newindex=function(t,k,v) if k=='LoopRegion' then error('unsupported') end rawset(t,k,v) end})
local fallback=RegionPool.new({parent={},factory=function()return rejected end,
    catalog={loop={uri='rbxassetid://1',startSec=10,lengthSec=4,loop=true,loopStartSec=11}}})
local soft=fallback:play('loop',{});soft:start();assert(not soft.hardwareRegions and not rejected.PlaybackRegionsEnabled)
rejected.TimePosition=14.5;fallback:update();assert(math.abs(rejected.TimePosition-11.5)<.001)
soft:stop();fallback:destroy()

-- Configured assets must be loaded as typed Sounds. A pending load holds the
-- handle without fabricating playback; terminal failures are recorded without interrupting update
-- or the specific event, while an explicitly disabled event remains silent.
local queued={};local created={};local status='ok';local mode='callback';now=0
local function makeSound()
    local s={IsLoaded=false,TimePosition=0,plays=0,destroyed=false}
    function s:Play()self.plays+=1 end
    function s:Stop()end
    function s:Pause()end
    function s:Resume()end
    function s:Destroy()self.destroyed=true end
    created[#created+1]=s;return s
end
local provider={PreloadAsync=function(_,sounds,callback)
    assert(#sounds==1 and sounds[1].SoundId:match('^rbxassetid://'),'Preload must receive a configured Sound')
    if mode=='throw'then error('synthetic provider failure')end
    if mode~='no_callback'then callback(sounds[1].SoundId,status)end
end}
local strict=Pool.new({parent={},factory=makeSound,clock=function()return now end,contentProvider=provider,
    scheduler={spawn=function(fn)queued[#queued+1]=fn end},successStatus='ok',loadTimeout=3,
    catalog={ready={uri='rbxassetid://3'},broken={uri='rbxassetid://4'},silent={disabled=true},invalid={uri=''}}})
local function stopped(h)
    assert(h.stopped and h:state()==2)
    h:start();h:volume(.5);h:pitch(1.2);h:pause(true);h:pan(.2);h:seek(10);h:position({});h:mixPitch(1);h:release();h:stop()
    assert(h.stopped and h:state()==2 and h:timeline()==0)
end
local function reported(p,expected)
    local found=false
    for _,message in p.errors do if message:find(expected,1,true)then found=true end end
    assert(found,'Missing reported audio error: '..expected)
end
stopped(strict:play('missing',{}));reported(strict,'missing')
stopped(strict:play('invalid',{}));reported(strict,'invalid')
assert(#created==0,'Invalid or missing events must not create a Sound')
local disabled=strict:play('silent',{oneshot=true,lengthMs=500});disabled:start()
now=.6;strict:update();assert(disabled:state()==2 and #created==0)
local audible=strict:play('ready',{});audible:start()
assert(#queued==1 and audible.pending and audible.sound.plays==0)
audible.sound.IsLoaded=true;strict:update();assert(audible.sound.plays==0,'Pending preload must not play')
queued[1]();assert(created[1].destroyed and strict.preloadJobs['rbxassetid://3'].status=='ready')
strict:update();assert(audible.sound.plays==1 and not audible.pending)
audible:stop()
status='failed';local bad=strict:play('broken',{});bad:start();queued[2]()
assert(created[3].destroyed and strict.preloadJobs['rbxassetid://4'].status=='failed')
strict:update();reported(strict,'rbxassetid://4');reported(strict,'broken');stopped(bad)
strict:update();stopped(strict:play('broken',{}))
strict:destroy()
for _,testMode in {'throw','no_callback'}do
    queued={};created={};mode=testMode;status='ok'
    local p=Pool.new({parent={},factory=makeSound,clock=function()return now end,contentProvider=provider,
        scheduler={spawn=function(fn)queued[#queued+1]=fn end},successStatus='ok'})
    p:preload({'rbxassetid://5','rbxassetid://5'});assert(#queued==1)
    queued[1]();assert(created[1].destroyed)
    p:update();reported(p,'rbxassetid://5');p:destroy()
end
queued={};created={};mode='callback';now=0
local timeout=Pool.new({parent={},factory=makeSound,clock=function()return now end,contentProvider=provider,
    scheduler={spawn=function(fn)queued[#queued+1]=fn end},successStatus='ok',loadTimeout=2})
timeout:preload({'rbxassetid://6'});now=2
timeout:update();reported(timeout,'rbxassetid://6');timeout:destroy();queued[1]()
assert(created[1].destroyed,'In-flight preload cleans up after disposal')
local muted=Pool.new({enabled=false,parent={},factory=function()error('disabled audio created a Sound')end})
local mutedHandle=muted:play('any-event',{});mutedHandle:start();assert(not mutedHandle.sound);muted:destroy()
now=0;queued={};created={}
local unready=Pool.new({parent={},factory=makeSound,clock=function()return now end,contentProvider=provider,
    scheduler={spawn=function(fn)queued[#queued+1]=fn end},successStatus='ok',loadTimeout=2,
    catalog={late={uri='rbxassetid://7'}}})
local late=unready:play('late',{});late:start();queued[1]();now=2
unready:update();reported(unready,'late');stopped(late);unready:destroy()
print('PASS configured audio load failures, typed preload, pending, timeout, disabled and cleanup')
