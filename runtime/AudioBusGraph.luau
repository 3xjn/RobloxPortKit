--!optimize 2
-- Native audio graph driven by authored property bindings. DSP conversions and
-- signal order must be supplied explicitly; FMOD endpoints cannot infer them.
local Graph={};Graph.__index=Graph
local allowed={AudioFader=true,AudioFilter=true,AudioEqualizer=true,AudioChorus=true,
    AudioEcho=true,AudioPitchShifter=true,AudioCompressor=true,AudioReverb=true,
    AudioDeviceOutput=true,AudioEmitter=true,AudioListener=true,AudioPlayer=true}
local function resolve(state,binding)
    local bus=assert(state[binding.bus],'Missing audio bus '..tostring(binding.bus))
    local value
    if binding.dsp~=nil then
        local dsp=assert(bus.dsps[binding.dsp+1],'Missing audio DSP '..tostring(binding.dsp))
        assert(dsp.type==binding.type,'Audio DSP binding type changed')
        value=dsp.parameters[binding.parameter]
    else value=bus[binding.field]end
    assert(value~=nil,'Missing audio property binding')
    if binding.values then
        local mapped=binding.values[value];assert(mapped~=nil,'Unmapped discrete audio DSP value');value=mapped
    elseif binding.transform=='decibels' then value=10^(value/20)
    elseif binding.transform~=nil then error('Unsupported audio binding transform '..binding.transform)end
    if binding.scale~=nil then value*=binding.scale end
    if binding.offset~=nil then value+=binding.offset end
    if type(value)=='number'then
        assert(value==value and math.abs(value)<math.huge,'Nonfinite audio DSP property')
        assert(not binding.min or value>=binding.min,'Audio DSP property below native range')
        assert(not binding.max or value<=binding.max,'Audio DSP property above native range')
    end
    return value
