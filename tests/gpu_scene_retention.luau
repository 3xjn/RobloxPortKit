local fs = require('@lune/fs')
local rbx = require('@lune/roblox')
local source = fs.readFile('runtime/GpuScene.luau')
local chunk = assert(loadstring(source, 'GpuScene'))
setfenv(chunk, setmetatable({UDim2=rbx.UDim2,Enum={ResamplerMode={Pixelated='pixelated'}}, Content={none='none'}}, {__index=getfenv()}))
local Scene = chunk()
local root, logs = {}, {}
local function factory()
    local values, log = {}, {}
    local object = setmetatable({Destroy=function() values.destroyed=true end}, {
        __index=values,
        __newindex=function(_, key, value)
            log[#log+1]={key=key,value=value,visible=values.Visible,parent=values.Parent}
            values[key]=value
        end,
    })
    logs[object]=log
    return object
end
local s=Scene.new(root,factory,{keepParented=true,cropRetentionFrames=180,imageRetentionFrames=2,maxInactiveImages=256})
local function props(content,frame)
    return {ImageContent=content,Position=rbx.UDim2.fromOffset(frame,frame*2),Size=rbx.UDim2.fromOffset(20,10),
        ImageRectOffset=rbx.Vector2.new(0,0),ImageRectSize=rbx.Vector2.new(20,10)}
end
local labels={}
for frame=1,36 do
    local content=if math.floor((frame-1)/6)%2==0 then 'a' else 'b'
    s:begin();local label=s:image(props(content,frame));s:finish()
    assert(not labels[content] or labels[content]==label)
    labels[content]=label
    for uri,existing in labels do
        assert(existing.Parent==root,'Retained crops must keep their parent')
        if uri~=content then
            assert(not existing.Visible or existing.Position==Scene.hiddenPosition)
        else assert(existing.Position==rbx.UDim2.fromOffset(frame,frame*2) and existing.ImageTransparency==0)end
    end
end
-- Parking must restore explicit alpha, default alpha, and frame geometry.
s:begin();local alpha=props('alpha',1);alpha.ImageTransparency=.4
local image=s:image(alpha)
local frame=s:frame({Position=rbx.UDim2.fromOffset(7,8),BackgroundTransparency=.3})
s:finish();s:begin();s:finish()
assert((not image.Visible or image.Position==Scene.hiddenPosition) and image.Parent==root and frame.Visible and frame.BackgroundTransparency==1)
assert(frame.Position==rbx.UDim2.fromOffset(-10000,-10000))
s:begin();assert(s:image(alpha)==image)
assert(s:frame({Position=rbx.UDim2.fromOffset(9,10)})==frame);s:finish()
assert(image.ImageTransparency==.4 and frame.BackgroundTransparency==0 and frame.Position==rbx.UDim2.fromOffset(9,10))
s:begin();s:finish();s:begin();s:image(props('alpha',2));s:finish()
assert(image.ImageTransparency==0 and image.Position==rbx.UDim2.fromOffset(2,4))
for _,label in labels do
    local parentIndex,positionIndex,sizeIndex,visibleIndex
    local parentWrites=0
    for index,write in logs[label] do
        if write.key=='Parent' then
            parentWrites+=1;assert(write.value==root and write.visible==false,'Parent while hidden')
            parentIndex=parentIndex or index
        elseif write.key=='Position' then
            if not positionIndex then assert(write.parent==nil and write.visible==false)end
            positionIndex=positionIndex or index
        elseif write.key=='Size' then
            if not sizeIndex then assert(write.parent==nil and write.visible==false)end
            sizeIndex=sizeIndex or index
        elseif write.key=='Visible' and write.value then visibleIndex=visibleIndex or index;assert(write.parent==root) end
    end
    assert(parentWrites==1,'Blinking must not detach or reparent')
    assert(positionIndex<parentIndex and sizeIndex<parentIndex and parentIndex<visibleIndex)
end
-- Detached pool entries receive new geometry while hidden before reparenting.
local detached=Scene.new(root,factory,{imageRetentionFrames=10})
detached:begin();local reused=detached:image(props('reused',1));detached:finish()
detached:begin();detached:finish();assert(reused.Parent==nil and not reused.Visible)
local start=#logs[reused]
detached:begin();assert(detached:image(props('reused',2))==reused);detached:finish()
local parentIndex,positionIndex,visibleIndex
for index=start+1,#logs[reused] do
    local write=logs[reused][index]
    if write.key=='Parent' then parentIndex=index;assert(write.value==root and not write.visible)
    elseif write.key=='Position' then positionIndex=index;assert(write.parent==nil and not write.visible)
    elseif write.key=='Visible' and write.value then visibleIndex=index;assert(write.parent==root) end
end
assert(parentIndex and positionIndex and visibleIndex and positionIndex<parentIndex and parentIndex<visibleIndex)
-- Expired crops enter the bounded pool even when their entire bucket is idle.
for _=1,181 do s:begin();s:finish() end
assert(#s.images==0 and next(s.imageBuckets)==nil)
print('PASS geometry-before-parent/publication and retained blinking image buckets')
