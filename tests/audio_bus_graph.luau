local Graph=require('../runtime/AudioBusGraph')
local made={};local writes=0;local destroyed=0
local function factory(kind)
    local values={ClassName=kind,GetOutputPins=function()return if kind=='AudioDeviceOutput'then {}else {'Output'}end,
        GetInputPins=function()return if kind=='AudioPlayer'then {}else {'Input','Sidechain'}end,Destroy=function(self)
        if not self.destroyed then self.destroyed=true;destroyed+=1 end
    end}
    local instance=setmetatable({}, {__index=values,__newindex=function(_,key,value)writes+=1;values[key]=value end})
    made[#made+1]=instance;return instance
end
local function dsp(index,kind,parameter,scale)
    return {bus='bus:/music',dsp=index,type=kind,parameter=parameter,scale=scale}
end
local spec={buses={['bus:/music']='input',['bus:/']='master'},nodes={
    input={className='AudioFader',bindings={Volume={bus='bus:/music',field='finalVolume',min=0,max=10}}},
    lowpass={className='AudioFilter',properties={FilterType='Lowpass24dB'},bindings={Frequency=dsp(0,'LOWPASS','Cutoff')}},
    band={className='AudioFilter',properties={FilterType='Peak'},bindings={Frequency=dsp(1,'MULTIBAND_EQ','Frequency'),Gain=dsp(1,'MULTIBAND_EQ','Gain')}},
    chorus={className='AudioChorus',bindings={Mix=dsp(2,'CHORUS','Mix',.01)}},
    echo={className='AudioEcho',bindings={DelayTime=dsp(3,'ECHO','Delay',.001)}},
    send={className='AudioFader',bindings={Volume=dsp(4,'SEND','Level')}},
    reverb={className='AudioReverb',properties={DecayTime=2}},
    master={className='AudioFader',bindings={Volume={bus='bus:/',field='finalVolume'}}},
    output={className='AudioDeviceOutput'},
},wires={
    {source='input',target='lowpass'},{source='lowpass',target='band'},{source='band',target='chorus'},
    {source='chorus',target='echo'},{source='echo',target='master'},
    {source='echo',target='send'},{source='send',target='reverb'},{source='reverb',target='master'},
    {source='master',target='output'},
}}
local state={['bus:/']={finalVolume=.8},['bus:/music']={finalVolume=.5,dsps={
    {type='LOWPASS',parameters={Cutoff=1200}},
    {type='MULTIBAND_EQ',parameters={Frequency=700,Gain=-6}},
    {type='CHORUS',parameters={Mix=50}},
    {type='ECHO',parameters={Delay=250}},
    {type='SEND',parameters={Level=.75}},
}}}
local graph=Graph.new(spec,{parent={},factory=factory})
assert(graph.ready and graph:commit(state) and #graph.errors==0)
assert(graph.nodes.input.Volume==.5 and graph.nodes.lowpass.Frequency==1200 and graph.nodes.band.Gain==-6)
assert(graph.nodes.chorus.Mix==.5 and graph.nodes.echo.DelayTime==.25 and graph.nodes.send.Volume==.75)
local before=writes;assert(graph:commit(state));assert(writes==before,'Unchanged mixer state must produce zero native property writes')
state['bus:/music'].dsps[0+1].parameters.Cutoff=800;assert(graph:commit(state));assert(writes==before+1)
local playing=true;local voice={audioNode={ClassName='AudioPlayer',GetOutputPins=function()return {'Output'}end},state=function()return if playing then 0 else 2 end}
graph:route(voice,'bus:/music');local wire=graph.attached[voice]
assert(wire.SourceInstance==voice.audioNode and wire.TargetInstance==graph.nodes.input)
playing=false;graph:commit(state);assert(wire.destroyed and not graph.attached[voice])
local owned=#graph.owned
for _=1,100 do playing=true;graph:route(voice,'bus:/music');playing=false;graph:commit(state)end
assert(#graph.owned==owned,'Completed event wires must not accumulate')
local ok,err=pcall(function()graph:route({state=voice.state},'bus:/music')end)
assert(not ok and tostring(err):find('legacy Sounds cannot feed Wires',1,true))
state['bus:/music'].dsps[1].parameters.Cutoff=nil
assert(not graph:commit(state) and not graph.ready and #graph.errors==1,'Missing DSP bindings must disable and report the graph')
assert(next(graph.attached)==nil and #graph.owned==0)
local cyclic=Graph.new({buses={},nodes={a={className='AudioFader'},b={className='AudioFader'}},
    wires={{source='a',target='b'},{source='b',target='a'}}},{parent={},factory=factory})
assert(not cyclic.ready and #cyclic.errors==1)
local badPins=Graph.new({buses={},nodes={a={className='AudioDeviceOutput'},b={className='AudioFader'}},
    wires={{source='a',target='b'}}},{parent={},factory=factory})
assert(not badPins.ready and #badPins.errors==1 and badPins.errors[1]:find('output pin',1,true))
print('PASS native audio graph bus routing, send/return branch, lowpass/EQ/chorus/echo bindings, write diffs, bounded wires and recorded capability failures')
