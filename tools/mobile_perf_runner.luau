-- Interpreter-only, original managed gameplay + retained 2D host projection.
-- Native mesh upload, Roblox bridge, GPU and network timings are unavailable.
local fs,luau,rbx,serde,process,task=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox'),require('@lune/serde'),require('@lune/process'),require('@lune/task')
local gameName,outPath,sdk=process.args[1],process.args[2],process.args[3]
local cache={}
local function compile(source,name)
    local ok,result=pcall(function()return luau.load(luau.compile(source,{optimizationLevel=2}),{debugName=name,codegenEnabled=false})()end)
    assert(ok,name..': '..tostring(result));return result
end
local function node(path)
    return setmetatable({},{__index=function(_,key)
        if key=='Parent' then return node(path:match('^(.*)/[^/]+$')) end
        return node(path..'/'..key)
    end,__tostring=function()return path end})
end
local function load(path)
    path=tostring(path)
    local group,name=path:match('^([MPRC]):([^/].*)$')
    if group then path=(if group=='M'then sdk..'/xna2luau/runtime/'elseif group=='P'then sdk..'/RobloxPortKit/runtime/'elseif group=='R'then 'runtime/'else 'runtime/Managed/')..name end
    path=path:gsub('/xna2luau/PortKit/', '/RobloxPortKit/runtime/')
    if cache[path]~=nil then return cache[path]end
    assert(fs.isFile(path..'.luau'),'Module unavailable: '..path)
    local source=fs.readFile(path..'.luau'):gsub('%-%-!native','')
    local wrap='return function(script,require,Enum,Vector2,Vector3,UDim2,UDim,Color3,CFrame,Content,Instance,task)\n'..source..'\nend'
    local function factory(kind)
        local item={ClassName=kind,Visible=false}
        function item:Destroy()self.Parent=nil end
        return item
    end
    local value=compile(wrap,path)(node(path),load,rbx.Enum,rbx.Vector2,rbx.Vector3,rbx.UDim2,rbx.UDim,rbx.Color3,rbx.CFrame,
        {none='none',fromUri=function(uri)return uri end},{new=factory},task)
    cache[path]=value;return value
end
local function M(name)return load(sdk..'/xna2luau/runtime/'..name)end
local function P(name)return load(sdk..'/RobloxPortKit/runtime/'..name)end
local function R(name)return load('runtime/'..name)end
local function alias(name)
    local group,path=name:match('^(%w):(.*)$')
    return if group=='M'then M(path)elseif group=='P'then P(path)elseif group=='R'then R(path)else R('Managed/'..path)
end
local f
if gameName=='Heavenly' then
    -- Reuse the game's native-boundary fixture initialization, but compile all
    -- managed/SDK modules with explicit bindings, safeenv and codegen disabled.
    local source=fs.readFile('tests/managed_fixture.luau')
    local fixtureStart=assert(source:find('local runtime=',1,true));source=source:sub(fixtureStart)
    f=compile('local fs,serde,rbx=require("@lune/fs"),require("@lune/serde"),require("@lune/roblox")\nreturn function(load)\n'..source..'\nend','celeste-fixture')(alias)
else
    local rt=M('ManagedRuntime').new();local keys={}
    local catalog=R('Assets/ContentCatalog')
    local provider=R('AssetsProvider').new(catalog,P('Base64').decode,nil,function(data)return serde.decompress('zstd',data)end)
    local backend={assets=provider,allowEditableImages=false,editableImagesCreated=0}
    local modules=setmetatable({WaitForChild=function(_,name)return node('runtime/Managed/'..name)end,
        FindFirstChild=function(_,name)return if fs.isFile('runtime/Managed/'..name..'.luau')then node('runtime/Managed/'..name)else nil end},
        {__index=function(_,name)return node('runtime/Managed/'..name)end})
    local env=M('Loader')(rt,modules,function(e,m)
        m.scheduler=M('CooperativeScheduler').new({budgetSeconds=.003})
        M('NativeThreading')(e,m.scheduler);R('SaveEncoding')(P('Base64'),e.System.cooperate)
        e.System.Collections.Concurrent={ConcurrentDictionary_2=e.System.Dictionary};e.System.Collection_1=e.System.List
        M('VirtualFileSystem')(e,R('SaveVfs').new(provider,P('FileStore').new('mobile-perf-isolated')))
        e.System.Reflection.Assembly.getLocation=function()return 'JumpKing.exe'end
        M('Crypto')(e,function(n)return string.rep(string.char(1),n)end)
        e.System.Windows={Forms={MessageBox={Show=function(message)error(message)end}}}
        M('DirectInput')(e);M('Steam')(e);M('XmlAttributes')(e);M('XmlSerializer')(e);R('SdkBindings')(e)
        M('XNA')(e,m,backend);M('XnaInput')(e,{keyboard=function()return keys end})
    end)
    f={env=env,runtime=rt,backend=backend,input={keys=keys},provider=provider}