end
function Graph:_wire(source,target,sourceName,targetName,owned)
    sourceName=sourceName or 'Output';targetName=targetName or 'Input'
    assert(table.find(source:GetOutputPins(),sourceName),'Missing native audio output pin '..sourceName)
    assert(table.find(target:GetInputPins(),targetName),'Missing native audio input pin '..targetName)
    local wire=self.factory('Wire');if owned~=false then self.owned[#self.owned+1]=wire end
    wire.SourceInstance=source;wire.TargetInstance=target
    wire.SourceName=sourceName;wire.TargetName=targetName;wire.Parent=self.parent
    return wire
end
function Graph:_fail(err)
    local message='[PORT-ERROR] Native audio graph unavailable: '..tostring(err)
    self.errors[#self.errors+1]=message;warn(message);self.ready=false
    for _,wire in self.attached do wire:Destroy()end;table.clear(self.attached)
    for i=#self.owned,1,-1 do
        local ok,problem=pcall(self.owned[i].Destroy,self.owned[i])
        if not ok then local cleanup='[PORT-ERROR] Audio graph cleanup: '..tostring(problem);self.errors[#self.errors+1]=cleanup;warn(cleanup)end
    end
    table.clear(self.owned)
end
function Graph.new(spec,options)
    options=options or {}
    local self=setmetatable({factory=options.factory or Instance.new,parent=options.parent,
        errors=options.errors or {},owned={},nodes={},attached={},bindings={},ready=false,
        buses=spec.buses or {},properties={}},Graph)
    self.pitchRoutes=spec.pitchRoutes or {}
    local ok,err=pcall(function()
        self.parent=self.parent or game:GetService('SoundService')
        local edges={}
        for id,node in spec.nodes do
            assert(allowed[node.className],'Unsupported native audio node '..tostring(node.className))
            edges[id]={}
        end
        for _,wire in spec.wires do
            assert(edges[wire.source] and edges[wire.target],'Missing native audio wire endpoint')
            edges[wire.source][#edges[wire.source]+1]=wire.target
        end
        local visiting,complete={},{}
        local function visit(id)
            assert(not visiting[id],'Cyclic native audio graph at '..id)
            if complete[id]then return end
            visiting[id]=true;for _,child in edges[id]do visit(child)end
            visiting[id]=nil;complete[id]=true
        end
        for id in edges do visit(id)end
        for bus,node in self.buses do assert(edges[node],'Missing native input for '..bus)end
        for id,descriptor in spec.nodes do
            local node=self.factory(descriptor.className);self.owned[#self.owned+1]=node;self.nodes[id]=node
            node.Name=id
            for key,value in descriptor.properties or {}do node[key]=value end
            node.Parent=self.parent
            for property,binding in descriptor.bindings or {}do
                self.bindings[#self.bindings+1]={node=node,property=property,binding=binding}
            end
        end
        for _,wire in spec.wires do self:_wire(self.nodes[wire.source],self.nodes[wire.target],wire.sourceName,wire.targetName)end
        self.ready=true
    end)
    if not ok then self:_fail(err)end
    return self
end
function Graph:commit(state)
    if not self.ready then return false end
    local ok,err=pcall(function()
        -- Resolve every binding before native writes; missing fields must not
        -- publish half of a snapshot into the live graph.
        local values={}
        for i,entry in self.bindings do values[i]=resolve(state,entry.binding)end
        for i,entry in self.bindings do
            local value=values[i]
            if entry.value~=value then entry.node[entry.property]=value;entry.value=value end
        end
        for playback,wire in self.attached do
            local status=playback:state()
            if status==2 and (playback.stopped or playback.audioGraphStarted)then self:detach(playback)
            else
                if status~=2 then playback.audioGraphStarted=true end
                self:_pitch(playback,state)
            end
        end
        self.state=state
    end)
    if not ok then self:_fail(err)end
    return self.ready
end
function Graph:route(playback,bus)
    assert(self.ready,'Native audio graph is unavailable; inspect errors[]')
    assert(playback.audioNode,'FMOD routing requires an AudioPlayer/AudioListener playback node; legacy Sounds cannot feed Wires')
    local target=assert(self.nodes[self.buses[bus]],'Missing native audio route '..tostring(bus))
    assert(type(playback.state)=='function','Routed audio playback must expose state')
    local previous=self.attached[playback]
    if previous and previous.SourceInstance==playback.audioNode and previous.TargetInstance==target then return end
    if previous then previous:Destroy()end
    self.attached[playback]=self:_wire(playback.audioNode,target,nil,nil,false)
    playback.audioGraph=self;playback.audioBus=bus;playback.audioGraphStarted=playback:state()~=2
    if self.state then self:_pitch(playback,self.state)end
end
function Graph:_pitch(playback,state)
    local routes=self.pitchRoutes[playback.audioBus]
    if not routes then return end
    assert(type(playback.mixPitch)=='function','Routed FMOD bus pitch requires playback.mixPitch')
    local pitch=1
    for _,bus in routes do
        local value=assert(state[bus]and state[bus].pitch,'Missing routed FMOD bus pitch '..bus)
        assert(type(value)=='number' and value>0 and value<math.huge,'Invalid routed FMOD bus pitch')
        pitch*=value
    end
    if playback.audioBusPitch~=pitch then playback:mixPitch(pitch);playback.audioBusPitch=pitch end
end
function Graph:detach(playback)
    local wire=self.attached[playback]
    if wire then wire:Destroy();self.attached[playback]=nil end
    playback.audioGraph=nil;playback.audioBus=nil;playback.audioBusPitch=nil;playback.audioGraphStarted=nil
end
function Graph:destroy()
    for _,wire in self.attached do wire:Destroy()end;table.clear(self.attached)
    for i=#self.owned,1,-1 do self.owned[i]:Destroy()end
    table.clear(self.owned);table.clear(self.nodes);self.ready=false
end
return Graph
