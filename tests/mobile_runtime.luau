local F=require('./mobile_fixture')
local rbx=F.rbx
local Profile=F.load('runtime/MobileProfile.luau')
assert(Profile.detect({mobile=true}).maxParkedNodes==384)
assert(Profile.detect({uis={TouchEnabled=true,KeyboardEnabled=false}}).isMobile)
assert(Profile.detect({viewport=rbx.Vector2.new(900,540)}).isMobile)
assert(not Profile.detect({uis={TouchEnabled=true,KeyboardEnabled=true},viewport=rbx.Vector2.new(1920,1080)}).isMobile)
local Shell=F.load('runtime/Shell.luau')
local live=true
local jobs={}
local scheduler={spawn=function(callback)
    local thread=coroutine.create(callback);jobs[#jobs+1]=thread
    assert(coroutine.resume(thread))
end,wait=coroutine.yield}
local calls,bindings={},{}
local starter={SetCoreGuiEnabled=function(_,key,value) calls[key.Name]=value end}
local cas={BindActionAtPriority=function(_,name,handler,touch,priority,key)
    assert(not touch and priority==3500 and key==rbx.Enum.KeyCode.Backquote);bindings[name]=handler
end,UnbindAction=function(_,name) bindings[name]=nil end}
local playerGui={}
local player={}
local config={singlePlayer=true,player=player,playerGui=playerGui,starterGui=starter,contextActionService=cas,scheduler=scheduler,
    runService={IsServer=function()return false end}}
local unbind=Shell.configureCoreGui(config,function()return live end)
assert(calls.Backpack==false)
assert(playerGui.ScreenOrientation==rbx.Enum.ScreenOrientation.LandscapeSensor)
assert(player.DevTouchMovementMode==nil,'Client must never write server-only touch movement mode')
config.runService.IsServer=function()return true end
Shell.configureCoreGui(config)()
assert(player.DevTouchMovementMode==rbx.Enum.DevTouchMovementMode.Scriptable)
config.runService.IsServer=function()return false end
local _,handler=next(bindings)
assert(handler(nil,rbx.Enum.UserInputState.Begin)==rbx.Enum.ContextActionResult.Sink)
live=false
for _,thread in jobs do if coroutine.status(thread)=='suspended' then assert(coroutine.resume(thread)) end end
assert(next(bindings)==nil);unbind()
live=true;jobs={}
unbind=Shell.configureCoreGui(config,function()return live end);assert(next(bindings));unbind();assert(not next(bindings))
config.disableBackpack=false
Shell.configureCoreGui(config);assert(calls.Backpack==true and not next(bindings))
config.disableBackpack=true;config.coreGui={Backpack=true}
Shell.configureCoreGui(config);assert(calls.Backpack==true and not next(bindings))
local uis=F.uis()
local paused=0
local shell=setmetatable({pauseKeys=Shell.defaultPauseKeys({}),pauseHandler=function()paused+=1 end},Shell)
shell:pauseKey(rbx.Enum.KeyCode.Tab,uis);shell:pauseKey(rbx.Enum.KeyCode.Backquote,uis);assert(paused==2)
assert(shell:pauseAction(rbx.Enum.UserInputState.Begin,{KeyCode=rbx.Enum.KeyCode.Tab},uis)==rbx.Enum.ContextActionResult.Sink);assert(paused==3)
uis.focused=true;shell:pauseKey(rbx.Enum.KeyCode.Tab,uis);assert(paused==3);assert(shell:pauseAction(rbx.Enum.UserInputState.Begin,{KeyCode=rbx.Enum.KeyCode.Tab},uis)==rbx.Enum.ContextActionResult.Pass);uis.focused=nil
local Input=F.load('runtime/Input.luau')
local input=Input.new({uis=uis,hud={},actions={{action='jump',size=rbx.UDim2.fromOffset(92,92)},{action='back'}}})
assert(input.overlay.Visible and input.touchButtons[1].button.Size==rbx.UDim2.fromOffset(92,92))
local move={UserInputType=rbx.Enum.UserInputType.Touch,Position=rbx.Vector2.new(110,-50)}
input.moveZone.InputBegan:fire(move)
assert(input:check('right') and input:check('up'),'Move pad must support diagonal input')
local finger={UserInputType=rbx.Enum.UserInputType.Touch,Position=rbx.Vector2.new(10,10)}
local jump,back=input.touchButtons[1].button,input.touchButtons[2].button
jump.AbsolutePosition=rbx.Vector2.zero;back.AbsolutePosition=rbx.Vector2.new(100,0)
jump.InputBegan:fire(finger);assert(input:check('jump') and input:check('right'))
finger.Position=rbx.Vector2.new(110,10);uis.TouchMoved:fire(finger)
assert(not input:check('jump') and input:check('back') and input:check('right'))
finger.Position=rbx.Vector2.new(220,10);uis.TouchMoved:fire(finger);assert(not input:check('back'))
finger.Position=rbx.Vector2.new(10,10);uis.TouchMoved:fire(finger);assert(input:check('jump'))
uis.TouchEnded:fire(finger);assert(not input:check('jump') and input:check('right'))
uis.TouchEnded:fire(move);assert(not input:check('right') and not input:check('up'))
input:destroy()
local Scene=F.load('runtime/GpuScene.luau')
local scene=Scene.new({},F.factory,{mobile=true,keepParented=true,cropRetentionFrames=1000,imageRetentionFrames=1000,maxParkedNodes=4})
local props={ImageContent='core',Position=rbx.UDim2.fromOffset(1,1),ImageRectSize=rbx.Vector2.new(1,1)}
scene:begin()
for i=1,12 do props.ImageRectOffset=rbx.Vector2.new(i,0);scene:image(props) end
scene:finish()
for _=1,179 do scene:begin();scene:finish() end
assert(scene.parkedCount==12 and scene.prunedParkedNodes==0)
scene:begin();scene:finish();assert(scene.parkedCount==4 and scene.prunedParkedNodes==8)
for _,entry in scene.images do if entry.coldDetached then assert(entry.object.Parent==nil) end end -- off-screen hide keeps Visible
scene:begin();props.ImageRectOffset=rbx.Vector2.new(1,0);local restored=scene:image(props);scene:finish()
assert(restored.Visible and restored.Parent and restored.Position==props.Position)
scene:destroy()
print('PASS mobile profile, backpack sink/lifecycle, landscape/scriptable, pause/focus, multi-touch sliding and cold parked-node pruning')
