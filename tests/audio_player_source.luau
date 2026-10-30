local Source=require('../runtime/AudioPlayerSource')
local Graph=require('../runtime/AudioBusGraph')
local fs=require('@lune/fs');local rbx=require('@lune/roblox')
local create=assert(loadstring('return function(NumberRange,script,require)\n'..fs.readFile('runtime/AudioPool.luau')..'\nend'))()
local Pool=create(rbx.NumberRange,{Parent={AudioPlayerSource='source'}},function(name)assert(name=='source');return Source end)
local now=0;local nodes={}
local function factory(kind)
    assert(kind=='AudioPlayer','Wireable sources must never allocate Sounds')
    local node={ClassName=kind,TimePosition=0,IsReady=true,PlaybackRegion=rbx.NumberRange.new(0,60000),LoopRegion=rbx.NumberRange.new(0,60000)}
    function node:GetOutputPins()return {'Output'}end
    function node:Play()self.plays=(self.plays or 0)+1 end
    function node:Stop()self.stops=(self.stops or 0)+1;self.TimePosition=0 end
    function node:Destroy()self.destroyed=true end
    nodes[#nodes+1]=node;return node
end
local pool=Pool.new({parent={},wireable=true,instanceFactory=factory,clock=function()return now end,
    catalog={loop={uri='rbxassetid://123',startSec=10,lengthSec=4,loop=true,loopStartSec=11}}})
local graph=Graph.new({buses={music='input'},pitchRoutes={music={'music','master'}},nodes={input={className='AudioFader'},out={className='AudioDeviceOutput'}},
    wires={{source='input',target='out'}}},{parent={},factory=function(kind)return {ClassName=kind,
        GetOutputPins=function()return {'Output'}end,GetInputPins=function()return {'Input'}end,
        Destroy=function(self)self.destroyed=true end}end})
pool.audioGraph=graph
local h=pool:play('loop',{bus='music'});local node=h.audioNode
assert(node==nodes[1] and node.Asset=='rbxassetid://123' and node.Looping==true and node.AutoLoad)
graph:commit({music={pitch=1},master={pitch=1}})
assert(graph.attached[h],'A parameter/control commit before start must preserve the pending source route')
graph:route(h,'music');local wire=graph.attached[h]
h:start();assert(h.hardwareRegions and node.PlaybackRegion.Min==10 and node.PlaybackRegion.Max==14 and node.LoopRegion.Min==11)
assert(node.plays==1 and node.TimePosition==10)
node.TimePosition=12.5;h:pause(true);assert(node.TimePosition==12.5)
h:pause(false);assert(node.TimePosition==12.5 and node.plays==2)
h:seek(750);assert(node.TimePosition==10.75)
h:volume(.4);h:pitch(.8);assert(node.Volume==.4 and node.PlaybackSpeed==.8)
graph:commit({music={pitch=2},master={pitch=.5}});assert(node.PlaybackSpeed==.8)
graph:commit({music={pitch=2},master={pitch=1}});assert(node.PlaybackSpeed==1.6)
h:pitch(.5);assert(node.PlaybackSpeed==1)
assert(h:timeline()==750)
h:stop();assert(wire.destroyed and not graph.attached[h] and node.Parent==nil)
local nextVoice=pool:play('loop',{bus='music'});assert(nextVoice.audioNode==node and #nodes==1)
graph:route(nextVoice,'music');nextVoice:start();nextVoice:stop()
pool:destroy();graph:destroy();assert(node.destroyed)
print('PASS AudioPool native AudioPlayer sources, hardware slices/loops, graph route/recycle, pause/resume, seek and zero Sound allocations')

local loads=Pool.new({parent={},wireable=true,instanceFactory=factory,clock=function()return now end,
    scheduler={spawn=function(fn)fn()end},successStatus='ok',
    contentProvider={PreloadAsync=function(_,sources,callback)
        assert(sources[1].ClassName=='AudioPlayer','Preload the native node rather than its adapter')
        callback(sources[1].Asset,if sources[1].Asset=='rbxassetid://bad'then 'failed'else 'ok')
    end},catalog={bad={uri='rbxassetid://bad'},good={uri='rbxassetid://good'}}})
local failed=loads:play('bad',{});assert(failed.stopped and failed:state()==2)
failed:start();failed:volume(.5);failed:pitch(1);failed:stop();assert(failed.stopped)
local healthy=loads:play('good',{});healthy:start()
assert(pcall(function()loads:update()end)and healthy:state()==0 and healthy.audioNode.plays>0 and #loads.errors>0)
loads:destroy()
print('PASS native preload failures are recorded and do not block healthy audio updates')
