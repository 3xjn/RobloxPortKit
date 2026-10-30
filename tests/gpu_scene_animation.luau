local fs=require('@lune/fs');local rbx=require('@lune/roblox')
local chunk=assert(loadstring(fs.readFile('runtime/GpuScene.luau')))
setfenv(chunk,setmetatable({UDim2=rbx.UDim2,Enum=rbx.Enum,Content={none='none'}},{__index=getfenv()}))
local Scene=chunk();local root={};local frame=0;local objects={};local parents,created=0,0;local shown={}
local function onScreen(o)return o.Visible and o.Position~=Scene.hiddenPosition end
local function factory(kind)
    assert(kind=='ImageLabel');created+=1
    local data={};local object=setmetatable({},{__index=data,__newindex=function(_,key,value)
        if key=='Parent' then parents+=1 end
        if (key=='ImageRectOffset' or key=='ImageRectSize') and data[key] and data[key]~=value then
            assert(not shown[object],'Recrop must follow a committed hidden or off-screen frame')
        end
        if key=='Visible' and value then
            assert(data.Parent==root and data.Position and data.Size and data.ZIndex and data.ImageColor3 and data.ImageTransparency~=nil)
        end
        data[key]=value
    end})
    function data:Destroy()data.destroyed=true end
    objects[#objects+1]=object;return object
end
local scene=Scene.new(root,factory,{maxInactiveImages=256,keepParented=true})
local warmParents,warmCreated
for tick=1,720 do
    frame=tick
    -- Twelve crops, six frames per crop, with a never-before-seen blink at 300.
    local crop=if tick==300 then 12 else math.floor((tick-1)/6)%12
    scene:begin()
    scene:image({ImageContent='rbxassetid://123',ImageRectOffset=rbx.Vector2.new(crop*16,0),ImageRectSize=rbx.Vector2.new(16,24),
        Position=rbx.UDim2.fromScale(tick*.0001,.5),Size=rbx.UDim2.fromScale(.02,.03),ZIndex=10,
        ImageColor3=rbx.Color3.new(1,1,1),ImageTransparency=0})
    scene:finish()
    local visible=0
    for _,object in objects do
        if not object.destroyed then
            assert(object.Parent==root,'Warm spare detached')
            shown[object]=onScreen(object);if shown[object] then visible+=1 end
        end
    end
    assert(visible==1,'Every presentation must contain exactly one body quad')
    if tick==20 then warmParents,warmCreated=parents,created end
    if tick>20 then assert(parents==warmParents and created==warmCreated,'Mid-animation hierarchy/allocation churn')end
end
assert(scene.recycledImages>0 and scene.destroyedImages==0)
print(string.format('PASS 720 animation frames including cold blink: %d warm images, 0 later Parent writes, 0 later allocations, 1 visible body every frame',created))