end
local E,rt,backend=f.env,f.runtime,f.backend
local index,pages
if gameName=='Heavenly'then
    index=serde.decode('json',fs.readFile('.cache/source-texture-index.json'))
    for _,sprite in index.textures do for _,part in sprite.parts do part.page='source:'..part.page end end
    pages={};local uploads=serde.decode('json',fs.readFile('data/source-texture-uploads.json')).pages
    for id,page in index.pages do pages['source:'..id]=table.clone(page);pages['source:'..id].uri=assert(uploads['source:'..id]).uri end
else pages=f.provider.catalog.pages end
local errors,diagnostics={},{}
local pool={images={},pins={},editableImagePolicy=P('EditableImagePolicy').new({allowEditableImages=false}),request=function()error('EditableImage prohibited')end}
function pool:import(id,uri,w,h)
    self.images[id]=self.images[id]or {published=true,content=uri,width=w,height=h};return self.images[id]
end
function pool:pin(id)self.pins[id]=(self.pins[id]or 0)+1 end
function pool:unpin(id)local n=(self.pins[id]or 0)-1;self.pins[id]=if n>0 then n else nil end
local assets
if gameName=='Heavenly'then
    local hashes=serde.decode('json',fs.readFile('.cache/tile-chunks/tile-source-fingerprints.json'))
    local static={};for id,page in pages do static[id]=page.uri end
    assets={pool=pool,errors=errors,staticTextures=static,sourceTextureIndex=function()return index end,sourceSprite=function(_,path)return index.textures[path]end,
        sprite=function(_,path)return index.textures[path]end,page=function(_,id)return pages[id]end,
        sourceTextureFingerprint=function(_,path)return hashes[path]end,
        image=function(_,id)local p=assert(pages[id],tostring(id));return pool:import(id,p.uri,p.w,p.h)end}
