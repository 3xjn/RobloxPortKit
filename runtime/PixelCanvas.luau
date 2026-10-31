--!optimize 2
-- Software 2D canvas for pixel-art ports: sprites are drawn into one RGBA frame
-- buffer and presented through a single EditableImage, instead of one GUI
-- object per sprite. Opaque pixels are copied in row runs with buffer.copy (a
-- native memcpy, fast even where Luau is interpreted); partially transparent
-- pixels, tints, scaling and rotation take per-pixel paths.
local Canvas={};Canvas.__index=Canvas
local copy,readu8,writeu8,readu32,writeu32=buffer.copy,buffer.readu8,buffer.writeu8,buffer.readu32,buffer.writeu32
local floor=math.floor

-- A sprite is a rectangle of an RGBA source buffer (stride in pixels), split
-- into opaque runs {sourceByte, dx, dy, length} and blended pixels
-- {sourceByte, dx, dy}. The source buffer is referenced, not copied.
local Sprite={};Sprite.__index=Sprite
function Canvas.sprite(source,stride,x,y,w,h)
    local runs,blended={}, {}
    for dy=0,h-1 do
        local dx=0
        while dx<w do
            local o=((y+dy)*stride+x+dx)*4;local a=readu8(source,o+3)
            if a==255 then
                local start=dx
                repeat dx+=1 until dx>=w or readu8(source,((y+dy)*stride+x+dx)*4+3)~=255
                runs[#runs+1]=o;runs[#runs+1]=start;runs[#runs+1]=dy;runs[#runs+1]=dx-start
            else
                if a>0 then blended[#blended+1]=o;blended[#blended+1]=dx;blended[#blended+1]=dy end
                dx+=1
            end
        end
    end
    return setmetatable({source=source,stride=stride,x=x,y=y,w=w,h=h,runs=runs,blended=blended},Sprite)
end
-- Horizontally mirrored copy, built once (buffer.copy cannot reverse a run).
function Sprite:mirrored()
    local m=self.mirror
    if m then return m end
    local w,h=self.w,self.h;local pixels=buffer.create(w*h*4)
    for dy=0,h-1 do for dx=0,w-1 do
        writeu32(pixels,(dy*w+(w-1-dx))*4,readu32(self.source,((self.y+dy)*self.stride+self.x+dx)*4))
    end end
    m=Canvas.sprite(pixels,w,0,0,w,h);m.mirror=self;self.mirror=m
    return m
end
-- Source-over blend of one source pixel (straight alpha) into the frame. A
-- frame cleared transparent (a layer between GUI draws) keeps straight alpha.
local function blendPixel(frame,o,sr,sg,sb,sa)
    if sa>=255 then writeu32(frame,o,bit32.bor(sr,bit32.lshift(sg,8),bit32.lshift(sb,16),0xFF000000));return end
    local da=readu8(frame,o+3)
    if da==255 then
        local ia=255-sa
        writeu8(frame,o,(sr*sa+readu8(frame,o)*ia+127)//255)
        writeu8(frame,o+1,(sg*sa+readu8(frame,o+1)*ia+127)//255)
        writeu8(frame,o+2,(sb*sa+readu8(frame,o+2)*ia+127)//255)
    elseif da==0 then writeu32(frame,o,bit32.bor(sr,bit32.lshift(sg,8),bit32.lshift(sb,16),bit32.lshift(sa,24)));return
    else
        -- out = s*sa + d*da*(1-sa), in 0..255 squared units.
        local dw=da*(255-sa)
        local oa=sa*255+dw
        writeu8(frame,o,(sr*sa*255+readu8(frame,o)*dw+oa//2)//oa)
        writeu8(frame,o+1,(sg*sa*255+readu8(frame,o+1)*dw+oa//2)//oa)
        writeu8(frame,o+2,(sb*sa*255+readu8(frame,o+2)*dw+oa//2)//oa)
        writeu8(frame,o+3,(oa+127)//255);return
    end
    writeu8(frame,o+3,255)
end
Canvas.blendPixel=blendPixel

function Canvas.new(width,height)
    local self=setmetatable({width=width,height=height,frame=buffer.create(width*height*4)},Canvas)
    return self
end
-- Fill the whole frame with one colour (alpha 255 unless given).
function Canvas:clear(r,g,b,a)
    local frame,n=self.frame,self.width*self.height*4
    writeu32(frame,0,bit32.bor(r or 0,bit32.lshift(g or 0,8),bit32.lshift(b or 0,16),bit32.lshift(a or 255,24)))
    local filled=4
    while filled<n do local chunk=math.min(filled,n-filled);copy(frame,filled,frame,0,chunk);filled+=chunk end
end
-- Untinted, unscaled, unrotated draw at integer (x,y). flipX/flipY mirror.
function Canvas:draw(sprite,x,y,flipX,flipY)
    if flipX then sprite=sprite:mirrored()end
    local W,H,frame=self.width,self.height,self.frame
    local w,h=sprite.w,sprite.h
    if x>=W or y>=H or x+w<=0 or y+h<=0 then return end
    local runs=sprite.runs;local source=sprite.source
    for k=1,#runs,4 do
        local dy=runs[k+2];if flipY then dy=h-1-dy end
        local ty=y+dy
        if ty>=0 and ty<H then
            local tx,len,src=x+runs[k+1],runs[k+3],runs[k]
            if tx<0 then src-=tx*4;len+=tx;tx=0 end
            if tx+len>W then len=W-tx end
            if len>0 then copy(frame,(ty*W+tx)*4,source,src,len*4)end
        end
    end
    local blended=sprite.blended
    for k=1,#blended,3 do
        local dy=blended[k+2];if flipY then dy=h-1-dy end
        local tx,ty=x+blended[k+1],y+dy
        if tx>=0 and tx<W and ty>=0 and ty<H then
            local o=blended[k]
            blendPixel(frame,(ty*W+tx)*4,readu8(source,o),readu8(source,o+1),readu8(source,o+2),readu8(source,o+3))
        end
    end
end
-- General path: destination pixels inside the transformed sprite are sampled
-- nearest-neighbour through the inverse of the sprite's local->canvas affine
-- map (a,b,c,d,tx,ty: x'=a*u+c*v+tx, y'=b*u+d*v+ty, u/v in sprite pixels),
-- tinted (0..255 per channel, straight alpha) and blended.
function Canvas:drawTransformed(sprite,a,b,c,d,tx,ty,r,g,bl,alpha)
    local det=a*d-b*c
    if det==0 then return end
    local W,H,frame=self.width,self.height,self.frame
    local w,h=sprite.w,sprite.h
    local x0,x1,y0,y1=math.huge,-math.huge,math.huge,-math.huge
    for _,p in {{0,0},{w,0},{0,h},{w,h}}do
        local px,py=a*p[1]+c*p[2]+tx,b*p[1]+d*p[2]+ty
        x0,x1,y0,y1=math.min(x0,px),math.max(x1,px),math.min(y0,py),math.max(y1,py)
    end
    local left,right=math.max(0,floor(x0)),math.min(W-1,math.ceil(x1)-1)
    local top,bottom=math.max(0,floor(y0)),math.min(H-1,math.ceil(y1)-1)
    if left>right or top>bottom then return end
    local ia,ib,ic,id=d/det,-b/det,-c/det,a/det
    local source,stride,sx,sy=sprite.source,sprite.stride,sprite.x,sprite.y
    local tr,tg,tb,ta=(r or 255)/255,(g or 255)/255,(bl or 255)/255,(alpha or 255)/255
    local plain=tr==1 and tg==1 and tb==1 and ta==1
    for py=top,bottom do
        local cy=py+.5-ty
        for px=left,right do
            local cx=px+.5-tx
            local u,v=floor(ia*cx+ic*cy),floor(ib*cx+id*cy)
            if u>=0 and u<w and v>=0 and v<h then
                local o=((sy+v)*stride+sx+u)*4
                local sa=readu8(source,o+3)
                if sa>0 then
                    if plain then blendPixel(frame,(py*W+px)*4,readu8(source,o),readu8(source,o+1),readu8(source,o+2),sa)
                    else blendPixel(frame,(py*W+px)*4,floor(readu8(source,o)*tr+.5),floor(readu8(source,o+1)*tg+.5),floor(readu8(source,o+2)*tb+.5),floor(sa*ta+.5))end
                end
            end
        end
    end
end
-- A sprite under one tint and linear map (a,b,c,d), resampled once
-- nearest-neighbour into its own buffer and cached; drawn later with :draw at
-- (round(tx)+ox, round(ty)+oy). flat replaces colour by the tint (silhouettes).
-- Returns nil when nothing is visible, or nil,true once the cache is full.
function Sprite:variant(a,b,c,d,r,g,bl,alpha,flat)
    -- Numeric keys (no string per draw): tint+flat, then the 4 matrix entries
    -- at 1/1024 (13 bits each while |entry|<4, exact in a double).
    local tintKey=((r*256+g)*256+bl)*256+alpha+(if flat then 2^32 else 0)
    local mapKey=(((floor(a*1024+.5)+4096)*8192+floor(b*1024+.5)+4096)*8192+floor(c*1024+.5)+4096)*8192+floor(d*1024+.5)+4096
    local cache=self.variants;if not cache then cache={};self.variants=cache;self.variantCount=0 end
    local byTint=cache[tintKey];if not byTint then byTint={};cache[tintKey]=byTint end
    local v=byTint[mapKey]
    if v~=nil then return v or nil end
    local key=mapKey;cache=byTint
    -- ponytail: per-sprite cap; fades/spins past it should use drawTransformed.
    if self.variantCount>=1024 then return nil,true end
    self.variantCount+=1
    v=false
    local det=a*d-b*c
    if det~=0 and alpha>0 then
        local w,h=self.w,self.h
        local x0,x1,y0,y1=math.min(0,a*w,c*h,a*w+c*h),math.max(0,a*w,c*h,a*w+c*h),math.min(0,b*w,d*h,b*w+d*h),math.max(0,b*w,d*h,b*w+d*h)
        local ox,oy=floor(x0+.5),floor(y0+.5)
        local vw,vh=floor(x1+.5)-ox,floor(y1+.5)-oy
        if vw>0 and vh>0 then
            local out=buffer.create(vw*vh*4)
            local ia,ib,ic,id=d/det,-b/det,-c/det,a/det
            local source,stride,sx,sy=self.source,self.stride,self.x,self.y
            for py=0,vh-1 do
                local cy=py+oy+.5
                for px=0,vw-1 do
                    local cx=px+ox+.5
                    local u,t=floor(ia*cx+ic*cy),floor(ib*cx+id*cy)
                    if u>=0 and u<w and t>=0 and t<h then
                        local o=((sy+t)*stride+sx+u)*4;local sa=readu8(source,o+3)
                        if sa>0 then
                            local q=(py*vw+px)*4
                            if flat then writeu8(out,q,r);writeu8(out,q+1,g);writeu8(out,q+2,bl)
                            else
                                writeu8(out,q,(readu8(source,o)*r+127)//255);writeu8(out,q+1,(readu8(source,o+1)*g+127)//255)
                                writeu8(out,q+2,(readu8(source,o+2)*bl+127)//255)
                            end
                            writeu8(out,q+3,(sa*alpha+127)//255)
                        end
                    end
                end
            end
            v=Canvas.sprite(out,vw,0,0,vw,vh);v.ox,v.oy=ox,oy
        end
    end
    cache[key]=v
    return v or nil
end
-- Axis-aligned rectangle, source-over (opaque rows are replicated by copy).
function Canvas:fillRect(x,y,w,h,r,g,b,a)
    local W,H,frame=self.width,self.height,self.frame
    local left,top,right,bottom=math.max(0,floor(x)),math.max(0,floor(y)),math.min(W,floor(x+w)),math.min(H,floor(y+h))
    if left>=right or top>=bottom then return end
    a=a or 255
    if a>=255 then
        local row=top*W*4;local word=bit32.bor(r,bit32.lshift(g,8),bit32.lshift(b,16),0xFF000000)
        for px=left,right-1 do writeu32(frame,row+px*4,word)end
        for py=top+1,bottom-1 do copy(frame,(py*W+left)*4,frame,row+left*4,(right-left)*4)end
    elseif a>0 then
        for py=top,bottom-1 do for px=left,right-1 do blendPixel(frame,(py*W+px)*4,r,g,b,a)end end
    end
end
-- Upload the frame to this canvas's EditableImage; returns its Content.
function Canvas:upload()
    if not self.image then
        self.image=game:GetService('AssetService'):CreateEditableImage({Size=Vector2.new(self.width,self.height)})
        self.content=Content.fromObject(self.image);self.size=Vector2.new(self.width,self.height)
    end
    self.image:WritePixelsBuffer(Vector2.zero,self.size,self.frame)
    return self.content
end
-- Show the frame through one EditableImage in an ImageLabel under parent.
function Canvas:present(parent)
    local content=self:upload()
    if not self.label then
        local label=Instance.new('ImageLabel');label.Name='PixelCanvas';label.BackgroundTransparency=1;label.BorderSizePixel=0
        label.Size=UDim2.fromScale(1,1);label.ResampleMode=Enum.ResamplerMode.Pixelated
        label.ImageContent=content;label.Parent=parent;self.label=label
    end
end
function Canvas:destroy()
    if self.label then self.label:Destroy();self.label=nil end
    if self.image then self.image:Destroy();self.image=nil end
end
return Canvas
