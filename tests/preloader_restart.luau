local task=require('@lune/task')
local Preloader=require('../runtime/Preloader')
local p=Preloader.new({headless=true,scheduler=task})
local completed=false
task.spawn(function() assert(p:waitForStart());completed=true end)
task.wait()
assert(p.waitingForStart and p.stage=='Press any button or click to start' and not completed)
p:triggerStart();task.wait();assert(completed and not p.waitingForStart)
local stopped=Preloader.new({headless=true,scheduler=task})
local result=true
task.spawn(function()result=stopped:waitForStart()end)
task.wait();stopped:destroy();task.wait();assert(result==false)
print('PASS restart prompt waits, triggers, and cancels on destruction')