else assets=R('GraphicsAssets').new(f.provider,pool,function(uri)return uri end)end
local graph=M('RenderGraph').new(if gameName=='Heavenly'then 1920 else 480,if gameName=='Heavenly'then 1080 else 360,M('GpuEffects'))
local factory=function(kind)local item={ClassName=kind};function item:Destroy()self.Parent=nil end;return item end
local profile=P('MobileProfile').detect({mobile=true,viewport=rbx.Vector2.new(844,390)})
local scene=P('GpuScene').new({},factory,{mobileProfile=profile,keepParented=true,imageReserve=0})
local renderer={scene=scene,assets=assets,framePins={},virtualWidth=844,virtualHeight=390,additiveAvailable=function()return false end}
local gpu=M('GpuRenderer');local geometry=0
backend.assets=assets;backend.graph=graph
local bitmap=M('BitmapFontHost').new(backend,{scheduler={}})
local planner
if gameName=='Heavenly'then
    local config=R('FontLayerCatalog')(assets,M('BitmapFontHost').isCapturedAbsoluteDraw)
    config.onMissingGlyph=function(message)diagnostics[#diagnostics+1]=message end
    planner=M('PublishedFontLayers').new(config);backend.publishedFontLayers=planner
    assets=M('PublishedAssetOverlay').new(assets,config.assets,{contentFromUri=function(uri)return uri end});renderer.assets=assets
end
function backend:spriteScalars(texture,cx,cy,cw,ch,px,py,ox,oy,r,g,b,a,sx,sy,rot,state)
    if texture.renderTarget then return graph:blitScalars(texture,cx,cy,cw,ch,px,py,ox,oy,r,g,b,a,sx,sy,rot,state.graphState)end
    return graph:textureScalars(texture.Path,cx,cy,cw,ch,px,py,ox,oy,r,g,b,a,sx,sy,rot,state.graphState)
end
function backend:texture(path,clip,pos,origin,color,scale,rot)
    return graph:textureScalars(path,clip.X,clip.Y,clip.Width,clip.Height,pos.X,pos.Y,origin.X,origin.Y,color.R,color.G,color.B,color.A,scale.X,scale.Y,rot or 0,nil)
end
-- Preserve XNA's real font capture attestation against the GraphicsHost class.
setmetatable(backend,M('GraphicsHost'));backend.bitmapFont=bitmap;backend.pendingFramePins={};backend.framePins={};backend.pins={}
backend.assets=assets
backend.beginBatch=function()end;backend.endBatch=function()end
function backend:target(target)graph:target(target)end
function backend:rectangleColor(x,y,w,h,color)graph:rectangle(x,y,w,h,color)end
function backend:triangles()geometry+=1 end
function backend:indexed()geometry+=1 end
function backend:renderTarget(target,pos,color,batch,clip,origin,scale,rotation)
    graph:blit(target,pos,color,batch,clip,origin,scale,rotation)
end
function backend:clear(color)graph:clear(color)end
local function decodedSet(ids,lookup)
    local bytes,slots,unique=0,0,{}
    for id in ids do
        slots+=1;local page=assert(lookup(id));local uri=page.uri
        if not uri then uri=assert(f.provider.catalog.uploads[page.file]).assetId end
        local size=page.w*page.h*4
        if unique[uri]then assert(unique[uri]==size,'Conflicting dimensions for published URI '..uri)
        else unique[uri]=size;bytes+=size end
    end
    local textures=0;for _ in unique do textures+=1 end
    return bytes,slots,textures
end
local extraDraw
local rows,replays,replayCounts={},{},{}
local function replayFrame(phase)
    local n=replayCounts[phase]or 0
    if n>=8 then return end
    replayCounts[phase]=n+1
    local images={}
    for _,entry in scene.images do if entry.lastUsed==scene.drawGeneration and not entry.parked then
        local v=entry.values;local pos,size,offset,crop,color=v.Position,v.Size,v.ImageRectOffset,v.ImageRectSize,v.ImageColor3
        images[#images+1]={uri=tostring(v.ImageContent),px=pos.X.Scale*844+pos.X.Offset,py=pos.Y.Scale*390+pos.Y.Offset,
            w=size.X.Scale*844+size.X.Offset,h=size.Y.Scale*390+size.Y.Offset,cx=offset.X,cy=offset.Y,cw=crop.X,ch=crop.Y,
            r=color.R,g=color.G,b=color.B,alpha=v.ImageTransparency or 0,rotation=v.Rotation or 0,
            ax=v.AnchorPoint.X,ay=v.AnchorPoint.Y,z=v.ZIndex or 1}
    end end
    replays[#replays+1]={phase=phase,images=images}
end
local function frame(phase,record,update)
    local heap=collectgarbage('count');local start=os.clock();geometry=0;graph:begin()
    if update~=false then rt:step(1/60)end
    rt:render();if extraDraw then extraDraw()end;local submitted=os.clock()
    scene:begin();local used={}
    graph:visit(function(d,m,tint)
        if d.kind~='texture'or type(d.path)~='string'then return end
        local sprite=assets:sourceSprite(d.path)or assets:sprite(d.path)
        for _,part in sprite.parts do if math.max(d.clipX,part.fx)<math.min(d.clipX+d.clipW,part.fx+part.w) and math.max(d.clipY,part.fy)<math.min(d.clipY+d.clipH,part.fy+part.h)then used[part.page]=true end end
        gpu.texture(renderer,d.path,{X=d.clipX,Y=d.clipY,Width=d.clipW,Height=d.clipH},
            {X=m[1]*d.posX+m[3]*d.posY+m[5],Y=m[2]*d.posX+m[4]*d.posY+m[6]},
            {X=d.origX,Y=d.origY},{R=d.r*tint.R/255,G=d.g*tint.G/255,B=d.b*tint.B/255,A=d.a*tint.A/255},
            {X=d.scaleX*m[1],Y=d.scaleY*m[4]},d.rot,1)
    end,nil,nil,{bitmapLayers=if planner then function(draw,list,m,t,w,mask,composite,flat)return backend:resolveFontLayers(draw,list,m,t,w,mask,composite,flat)end else nil,
        matrices={{844/(if gameName=='Heavenly'then 1920 else 480),0,0,390/(if gameName=='Heavenly'then 1080 else 360),0,0}}})
    scene:finish();local finished=os.clock();local heapDelta=collectgarbage('count')-heap
    if record then replayFrame(phase)end
    local bytes,count,textures=decodedSet(used,function(id)return assets:page(id)end)
    if record then rows[#rows+1]={phase=phase,totalMs=(finished-start)*1000,submissionMs=(submitted-start)*1000,composeMs=(finished-submitted)*1000,
        activeGuiNodes=scene.imageCount+scene.frameCount,parkedGuiNodes=scene.parkedCount,propertyWrites=scene.writes,
        heapDeltaKB=heapDelta,activeSheets=count,uniqueDecodedTextures=textures,decodedRGBA8Bytes=bytes,geometrySubmissions=geometry}end
end
local function keys(values)table.clear(f.input.keys);for i,v in values do f.input.keys[i]=v end end
local function ticks(n,phase,record,update)for i=1,n do frame(phase,record,update);if i%10==0 then task.wait()end end end
if gameName=='Heavenly'then
    local C=E.Celeste
    local main=coroutine.create(function()C.Celeste.Main(E.System.Array(E.System.String)(0))end);assert(coroutine.resume(main))
    local deadline=os.clock()+60
    while not rt.started do assert(os.clock()<deadline,'Celeste boot timeout');task.wait()end
    repeat rt:step(1/60);task.wait();assert(os.clock()<deadline,'Title timeout')until rt.scene and rt.scene.Current and rt.scene.Current.__name__=='Celeste.OuiTitleScreen'
    if not C.SaveData.Instance then C.SaveData.Start(C.SaveData(),0)end
    local overworld=rt.scene
    overworld:Goto(E.System.typeof(C.OuiChapterSelect))
    ticks(60,'chapter-select',false);ticks(90,'chapter-select',true)
    -- Explicit regression crop added to a real Chapter Select captured frame.
    local state=M('GpuEffects').capture({name='alpha'},{name='pointClamp'})
    local variant
    for _,v in planner.catalog.variants do if v.sourcePath=='content/graphics/atlases/gui0.data' and v.configFingerprint=='e33f6738d5786d0882c528ff233547e5a67e3d51de0bb038e8159f745104d089'then variant=v;break end end
    assert(variant,'Exact live-crash font variant unavailable')
    local passes={}
    for _,o in variant.offsets do passes[#passes+1]={dx=o[1]/(variant.strokeDensity or 1),dy=o[2]/(variant.strokeDensity or 1),addX=true,addY=true,tint=3}end
    for _,o in variant.edgeOffsets or {}do passes[#passes+1]={dx=o[1],dy=o[2],addX=true,addY=true,tint=2}end
    passes[#passes+1]={dx=0,dy=0,addX=false,addY=false,tint=1}
    local colors={{R=255,G=255,B=255,A=255},{R=72,G=61,B=139,A=255},{R=0,G=0,B=0,A=variant.strokeAlpha}}
    local compact=assert(M('CompactFontCommands').capture({glyphs={{texture={Path=variant.sourcePath},cx=3776,cy=2984,cw=102,ch=105,px=400,py=400,ox=0,oy=0}},
        passes=passes,colors=colors,scaleX=1,scaleY=1},state,nil,'alpha'))
    local checked=false
    local token,font={}, {LineHeight=105,Size=105};local batch={graphState=state,blend={name='alpha'}}
    extraDraw=function()graph:target(nil);assert(bitmap:renderAbsolute(font,'live-unbaked-crop',{X=400,Y=400},{X=0,Y=0},{X=1,Y=1},colors[1],0,colors[2],2,colors[3],
        batch,{compact=function()return compact end},token))
        if checked then return end;checked=true
        local draw=graph:list()[#graph:list()]
        assert(M('BitmapFontHost').isCapturedAbsoluteDraw(draw),'Injected glyph must have real SDK provenance')
        assert(planner:plan(draw,nil,{1,0,0,1,0,0},{A=255},{l=0,t=0,r=1920,b=1080},0,'alpha',false)==nil)
    end
    ticks(20,'chapter-select-unbaked',true,false);extraDraw=nil
    assert(#diagnostics>=1,'Unbaked live glyph must emit a diagnostic')
    local area=C.AreaData.Areas:get(0);local first
    for _,room in E.System.each(area.Mode:get(0).MapData.Levels)do if not first and not room.Dummy and #room.Spawns>0 then first=room.Name end end
    local session=E.System.new(C.Session,2,C.AreaKey(0,0),nil,nil);session.Level=assert(first)
    local loader=C.LevelLoader(session,nil);deadline=os.clock()+40
    while not loader.Loaded do assert(os.clock()<deadline,'Prologue timeout');task.wait()end
    loader.PlayerIntroTypeOverride=8;loader:Update();local previous=rt.scene;previous:End();rt.scene=loader.Level;rt.nextScene=nil;rt.scenePending=false
    rt.Engine.Instance:OnSceneTransition(previous,rt.scene);rt.scene:Begin()
    ticks(30,'prologue',false);keys({39});ticks(90,'prologue',true);keys({})
else
    local failure;local main=coroutine.create(function()local ok,err=xpcall(function()E.SteamJK.Program.Main()end,debug.traceback);if not ok then failure=err end end)
    assert(coroutine.resume(main));local deadline=os.clock()+60
    while not rt.started do assert(not failure,failure);assert(os.clock()<deadline,'Jump King boot timeout');rt.scheduler.step(1/60);task.wait(.001)end
    local title=rt.gameInstance.m_game.m_title_screen
    for i=1,5000 do
        keys(if i%90==1 then {32}else {});rt:step(1/60)
        if E.JumpKing.GameManager.GameLoop.m_player then break end
        if i%10==0 then task.wait()end
    end
    local player=assert(E.JumpKing.GameManager.GameLoop.m_player,'Jump King gameplay timeout');local body=player.m_body
    keys({});for _=1,600 do rt:step(1/60);if body:getIsOnGround()then break end end
    ticks(20,'grounded',false);keys({32});ticks(15,'jump-charge',true);keys({});ticks(60,'jump-flight',true)
    -- Controlled placement exercises the actual camera/screen transition code.
    local startY=body.Position.Y
    for _,screen in {1,2,3}do body.Position.Y=-screen*360+100;body.Velocity.Y=0;ticks(15,'screen-transition',true)end
    body.Position.Y=startY
end
for _,message in E.System.errors or {}do errors[#errors+1]=message end
for _,message in assets.errors or {}do if assets.errors~=errors then errors[#errors+1]=message end end
local residency={}
if gameName~='Heavenly'then
    local provider={PreloadAsync=function(_,labels,callback)for _,label in labels do label.IsLoaded=true;callback(label.ImageContent,'Success')end end,GetAssetFetchStatus=function()return 'Success'end}
    for _,mobile in {true,false}do
        local streamer=R('TextureStreamer').new(f.provider.catalog,{SetAttribute=function()end}, {mobile=mobile,provider=provider,factory=factory,success='Success',scheduler={wait=function()end}})
        streamer:boot();local peakBytes,peakSheets=0,0
        for screen=1,166 do
            streamer:setScreen(screen)
            for _=1,40 do local batch=streamer:nextBatch();if #batch>0 then streamer:batch(batch)end end
            local bytes,count=decodedSet(streamer.pins,function(id)return pages[id]end)
            peakBytes=math.max(peakBytes,bytes);peakSheets=math.max(peakSheets,count)
        end
        residency[if mobile then 'mobile'else 'desktop']={peakPinnedSheets=peakSheets,peakDecodedRGBA8Bytes=peakBytes}
        for _,message in streamer.errors do errors[#errors+1]=message end
        streamer:destroy()
    end
end
if gameName=='Heavenly'then residency.unavailable='Full boot pins and mesh texture residency are not exposed by the native-boundary fixture; frame rows report referenced 2D sheets only'end
local desktopBytes,desktopSheets,desktopTextures=decodedSet(pages,function(id)return pages[id]end)
fs.writeFile(outPath,serde.encode('json',{game=gameName,backend='Lune interpreter; retained 2D projection',viewport={844,390},mobile=true,codegenEnabled=false,
    limitations={'Headless native boundary: no Roblox property bridge, GPU, texture decode or mesh composition time','Active sheets are referenced 2D sheets, not a driver residency measurement','heapDeltaKB is net heap growth, not allocated GC bytes'},
    frames=rows,replays=replays,residency=residency,errors=errors,diagnostics=diagnostics,editableImagesCreated=pool.editableImagePolicy.editableImagesCreated or 0,
    desktopCatalog={sheets=desktopSheets,decodedRGBA8Bytes=desktopBytes,uniqueTextures=desktopTextures}},true))
print('PERF_RESULT',outPath,#rows)
