--!optimize 2
-- Immutable textured quads, built once. Animation changes MeshPart.Size/CFrame,
-- never GUI glyph rectangles or EditableMesh vertices. No EditableImages.
local Text={};Text.__index=Text
local unit=.01
local function set(entry,key,value)
    if entry.values[key]~=value then entry.object[key]=value;entry.values[key]=value end
end
local function overlaps(a,b)
    return a.x<b.x+b.w and b.x<a.x+a.w and a.y<b.y+b.h and b.y<a.y+a.h
end
-- A page may be hoisted only across disjoint quads. This preserves source
-- alpha composition, including kerning/overlapping stroke and fill pages.
function Text.batches(quads)
    local groups={}
    for _,quad in quads do
        local selected
        for i=#groups,1,-1 do
            local group=groups[i]
            local blocked=false
            for _,other in group.quads do if overlaps(quad,other)then blocked=true;break end end
            if blocked then break end
            if group.page==quad.page and group.alpha==quad.a then selected=group;break end
        end
        if not selected then selected={page=quad.page,alpha=quad.a,quads={}};groups[#groups+1]=selected end
        selected.quads[#selected.quads+1]=quad
    end
    return groups
end
function Text.new(root,options)
    options=options or {}
    -- Preserve the original injected build queue contract for headless hosts.
    -- Their service methods return synchronously; Roblox uses task workers.
    local scheduler=options.scheduler or (options.spawn and {
        defer=options.spawn,spawn=function(job)job()end,
        wait=function()assert(task,'Injected service must complete synchronously');task.wait()end}) or task
    return setmetatable({root=root,entries={},generation=0,errors=options.errors or {},reported={},
        factory=options.factory or (Instance and Instance.new),service=options.service or (game and game:GetService('AssetService')),
        scheduler=scheduler,clock=options.clock or os.clock,timeout=options.timeout or 2,wrap=options.wrap or (Content and Content.fromObject),
        materials=options.materials,maxEntries=options.maxEntries or 48,retentionFrames=options.retentionFrames or 45,
        nonfatalErrors=options.nonfatalErrors,builds=0,vertexWrites=0,pending=0},Text)
end
function Text:report(problem)
    local message='[PORT-ERROR] Retained text mesh: '..tostring(problem)
    if self.nonfatalErrors then self.nonfatalErrors[message]=true end
    if not self.reported[message]then self.reported[message]=true;self.errors[#self.errors+1]=message;warn(message)end
end
function Text:begin(width,height)
    self.generation+=1;self.width,self.height=width,height
    local root=self.root
    if root~=self.geometryRoot then
        if self.sizeConnection then self.sizeConnection:Disconnect();self.sizeConnection=nil end
        self.geometryRoot=root
        if typeof(root)=='Instance' then
            self.rootSize=root.AbsoluteSize
            self.sizeConnection=root:GetPropertyChangedSignal('AbsoluteSize'):Connect(function()self.rootSize=root.AbsoluteSize end)
        end
    end
    local size=if typeof(root)=='Instance' then self.rootSize else root.AbsoluteSize
    self.aspectScale=if size and size.X>0 and size.Y>0 then size.X*height/(size.Y*width)else 1
end
function Text:release(entry)
    entry.cancelled=true
    for _,batch in entry.batches do
        if batch.viewport then batch.viewport:Destroy()end
        if batch.mesh then batch.mesh:Destroy()end
    end
end
function Text:await(entry,name,callback)
    local done,abandoned,result=false,false,nil
    self.scheduler.spawn(function()
        local value=table.pack(pcall(callback))
        if abandoned or entry.cancelled then
            if value[1] and value[2]then value[2]:Destroy()end
        else result=value;done=true end
    end)
    local deadline=self.clock()+self.timeout
    while not done do
        if entry.cancelled or self.clock()>=deadline then
            abandoned=true;error(name..' cancelled or timed out',0)
        end
        self.scheduler.wait()
    end
    if not result[1]then error(result[2],0)end
    return result[2]
end
function Text:build(key,quads,pages)
    local entry={batches=Text.batches(quads),used=self.generation,values={},pending=true}
    local variants=self.entries[key]
    if not variants then variants={};self.entries[key]=variants end
    variants[#variants+1]=entry;self.builds+=1;self.pending+=1
    self.scheduler.defer(function()
        local temporary,part,viewport
        local ok,problem=pcall(function()
            for _,batch in entry.batches do
                if entry.cancelled then return end
                local page=assert(pages[batch.page],'Missing published font page')
                local material=self.materials and self.materials:FindFirstChild(tostring(batch.page))
                assert(material and material:IsA('SurfaceAppearance') and material.AlphaMode==Enum.AlphaMode.Transparency,
                    'Missing transparent published font material: '..tostring(batch.page))
                local mesh=assert(self.service:CreateEditableMesh(),'EditableMesh budget exhausted');temporary=mesh
                for index,q in batch.quads do
                    local vertices,uvs={},{ }
                    for i,p in {{0,0},{1,0},{1,1},{0,1}}do
                        vertices[i]=mesh:AddVertex(Vector3.new(q.x+p[1]*q.w,-q.y-p[2]*q.h,0))
                        uvs[i]=mesh:AddUV(Vector2.new(q.u+p[1]*q.uw,q.v+p[2]*q.vh))
                        self.vertexWrites+=1
                    end
                    local color=mesh:AddColor(Color3.new(math.clamp(q.r/math.max(1,q.a),0,1),
                        math.clamp(q.g/math.max(1,q.a),0,1),math.clamp(q.b/math.max(1,q.a),0,1)),1)
                    for _,tri in {{1,2,3},{1,3,4}}do
                        local face=mesh:AddTriangle(vertices[tri[1]],vertices[tri[2]],vertices[tri[3]])
                        mesh:SetFaceUVs(face,{uvs[tri[1]],uvs[tri[2]],uvs[tri[3]]})
                        mesh:SetFaceColors(face,{color,color,color})
                    end
                    if index%64==0 then self.scheduler.wait()end
                end
                local size,center=mesh:GetSize(),mesh:GetCenter()
                part=self:await(entry,'Font MeshPart',function()
                    return self.service:CreateMeshPartAsync(self.wrap(mesh),{RenderFidelity=Enum.RenderFidelity.Precise})
                end)
                part.Size=Vector3.new(math.max(size.X,.001),math.max(size.Y,.001),math.max(size.Z,.001));part.Anchored=true;part.CanCollide=false;part.CanTouch=false;part.CanQuery=false
                part.DoubleSided=true;part.Material=Enum.Material.SmoothPlastic;part.Color=Color3.new(1,1,1)
                -- ColorMap is authored in Edit (PluginSecurity). Clone that
                -- published material rather than binding live-mesh TextureContent.
                local appearance=assert(material:Clone(),'Font material clone failed')
                appearance.Parent=part
                viewport=self.factory('ViewportFrame');viewport.Name='RetainedFontLayer';viewport.BackgroundTransparency=1
                viewport.Position=UDim2.fromScale(0,0);viewport.Size=UDim2.fromScale(1,1)
                viewport.Ambient=Color3.new(1,1,1);viewport.LightColor=Color3.new();viewport.Visible=false
                local camera=self.factory('Camera');camera.FieldOfView=45;camera.Parent=viewport;viewport.CurrentCamera=camera
                part.Parent=viewport
                batch.viewport=viewport;batch.mesh=mesh;batch.part={object=part,values={}}
                batch.gui={object=viewport,values={Visible=false}};batch.camera=camera;batch.size=size;batch.center=center
                temporary=nil;part=nil;viewport=nil
                if entry.cancelled then return end
                batch.viewport.Parent=self.root
            end
        end)
        if temporary then temporary:Destroy()end
        if part then part:Destroy()end
        if viewport then viewport:Destroy()end
        entry.pending=false;self.pending-=1
        if not ok then
            local intentional=entry.cancelled
            entry.failed=true;self:release(entry)
            if not intentional then self:report(problem)end
        elseif entry.cancelled then self:release(entry)end
    end)
    return entry
end
function Text:prepare(key,quads,pages)
    local variants=self.entries[key]
    if variants and variants.prepareGeneration~=self.generation then variants.prepareGeneration=self.generation;variants.prepareIndex=0 end
    local index=(variants and variants.prepareIndex or 0)+1
    local entry=variants and variants[index]
    entry=entry or self:build(key,quads,pages)
    variants=self.entries[key];variants.prepareGeneration=self.generation;variants.prepareIndex=index
    entry.reservedGeneration=self.generation
    return not entry.pending and not entry.failed and not entry.cancelled
end
-- Each batch is its own full-screen viewport. Its integer GUI rectangle is
-- fixed; camera/part transforms carry all fractional position and scale.
function Text:draw(key,quads,pages,m,tint,z)
    local variants=self.entries[key]
    if variants and variants.drawGeneration~=self.generation then variants.drawGeneration=self.generation;variants.drawIndex=0 end
    local index=(variants and variants.drawIndex or 0)+1
    local entry=variants and variants[index]
    entry=entry or self:build(key,quads,pages)
    variants=self.entries[key];variants.drawGeneration=self.generation;variants.drawIndex=index
    entry.used=self.generation;entry.drawnGeneration=self.generation
    if entry.pending or entry.failed or entry.cancelled then return false end
    for i,batch in entry.batches do
        if batch.height~=self.height then
            batch.camera.CFrame=CFrame.new(0,0,self.height*unit/(2*math.tan(math.rad(22.5))))
        end
        local scaled=batch.mx~=m[1] or batch.my~=m[4] or batch.aspectScale~=self.aspectScale
        if scaled then
            local size=batch.size
            set(batch.part,'Size',Vector3.new(size.X*m[1]*unit*self.aspectScale,size.Y*m[4]*unit,math.max(size.Z*unit,.001)))
        end
        if scaled or batch.tx~=m[5] or batch.ty~=m[6] or batch.width~=self.width or batch.height~=self.height then
            local center=batch.center
            set(batch.part,'CFrame',CFrame.new((m[1]*center.X+m[5]-self.width/2)*unit*self.aspectScale,
                (m[4]*center.Y-m[6]+self.height/2)*unit,0))
        end
        batch.mx,batch.my,batch.tx,batch.ty,batch.width,batch.height=m[1],m[4],m[5],m[6],self.width,self.height
        batch.aspectScale=self.aspectScale
        set(batch.gui,'ZIndex',z+i-1)
        if batch.r~=tint.R or batch.g~=tint.G or batch.b~=tint.B or batch.a~=tint.A then
            local alpha=math.max(1,tint.A)
            set(batch.gui,'ImageColor3',Color3.new(math.clamp(tint.R/alpha,0,1),math.clamp(tint.G/alpha,0,1),math.clamp(tint.B/alpha,0,1)))
            batch.r,batch.g,batch.b=tint.R,tint.G,tint.B
        end
        -- Quads within a batch are disjoint and share opacity. Applying that
        -- opacity to the viewport is exact and avoids depending on native
        -- vertex-alpha routing or changing MeshPart.Transparency as a hack.
        if batch.a~=tint.A then set(batch.gui,'ImageTransparency',1-(tint.A/255)*(batch.alpha/255));batch.a=tint.A end
        set(batch.gui,'Visible',true)
    end
    return true
end
function Text:finish()
    local count=0;for _,variants in self.entries do count+=#variants end
    for key,variants in self.entries do for i=#variants,1,-1 do local entry=variants[i]
        if entry.used~=self.generation then
            for _,batch in entry.batches do if batch.gui then set(batch.gui,'Visible',false)end end
            if self.generation-entry.used>self.retentionFrames or count>self.maxEntries then
                self:release(entry);table.remove(variants,i);count-=1
            end
        end
    end;if #variants==0 then self.entries[key]=nil end end
end
function Text:destroy()
    if self.sizeConnection then self.sizeConnection:Disconnect();self.sizeConnection=nil end
    self.geometryRoot=nil
    for key,variants in self.entries do for i=1,#variants do self:release(variants[i])end;self.entries[key]=nil end
end
return Text
