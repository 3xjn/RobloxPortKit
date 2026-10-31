--!optimize 2
-- Revisioned binary files for runtimes that expose an ordinary filesystem.
local Base64=require(script.Parent.Base64)
local FileStore={};FileStore.__index=FileStore
local function newer(a,b)
    return not b or a.version>b.version or (a.version==b.version and a.writer>b.writer)
end
function FileStore.blank()return {format=1,files={},achievements={}}end
function FileStore.validate(data)
    if type(data)~='table'or type(data.files)~='table'then return false,'Invalid file store'end
    local result=FileStore.blank();local count,total=0,0
    for name,file in data.files do
        count+=1
        if type(name)~='string'or #name>160 or name:find('[^%w_./-]')or name:sub(1,1)=='/'or name:find('..',1,true)then return false,'Invalid file path'end
        if type(file)~='table'or type(file.version)~='number'or file.version%1~=0 or file.version<1 or file.version>1e12
            or type(file.writer)~='string'or #file.writer<1 or #file.writer>64 or type(file.data)~='string'or #file.data>600000 or not Base64.isValid(file.data)
            or (file.deleted~=nil and type(file.deleted)~='boolean')then return false,'Invalid file revision'end
        total+=#file.data;if count>64 or total>3000000 then return false,'File store is too large'end
        result.files[name]={version=file.version,writer=file.writer,data=file.data,deleted=file.deleted==true}
    end
    if data.achievements~=nil and type(data.achievements)~='table'then return false,'Invalid achievements'end
    for id,value in data.achievements or {}do
        if type(id)~='string'or #id>128 or value~=true then return false,'Invalid achievement'end
        result.achievements[id]=true
    end
    return true,result
end
function FileStore.merge(old,incoming)
    local result=FileStore.blank()
    for _,source in {old or {},incoming or {}}do
        for name,file in source.files or {}do if newer(file,result.files[name])then result.files[name]=table.clone(file)end end
        for id in source.achievements or {}do result.achievements[id]=true end
    end
    result.revision=old and old.revision or 0;result._portkit=old and old._portkit or nil
    return result
end
function FileStore.new(writer)
    assert(type(writer)=='string'and #writer>0 and #writer<=64)
    return setmetatable({writer=writer,data=FileStore.blank(),clock=0,dirty=false},FileStore)
end
function FileStore:read(name)
    local file=self.data.files[name]
    if file and not file.deleted then return Base64.decode(file.data)end
end
function FileStore:exists(name)local file=self.data.files[name];return file~=nil and not file.deleted end
function FileStore:write(name,bytes)
    local encoded=Base64.encode(bytes);local previous=self.data.files[name]
    if previous and not previous.deleted and previous.data==encoded then return end
    self.clock+=1;self.data.files[name]={version=self.clock,writer=self.writer,data=encoded,deleted=false};self.dirty=true
end
function FileStore:delete(name)
    self.clock+=1;self.data.files[name]={version=self.clock,writer=self.writer,data='',deleted=true};self.dirty=true
end
function FileStore:snapshot(achievements)
    local result=FileStore.merge(self.data,nil);result.achievements=table.clone(achievements or result.achievements);return result
end
function FileStore:apply(data,sent)
    self.data=FileStore.merge(self.data,data)
    for _,file in self.data.files do self.clock=math.max(self.clock,file.version)end
    if sent then
        self.dirty=false
        for name,file in self.data.files do
            local previous=sent.files[name]
            if not previous or newer(file,previous)then self.dirty=true;break end
        end
    end
end
return FileStore
