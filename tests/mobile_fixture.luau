local fs=require('@lune/fs')
local rbx=require('@lune/roblox')
local Fixture={rbx=rbx}
function Fixture.signal()
    local signal={listeners={}}
    function signal:Connect(callback)
        local connection={connected=true}
        function connection:Disconnect() self.connected=false end
        self.listeners[#self.listeners+1]={callback,connection};return connection
    end
    function signal:fire(...)
        for _,entry in self.listeners do if entry[2].connected then entry[1](...) end end
    end
    return signal
end
function Fixture.factory(kind)
    local item={ClassName=kind,Activated=Fixture.signal(),InputBegan=Fixture.signal(),Destroying=Fixture.signal(),
        AbsolutePosition=rbx.Vector2.zero,AbsoluteSize=rbx.Vector2.new(60,60)}
    function item:Destroy() self.destroyed=true;self.Parent=nil end
    return item
end
function Fixture.uis()
    local uis={TouchEnabled=true,KeyboardEnabled=false,GamepadEnabled=false}
    for _,name in {'InputBegan','InputChanged','InputEnded','WindowFocusReleased','GamepadConnected','GamepadDisconnected','LastInputTypeChanged','TouchMoved','TouchEnded'} do uis[name]=Fixture.signal() end
    function uis:GetFocusedTextBox() return self.focused end
    function uis:GetLastInputType() return rbx.Enum.UserInputType.Touch end
    function uis:GetConnectedGamepads() return {} end
    return uis
end
function Fixture.load(path,extra)
    local globals={Enum=rbx.Enum,Vector2=rbx.Vector2,UDim2=rbx.UDim2,UDim=rbx.UDim,Color3=rbx.Color3,
        Content={none='none',fromUri=function(uri)return uri end},Instance={new=Fixture.factory}}
    for key,value in extra or {} do globals[key]=value end
    local chunk=assert(loadstring(fs.readFile(path),path))
    setfenv(chunk,setmetatable(globals,{__index=getfenv()}));return chunk()
end
return Fixture
