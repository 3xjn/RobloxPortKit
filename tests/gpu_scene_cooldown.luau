local fs=require('@lune/fs');local rbx=require('@lune/roblox')
local chunk=assert(loadstring(fs.readFile('runtime/GpuScene.luau')))
setfenv(chunk,setmetatable({UDim2=rbx.UDim2,Enum=rbx.Enum,Content={none='none'}},{__index=getfenv()}))
local Scene=chunk();local frame=0;local snapshots={};local changes=0
local function factory()
    local data={};local object={}
    setmetatable(object,{__index=data,__newindex=function(_,key,value)
        if (key=='ImageRectOffset' or key=='ImageRectSize')and data[key]~=nil and data[key]~=value then
            changes+=1
            assert(snapshots[object] and snapshots[object].frame==frame-1 and not snapshots[object].visible,
                'A complete prior rendered frame must observe the label hidden or parked off-screen')
        end
        data[key]=value
    end})
    function data:Destroy()data.destroyed=true end
    snapshots[object]={frame=frame-1,visible=false};return object
end
for _,config in {{},{keepParented=true,cropRetentionFrames=0},{keepParented=true,imageReserve=4}}do
    local scene=Scene.new({},factory,config);local prior
    for i=1,100 do
        frame+=1;local committed=scene.generation;scene:begin()
        assert(scene.generation==committed,'begin must not advance committed presentations')
        local label=scene:image({ImageContent='page',ScrollingCrop=true,
            ImageRectOffset=rbx.Vector2.new(i+.25,0),ImageRectSize=rbx.Vector2.new(8,8)})
        scene:finish()
        assert(scene.generation==committed+1,'finish must commit exactly one presentation')
        assert(label~=prior,'Previous visible label must spend this frame hidden')
        for _,entry in scene.images do snapshots[entry.object]={frame=frame,visible=entry.object.Visible and entry.object.Position~=Scene.hiddenPosition}end
        prior=label
    end
    assert(scene.createdImages<=6,'A two-frame crop cycle must remain bounded')
    scene:destroy()
end
assert(changes>100,'Test must exercise actual recropping, including ScrollingCrop')
print('PASS mandatory rendered-frame crop cooldown under scrolling and pool pressure')
