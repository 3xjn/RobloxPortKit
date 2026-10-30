local fs=require('@lune/fs')
local chunk=assert(loadstring(fs.readFile('runtime/MaterialPool.luau'),'MaterialPool'))
local policy=assert(loadstring(fs.readFile('runtime/EditableImagePolicy.luau')))()
setfenv(chunk,setmetatable({script={Parent={EditableImagePolicy='policy'}},require=function(name)assert(name=='policy');return policy end},{__index=getfenv()}))
local Pool=chunk()
local images,appearances={},{}
local service={}
local afterImage,failAppearance
function service:CreateEditableImageAsync(content)
    assert(content.kind=='immutable')
    local image={Destroy=function(self)self.destroyed=true end}
    images[#images+1]=image
    if afterImage then afterImage()end
    return image
end
function service:CreateSurfaceAppearanceAsync(properties)
    assert(properties.ColorMap.kind=='editable'and properties.ColorMap.image==images[#images])
    if failAppearance then error('injected material failure')end
    local a={Destroy=function(self)self.destroyed=true end};appearances[#appearances+1]=a;return a
end
local function new()
    return Pool.new({service=service,allowEditableImages=true,wrap=function(image)return {kind='editable',image=image}end,
        alphaMode='Transparency',maxPages=2,maxBytes=32})
end
local content={kind='immutable'}
local p=new();local a=p:acquire('a',content,2,2)
assert(not a.image.destroyed and a.appearance.AlphaMode=='Transparency')
assert(p:acquire('a',content,2,2)==a and #images==1)
p:pin('a');p:pin('a');p:acquire('b',content,2,2);p:unpin('a')
p:acquire('c',content,2,2);assert(p.entries.a and not p.entries.b)
p:pin('c');assert(not pcall(p.acquire,p,'d',content,2,2))
p:unpin('a');p:acquire('d',content,2,2);assert(a.image.destroyed and a.appearance.destroyed)
assert(p.count==2 and p.bytes==32);p:destroy();assert(p.count==0 and p.bytes==0)
assert(not pcall(p.acquire,p,'x',content,1,1))
local q=new();failAppearance=true
assert(not pcall(q.acquire,q,'x',content,1,1));assert(images[#images].destroyed and q.count==0)
failAppearance=false;afterImage=function()q:clear()end
assert(not pcall(q.acquire,q,'x',content,1,1));assert(images[#images].destroyed and appearances[#appearances].destroyed)
afterImage=nil
assert(not pcall(q.acquire,q,'large',content,1025,1))
assert(not pcall(q.acquire,q,'fractional',content,1.5,1))
local denied=Pool.new({service=service,wrap=function(image)return image end,alphaMode='Transparency'})
local ok,err=pcall(denied.acquire,denied,'denied',content,1,1)
assert(not ok and tostring(err):find('EditableImage is disabled',1,true))
assert(denied.editableImagePolicy.editableImagesCreated==0)
assert(p.editableImagePolicy.editableImagesCreated==4 and q.editableImagePolicy.editableImagesCreated==2)
print('PASS retained editable material sources, LRU/refcounts, budgets, failure and clear cleanup')
