-- PixelCanvas fast paths (run copies, mirrored sprites, row-replicated fills)
-- must equal a plain per-pixel source-over compositor, including clipping.
local fs=require('@lune/fs')
local chunk=assert(loadstring(fs.readFile('runtime/PixelCanvas.luau'),'PixelCanvas'))
local Canvas=chunk()
local seed=3
local function rand()seed=(seed*1103515245+12345)%2147483648;return seed/2147483648 end
local function int(a,b)return a+math.floor(rand()*(b-a+1))end
-- 64x64 source page with opaque, transparent and partly transparent pixels.
local SW=64
local page=buffer.create(SW*SW*4)
for i=0,SW*SW-1 do
    local roll=rand()
    local a=if roll<.3 then 0 elseif roll<.4 then int(1,254) else 255
    buffer.writeu8(page,i*4,int(0,255));buffer.writeu8(page,i*4+1,int(0,255));buffer.writeu8(page,i*4+2,int(0,255));buffer.writeu8(page,i*4+3,a)
end
local W,H=40,24
local function reference()
    local frame=buffer.create(W*H*4)
    local ref={frame=frame}
    function ref.clear(r,g,b)for i=0,W*H-1 do buffer.writeu32(frame,i*4,bit32.bor(r,bit32.lshift(g,8),bit32.lshift(b,16),0xFF000000))end end
    function ref.draw(sx,sy,w,h,x,y,flipX,flipY,tr,tg,tb,ta)
        for dy=0,h-1 do for dx=0,w-1 do
            local u,v=if flipX then w-1-dx else dx,if flipY then h-1-dy else dy
            local o=((sy+v)*SW+sx+u)*4
            local a=buffer.readu8(page,o+3)
            local px,py=x+dx,y+dy
            if a>0 and px>=0 and px<W and py>=0 and py<H then
                local r,g,b=buffer.readu8(page,o),buffer.readu8(page,o+1),buffer.readu8(page,o+2)
                if tr then r,g,b,a=math.floor(r*tr/255+.5),math.floor(g*tg/255+.5),math.floor(b*tb/255+.5),math.floor(a*ta/255+.5)end
                if a>0 then Canvas.blendPixel(frame,(py*W+px)*4,r,g,b,a)end
            end
        end end
    end
    return ref
end
local function same(a,b,what)
    for i=0,W*H*4-1 do
        if buffer.readu8(a,i)~=buffer.readu8(b,i)then error(what..': byte '..i..' differs ('..buffer.readu8(a,i)..' vs '..buffer.readu8(b,i)..')')end
    end
end
for trial=1,300 do
    local canvas=Canvas.new(W,H);local ref=reference()
    local cr,cg,cb=int(0,255),int(0,255),int(0,255)
    canvas:clear(cr,cg,cb);ref.clear(cr,cg,cb)
    for _=1,int(1,12)do
        local w,h=int(1,16),int(1,16);local sx,sy=int(0,SW-w),int(0,SW-h)
        local x,y=int(-16,W),int(-16,H);local flipX,flipY=rand()<.3,rand()<.3
        local sprite=Canvas.sprite(page,SW,sx,sy,w,h)
        if rand()<.3 then
            -- identity transform through the general path (with a tint sometimes)
            local tint=rand()<.5
            local tr,tg,tb,ta=int(0,255),int(0,255),int(0,255),int(0,255)
            local a,d=if flipX then -1 else 1,if flipY then -1 else 1
            local tx,ty=if flipX then x+w else x,if flipY then y+h else y
            if tint then canvas:drawTransformed(sprite,a,0,0,d,tx,ty,tr,tg,tb,ta);ref.draw(sx,sy,w,h,x,y,flipX,flipY,tr,tg,tb,ta)
            else canvas:drawTransformed(sprite,a,0,0,d,tx,ty);ref.draw(sx,sy,w,h,x,y,flipX,flipY)end
        else canvas:draw(sprite,x,y,flipX,flipY);ref.draw(sx,sy,w,h,x,y,flipX,flipY)end
    end
    same(canvas.frame,ref.frame,'trial '..trial)
end
-- Opaque and translucent rectangles.
local canvas=Canvas.new(W,H);local ref=reference()
canvas:clear(10,20,30);ref.clear(10,20,30)
canvas:fillRect(-3,2,20,5,200,100,50);canvas:fillRect(5,4,50,30,0,255,0,128)
for py=2,6 do for px=0,16 do Canvas.blendPixel(ref.frame,(py*W+px)*4,200,100,50,255)end end
for py=4,H-1 do for px=5,W-1 do Canvas.blendPixel(ref.frame,(py*W+px)*4,0,255,0,128)end end
same(canvas.frame,ref.frame,'rectangles')
-- Transparent layers: source-over keeps straight alpha (composited later by GUI).
do
    local c=Canvas.new(1,1);c:clear(0,0,0,0)
    Canvas.blendPixel(c.frame,0,200,100,0,128)
    assert(buffer.readu32(c.frame,0)==bit32.bor(200,bit32.lshift(100,8),bit32.lshift(128,24)),'empty destination takes the source')
    Canvas.blendPixel(c.frame,0,0,0,200,128)
    local a=buffer.readu8(c.frame,3);assert(math.abs(a-192)<=1,'alpha union '..a)
    assert(math.abs(buffer.readu8(c.frame,0)-67)<=1 and math.abs(buffer.readu8(c.frame,2)-133)<=1,'straight colour mix')
end
-- Variants (integer placement) equal the general transformed path.
for trial=1,200 do
    local w,h=int(1,12),int(1,12);local sx,sy=int(0,SW-w),int(0,SW-h)
    local sprite=Canvas.sprite(page,SW,sx,sy,w,h)
    local angle=rand()*math.pi*2;local k=.5+rand()*2.5
    local a,b,c,d=math.cos(angle)*k,math.sin(angle)*k,-math.sin(angle)*k,math.cos(angle)*k
    if rand()<.3 then a,b,c,d=k,0,0,k*(if rand()<.5 then -1 else 1)end
    local tx,ty=int(-8,W),int(-8,H)
    local r,g,bl,al=int(0,255),int(0,255),int(0,255),int(1,255)
    local one,two=Canvas.new(W,H),Canvas.new(W,H)
    one:clear(9,8,7);two:clear(9,8,7)
    one:drawTransformed(sprite,a,b,c,d,tx,ty,r,g,bl,al)
    local v=sprite:variant(a,b,c,d,r,g,bl,al)
    if v then two:draw(v,tx+v.ox,ty+v.oy)end
    -- Rounding of the tint differs (pre-multiplied into the variant), +-2.
    for i=0,W*H*4-1 do
        if math.abs(buffer.readu8(one.frame,i)-buffer.readu8(two.frame,i))>2 then error('variant trial '..trial..' byte '..i)end
    end
end
print('PASS PixelCanvas runs, mirrors, clipping, identity transforms, tints and fills match per-pixel compositing')
