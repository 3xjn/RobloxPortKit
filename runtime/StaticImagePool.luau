--!native
-- Immutable texture pages. Decode/upload/conversion run outside render callbacks.
-- Labels and mesh materials share the returned Content; no editable image stays live.
local Policy=require(script.Parent.EditableImagePolicy)
local Pool={};Pool.__index=Pool
function Pool.new(config)
    config=config or {}
    assert((config.maxPages or 96)>=1 and (config.maxPages or 96)%1==0,'maxPages must be a positive integer')
    assert((config.maxBytes or 192*1024*1024)>0,'maxBytes must be positive')
    local service=config.service or game:GetService('AssetService')
    return setmetatable({images={},pins={},jobs={},queue={},count=0,bytes=0,clock=0,pending=0,
        maxPages=config.maxPages or 96,maxBytes=config.maxBytes or 192*1024*1024,
        scheduler=config.scheduler or task,service=service,success=config.success or Enum.CreateContentResult.Success,
        uploadBudget=config.uploadBudget or .0015,now=config.clock or os.clock,
        editableImagePolicy=config.editableImagePolicy or Policy.new(config),
        errors=config.errors or {},uploads=0,hits=0,evictions=0,maxUploadMs=0,disposed=false},Pool)
end
function Pool:pin(id)self.pins[id]=(self.pins[id]or 0)+1 end
function Pool:import(id,content,width,height,prepare)
    assert(not self.disposed,'Static image pool disposed')
    assert(content~=nil and width>=1 and height>=1 and width<=1024 and height<=1024,'Invalid published image page')
    local entry=self.images[id]
    self.clock+=1
    if entry then entry.used=self.clock;self.hits+=1;return entry end
    local job=self.jobs[id]
    if job then assert(not job.error,job.error);return nil end
    if prepare then
        job={id=id,width=width,height=height,content=content,bytes=0,published=true,prepare=prepare}
        self.jobs[id]=job;self.queue[#self.queue+1]=job;self.pending+=1;self:run();return nil
    end
    entry={content=content,bytes=0,used=self.clock,published=true,width=width,height=height}
    self.images[id]=entry
    return entry
end
function Pool:awaitImport(id,content,width,height,prepare)
    while not self.disposed do
        local entry=self:import(id,content,width,height,prepare)
        if entry then return entry end
        self.scheduler.wait()
    end
    error('Static image pool disposed')
end
function Pool:unpin(id)local n=(self.pins[id]or 0)-1;self.pins[id]=if n>0 then n else nil end
function Pool:releasePins()table.clear(self.pins)end
function Pool:evict()
    local oldest,age=nil,math.huge
    for id,entry in self.images do
        if not entry.published and not self.pins[id]and entry.used<age then oldest,age=id,entry.used end
    end
    if oldest==nil then return false end
    local entry=self.images[oldest];self.images[oldest]=nil
    self.count-=1;self.bytes-=entry.bytes;self.evictions+=1
    return true
end
function Pool:run()
    if self.running then return end
    self.running=true
    self.scheduler.defer(function()
        local sliceStarted=self.now()
        while not self.disposed and #self.queue>0 do
            local job=table.remove(self.queue,1)
            local editable
            local started=os.clock()
            local ok,err=xpcall(function()
                while not job.published and (self.count>=self.maxPages or self.bytes+job.bytes>self.maxBytes) do
                    assert(self:evict(),'Static image residency limit reached: all pages pinned')
                end
                local content=job.content
                if job.published then job.prepare()
                else
                    local raw=if type(job.pixels)=='function'then job.pixels()else job.pixels
                    assert(buffer.len(raw)==job.bytes,'Invalid RGBA page size')
                    self.editableImagePolicy:assertAllowed('Static image staging')
                    editable=assert(self.service:CreateEditableImage({Size=Vector2.new(job.width,job.height)}),'Static image staging allocation failed')
                    self.editableImagePolicy:recordCreated()
                    editable:WritePixelsBuffer(Vector2.zero,Vector2.new(job.width,job.height),raw)
                    local status;status,content=self.service:CreateDataModelContentAsync(Content.fromObject(editable))
                    assert(status==self.success,'Static image conversion failed: '..tostring(status))
                    editable:Destroy();editable=nil
                end
                if not self.disposed then
                    self.clock+=1
                    self.images[job.id]={content=content,bytes=job.bytes,used=self.clock,published=job.published}
                    if not job.published then self.count+=1;self.bytes+=job.bytes;self.uploads+=1 end
                end
            end,debug.traceback)
            if editable then editable:Destroy()end
            job.pixels=nil;job.prepare=nil;job.finished=true;job.error=if ok then nil else err
            if ok then self.jobs[job.id]=nil
            elseif not self.disposed then
                local message='Static image job '..tostring(job.id)..' failed: '..tostring(err)
                self.errors[#self.errors+1]=message;warn(message)
            end
            self.pending=math.max(0,self.pending-1);self.maxUploadMs=math.max(self.maxUploadMs,(os.clock()-started)*1000)
            -- Serialize editable staging, but batch fast pages in one slice so
            -- a font spread over several pages becomes ready together.
            if not self.disposed and #self.queue>0 and self.now()-sliceStarted>=self.uploadBudget then
                self.scheduler.wait();sliceStarted=self.now()
            end
        end
        self.running=false
    end)
end
function Pool:request(id,width,height,pixels)
    assert(not self.disposed,'Static image pool disposed')
    assert(width>=1 and height>=1 and width<=1024 and height<=1024
        and width%1==0 and height%1==0,'Atlas pages must be <= 1024x1024')
    local bytes=width*height*4
    assert(bytes<=self.maxBytes,'Atlas page exceeds the byte budget')
    local entry=self.images[id]
    if entry then self.clock+=1;entry.used=self.clock;self.hits+=1;return entry end
    local job=self.jobs[id]
    if job then assert(not job.error,job.error);return nil end
    self.editableImagePolicy:assertAllowed('Static image staging')
    job={id=id,width=width,height=height,bytes=bytes,pixels=pixels}
    self.jobs[id]=job;self.queue[#self.queue+1]=job;self.pending+=1;self:run()
    return nil
end
function Pool:await(id,width,height,pixels)
    while not self.disposed do
        local entry=self:request(id,width,height,pixels)
        if entry then return entry end
        self.scheduler.wait()
    end
    error('Static image pool disposed')
end
function Pool:destroy()
    self.disposed=true
    -- An in-flight conversion owns and releases its staging image when it resumes.
    table.clear(self.queue);table.clear(self.images);table.clear(self.pins);table.clear(self.jobs)
    self.count=0;self.bytes=0;self.pending=0
end
return Pool
