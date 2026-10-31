--!optimize 2
-- Soft-alpha mesh materials require a live EditableImage. Keep only bounded,
-- referenced pages editable; ordinary UI/opaque pages use immutable Content.
local Policy=require(script.Parent.EditableImagePolicy)
local Pool={};Pool.__index=Pool
function Pool.new(config)
    config=config or {}
    assert((config.maxPages or 8)>=1 and (config.maxPages or 8)%1==0,'Invalid material page budget')
    assert((config.maxBytes or 16*1024*1024)>=4,'Invalid material byte budget')
    return setmetatable({entries={},pins={},clock=0,count=0,bytes=0,generation=0,
        maxPages=config.maxPages or 8,maxBytes=config.maxBytes or 16*1024*1024,
        service=config.service or game:GetService('AssetService'),
        editableImagePolicy=config.editableImagePolicy or Policy.new(config),
        wrap=config.wrap or Content.fromObject,alphaMode=config.alphaMode or Enum.AlphaMode.Transparency},Pool)
end
function Pool:pin(id)assert(self.entries[id],'Material page must exist before pinning');self.pins[id]=(self.pins[id]or 0)+1 end
function Pool:unpin(id)local n=(self.pins[id]or 0)-1;self.pins[id]=if n>0 then n else nil end
function Pool:release(id)
    local entry=self.entries[id];if not entry then return end
    entry.appearance:Destroy();entry.image:Destroy();self.entries[id]=nil;self.pins[id]=nil
    self.count-=1;self.bytes-=entry.bytes
end
function Pool:evict()
    local oldest,age=nil,math.huge
    for id,entry in self.entries do if not self.pins[id]and entry.used<age then oldest,age=id,entry.used end end
    if oldest==nil then return false end;self:release(oldest);return true
end
function Pool:acquire(id,content,width,height)
    assert(not self.disposed,'Material pool disposed')
    assert(width>=1 and height>=1 and width<=1024 and height<=1024 and width%1==0 and height%1==0,'Material pages must be <=1024')
    self.clock+=1;local entry=self.entries[id]
    if entry then entry.used=self.clock;return entry end
    self.editableImagePolicy:assertAllowed('Soft-alpha material allocation')
    local bytes=width*height*4;assert(bytes<=self.maxBytes,'Material page exceeds byte budget')
    while self.count>=self.maxPages or self.bytes+bytes>self.maxBytes do assert(self:evict(),'Material budget exhausted with all pages pinned')end
    local image,appearance;local generation=self.generation
    local ok,err=xpcall(function()
        image=assert(self.service:CreateEditableImageAsync(content),'Soft-alpha image allocation failed')
        self.editableImagePolicy:recordCreated()
        appearance=self.service:CreateSurfaceAppearanceAsync({ColorMap=self.wrap(image)})
        appearance.AlphaMode=self.alphaMode
        assert(not self.disposed and self.generation==generation,'Material pool cleared during allocation')
    end,debug.traceback)
    if not ok then if appearance then appearance:Destroy()end;if image then image:Destroy()end;error(err)end
    entry={image=image,appearance=appearance,bytes=bytes,used=self.clock};self.entries[id]=entry
    self.count+=1;self.bytes+=bytes;return entry
end
function Pool:clear()self.generation+=1;for id in self.entries do self:release(id)end end
function Pool:destroy()self.disposed=true;self:clear()end
return Pool
