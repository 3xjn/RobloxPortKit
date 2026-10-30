local fixture=require('./text_mesh_fixture')()
local rbx=require('@lune/roblox')
local Text,jobs,created,service,factory=fixture.Text,fixture.jobs,fixture.created,fixture.service,fixture.factory
local errors={};local nonfatal={}
local root={AbsoluteSize=rbx.Vector2.new(1253,705)}
local text=Text.new(root, {service=service,factory=factory,materials=fixture.materials,scheduler={defer=function(job)jobs[#jobs+1]=job end,spawn=function(job)job()end,wait=function()end},
    wrap=function(mesh)return mesh end,errors=errors,nonfatalErrors=nonfatal})
local quads={}
for i=1,30 do
    quads[#quads+1]={page='stroke',x=i*10-1,y=-1,w=8,h=10,u=0,v=0,uw=.1,vh=.1,r=0,g=0,b=0,a=255}
    quads[#quads+1]={page='fill',x=i*10,y=0,w=6,h=8,u=.1,v=.1,uw=.1,vh=.1,r=128,g=64,b=32,a=128}
end
local pages={stroke={content='rbxassetid://stroke'},fill={content='rbxassetid://fill'}}
assert(#Text.batches(quads)==2,'Disjoint glyphs should batch onto two page meshes')
local overlap={quads[1],quads[2],table.clone(quads[1])};overlap[3].page='stroke'
assert(#Text.batches(overlap)==3,'Overlapping source order must prevent page hoisting')
text:begin(1920,1080)
assert(not text:prepare('sentence',quads,pages))
assert(not text:draw('sentence',quads,pages,{1,0,0,1,0,0},{R=255,G=255,B=255,A=255},1),'Pending mesh must decline the draw')
assert(not text:prepare('sentence',quads,pages),'Two simultaneous occurrences need distinct scenes')
for _,job in jobs do job()end;table.clear(jobs)
assert(text.pending==0 and text.builds==2 and #errors==0)
assert(text.maxEntries==48 and text.retentionFrames==45)
local materialCount=0
for _,object in created do
    if object.kind=='SurfaceAppearance' then assert(object.Parent and object.Parent.kind=='MeshPart');materialCount+=1 end
    if object.kind=='MeshPart' then assert(object.TextureContent==nil,'Live mesh texture must use authored material')end
end
assert(materialCount==4,'Both pages of both runs must clone their published material')
local writes=text.vertexWrites
for frame=1,120 do
    text:begin(1920,1080)
    assert(text:prepare('sentence',quads,pages))
    assert(text:prepare('sentence',quads,pages))
    local scale=1+.15*math.sin(frame/10)
    text:draw('sentence',quads,pages,{scale,0,0,scale,100+frame*.125,200+frame*.25},{R=255,G=255,B=255,A=255},11)
    text:draw('sentence',quads,pages,{scale,0,0,scale,300.25,500.125},{R=255,G=255,B=255,A=255},101)
    text:finish()
    local a,b=text.entries.sentence[1],text.entries.sentence[2]
    assert(a.batches[1].viewport.ZIndex==11 and b.batches[1].viewport.ZIndex==101)
    assert(a.batches[1].part.object.CFrame~=b.batches[1].part.object.CFrame)
    assert(a.batches[2].viewport.ImageTransparency==1-128/255,'Fill opacity must be applied exactly once')
    for _,color in a.batches[2].mesh.colors do assert(color[2]==1,'Vertex alpha must remain opaque')end
    for _,entry in {a,b}do for _,batch in entry.batches do
        assert(batch.viewport.Position==rbx.UDim2.fromScale(0,0) and batch.viewport.Size==rbx.UDim2.fromScale(1,1))
    end end
    -- Reproject actual retained MeshPart transforms into physical pixels.
    -- Include both pages and adjacent glyphs at the reported 1253x705 size.
    for _,batch in a.batches do
        local cameraZ=batch.camera.CFrame.Position.Z
        local pixelsPerUnit=705/(2*cameraZ*math.tan(math.rad(22.5)))
        for _,index in {1,2,5,6}do
            local v=batch.mesh.vertices[index];local center=batch.center;local part=batch.part.object
            local x=(v.X-center.X)*part.Size.X/batch.size.X+part.CFrame.Position.X
            local y=(v.Y-center.Y)*part.Size.Y/batch.size.Y+part.CFrame.Position.Y
            assert(math.abs(x*pixelsPerUnit+1253/2-(v.X*scale+100+frame*.125)*1253/1920)<.001)
            assert(math.abs(705/2-y*pixelsPerUnit-(-v.Y*scale+200+frame*.25)*705/1080)<.001)
        end
    end
end
assert(text.builds==2 and text.vertexWrites==writes and fixture.imageCalls()==0,'Continuous slide/pulse must only transform retained parts')
text:begin(1920,1080);assert(text:prepare('sentence',quads,pages))
text:draw('sentence',quads,pages,{1,0,0,1,0,0},{R=64,G=32,B=16,A=128},11)
local gui=text.entries.sentence[1].batches[1].viewport
assert(gui.ImageColor3==rbx.Color3.new(.5,.25,.125) and gui.ImageTransparency==1-128/255,
    'Premultiplied traversal tint must unpremultiply once before viewport composition')
-- Binding failure stays visible to automation and never throws or retries a
-- broken capability behind an image/glyph fallback.
service.denyTexture=true
text:begin(1920,1080);assert(not text:prepare('bad',quads,pages));jobs[1]()
assert(#errors==1 and nonfatal[errors[1]])
assert(text:draw('bad',quads,pages,{1,0,0,1,0,0},{R=255,G=255,B=255,A=255},1)==false,
    'Failed meshes must decline the draw so published image text remains available')
text:finish();assert(#errors==1)
text:destroy()
for _,object in created do if object.kind=='MeshPart' or object.kind=='ViewportFrame'then assert(object.destroyed)end end
local timeoutFixture=require('./text_mesh_fixture')()
local clock=0;local deferred,workers={},{}
local timed=Text.new({}, {service=timeoutFixture.service,factory=timeoutFixture.factory,materials=timeoutFixture.materials,
    wrap=function(mesh)return mesh end,clock=function()return clock end,timeout=.01,
    scheduler={defer=function(job)deferred[#deferred+1]=job end,spawn=function(job)workers[#workers+1]=job end,
        wait=function()clock+=.01 end}})
timed:begin(1920,1080);assert(not timed:prepare('timeout',quads,pages))
deferred[1]();assert(timed.pending==0 and #timed.errors==1)
workers[1]()
for _,object in timeoutFixture.created do assert(object.destroyed,'Late native results must be disposed after timeout')end
timed:destroy()
print('PASS retained font meshes: float transforms, duplicate occurrences, source order, zero image/vertex uploads, loud nonfatal failures')
