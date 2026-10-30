return function()
local fs=require('@lune/fs');local rbx=require('@lune/roblox')
local chunk=assert(loadstring(fs.readFile(if fs.isFile('runtime/RetainedTextMesh.luau')then 'runtime/RetainedTextMesh.luau'else '../RobloxPortKit/runtime/RetainedTextMesh.luau')))
setfenv(chunk,setmetatable({Vector3=rbx.Vector3,Vector2=rbx.Vector2,CFrame=rbx.CFrame,Color3=rbx.Color3,
    UDim2=rbx.UDim2,Enum=rbx.Enum},{__index=getfenv()}))
local Text=chunk();local jobs={};local created={};local imageCalls=0
local function factory(kind)
    local object={kind=kind,Destroy=function(self)self.destroyed=true;for _,child in created do if child.Parent==self and not child.destroyed then child:Destroy()end end end};created[#created+1]=object;return object
end
local service={}
local materials={}
function materials:FindFirstChild(id)
    if service.denyTexture then return nil end
    return {AlphaMode=rbx.Enum.AlphaMode.Transparency,IsA=function(_,kind)return kind=='SurfaceAppearance'end,
        Clone=function()local appearance=factory('SurfaceAppearance');appearance.materialPage=id;return appearance end}
end
function service:CreateEditableImage()imageCalls+=1;error('Forbidden')end
function service:CreateEditableMesh()
    local mesh={vertices={},uvs={},faces={},colors={},Destroy=function(self)self.destroyed=true end}
    function mesh:AddVertex(v)self.vertices[#self.vertices+1]=v;return #self.vertices end
    function mesh:AddUV(v)self.uvs[#self.uvs+1]=v;return #self.uvs end
    function mesh:AddColor(c,a)self.colors[#self.colors+1]={c,a};return #self.colors end
    function mesh:AddTriangle(a,b,c)self.faces[#self.faces+1]={a,b,c};return #self.faces end
    function mesh:SetFaceUVs()end;function mesh:SetFaceColors()end
    function mesh:bounds()
        local l,t,r,b=math.huge,math.huge,-math.huge,-math.huge
        for _,v in self.vertices do l=math.min(l,v.X);t=math.min(t,v.Y);r=math.max(r,v.X);b=math.max(b,v.Y)end
        return l,t,r,b
    end
    function mesh:GetCenter()local l,t,r,b=self:bounds();return rbx.Vector3.new((l+r)/2,(t+b)/2,0)end
    function mesh:GetSize()local l,t,r,b=self:bounds();return rbx.Vector3.new(r-l,b-t,0)end
    return mesh
end
function service:CreateMeshPartAsync()
    return setmetatable(factory('MeshPart'),{__newindex=function(t,key,value)
        if key=='TextureContent'then
            assert(not service.denyTexture,'binding denied')
            assert(type(value)=='string' and value:match('^rbxassetid://'),'Only published Content may be bound')
        end
        rawset(t,key,value)
    end})
end
function service:CreateSurfaceAppearanceAsync(content)
    assert(type(content.ColorMap)=='string','Only published Content may be bound')
    return factory('SurfaceAppearance')
end
return {Text=Text,jobs=jobs,created=created,service=service,factory=factory,materials=materials,
    imageCalls=function()return imageCalls end,
    drain=function()while #jobs>0 do table.remove(jobs,1)()end end}
end
