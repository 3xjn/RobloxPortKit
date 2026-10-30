"""One command: python tools/mobile_perf_gate.py

Original managed gameplay in a native-disabled Lune interpreter, followed by
Edit-only captured GUI replay in the two assigned Studios. Never controls Play.
Exit 1 = budget/error failure, 2 = missing/incomplete evidence. RGBA8 byte counts
are exact w*h*4 metadata sums, not actual GPU memory (mips/compression excluded).
"""
from __future__ import annotations
import argparse
import json
import math
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
GAMES = [('Dash Queen', 'jumpking2luau', '886693a8-9a1d-4404-a8b6-1a783b8687ad'),
         ('Heavenly', 'celeste2luau', 'bf3f2e1e-68c3-4245-9c69-3ef2cd7f9d39')]

class StudioMCP:
    def __init__(self):
        base = Path(os.environ['LOCALAPPDATA']) / 'Roblox'
        bat = (base / 'mcp.bat').read_text()
        match = re.search(r'if exist "([^"\n]+StudioMCP.exe)"', bat)
        executable = Path(match[1]) if match else max((base/'Versions').glob('*/StudioMCP.exe'), key=lambda p:p.stat().st_mtime)
        self.proc = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True, encoding='utf-8', creationflags=subprocess.CREATE_NO_WINDOW)
        self.messages = queue.Queue(); self.serial = 0
        def read():
            for line in self.proc.stdout:
                try: self.messages.put(json.loads(line))
                except ValueError: pass
        threading.Thread(target=read, daemon=True).start()
        self.rpc('initialize', {'protocolVersion':'2024-11-05', 'capabilities':{}, 'clientInfo':{'name':'mobile-perf-gate','version':'1'}})
        self.proc.stdin.write(json.dumps({'jsonrpc':'2.0','method':'notifications/initialized'})+'\n'); self.proc.stdin.flush()
        self.names = [t['name'] for t in self.rpc('tools/list', {})['tools']]
    def rpc(self, method, params, timeout=120):
        self.serial += 1; serial=self.serial
        self.proc.stdin.write(json.dumps({'jsonrpc':'2.0','id':serial,'method':method,'params':params})+'\n'); self.proc.stdin.flush()
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            result=self.messages.get(timeout=max(.01,deadline-time.monotonic()))
            if result.get('id') == serial:
                if 'error' in result: raise RuntimeError(str(result['error']))
                return result['result']
        raise TimeoutError(method)
    def tool(self, suffix, args):
        name=next(n for n in self.names if n==suffix or n.endswith('_'+suffix))
        result=self.rpc('tools/call', {'name':name,'arguments':args})
        if result.get('isError'): raise RuntimeError(str(result))
        return result
    def close(self):
        self.proc.terminate()
        try: self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired: self.proc.kill()

def summarize(frames, key):
    values=sorted(f[key] for f in frames)
    return {'mean':sum(values)/len(values), 'p95':values[math.ceil(len(values)*.95)-1], 'max':values[-1]}

def metrics(raw):
    groups={}
    for phase in sorted({f['phase'] for f in raw['frames']}):
        frames=[f for f in raw['frames'] if f['phase']==phase]
        timing=summarize(frames,'totalMs')
        estimates={}
        for name,multiplier in [('midPhone',3.5),('budgetPhone',5.0)]:
            ms=timing['p95']*multiplier
            estimates[name]={'multiplier':multiplier,'p95Ms':ms,'estimatedFPS':1000/ms,'cpu60fpsPass':ms<16.67}
        groups[phase]={'frames':len(frames),'hostMs':timing,'headlessSubmissionMs':summarize(frames,'submissionMs'),'estimates':estimates,
                       'activeGuiNodesPeak':max(f['activeGuiNodes'] for f in frames),
                       'parkedGuiNodesPeak':max(f['parkedGuiNodes'] for f in frames),
                       'propertyWritesPerFrame':summarize(frames,'propertyWrites'),
                       'netHeapKBPerFrame':summarize(frames,'heapDeltaKB'),
                       'referenced2DSheetsPeak':max(f['activeSheets'] for f in frames),
                       'referenced2DDecodedRGBA8BytesPeak':max(f['decodedRGBA8Bytes'] for f in frames),
                       'unmeasuredGeometrySubmissionsPeak':max(f['geometrySubmissions'] for f in frames)}
    return groups

STUDIO_CODE = r'''
local Http=game:GetService('HttpService')
local Run=game:GetService('RunService')
local function edit()assert(not Run:IsRunning(),'Phone gate requires Edit; user Play is untouched')end
edit()
local base=BASE_URL
local originalHttp=Http.HttpEnabled
if not originalHttp then Http.HttpEnabled=true end
local fetched,payload=pcall(function()return Http:JSONDecode(Http:GetAsync(base..'/payload'))end)
if not fetched then Http.HttpEnabled=originalHttp;error(payload)end
assert(game.PlaceId==payload.placeId,'Wrong Studio place')
local temp=Instance.new('Folder');temp.Name='MobilePerfGateProbe'
local module=Instance.new('ModuleScript');module.Name='GpuScene';module.Source=payload.sceneSource;module.Parent=temp
local profile=Instance.new('ModuleScript');profile.Name='MobileProfile';profile.Source=payload.profileSource;profile.Parent=temp
local gui=Instance.new('ScreenGui');gui.Name='MobilePerfGateProbe';gui.IgnoreGuiInset=true;gui.DisplayOrder=-1000
local root=Instance.new('Frame');root.Size=UDim2.fromOffset(844,390);root.BackgroundTransparency=1;root.ClipsDescendants=true;root.Parent=gui
local ok,result=xpcall(function()
    local scene=require(module).new(root,Instance.new,{mobile=true,keepParented=true,imageReserve=0})
    gui.Parent=game:GetService('CoreGui')
    local rows={}
    for cycle=1,3 do for _,frame in payload.replays do
        edit();local heap=collectgarbage('count');local start=os.clock();scene:begin()
        for _,d in frame.images do
            scene:image({ImageContent=Content.fromUri(d.uri),ImageRectOffset=Vector2.new(d.cx,d.cy),ImageRectSize=Vector2.new(d.cw,d.ch),
                Position=UDim2.fromOffset(d.px,d.py),Size=UDim2.fromOffset(d.w,d.h),AnchorPoint=Vector2.new(d.ax,d.ay),
                ImageColor3=Color3.new(d.r,d.g,d.b),ImageTransparency=d.alpha,Rotation=d.rotation,ZIndex=d.z})
        end
        scene:finish();local ms=(os.clock()-start)*1000
        if cycle>1 then rows[#rows+1]={phase=frame.phase,hostMs=ms,activeGuiNodes=scene.imageCount+scene.frameCount,
            parkedGuiNodes=scene.parkedCount,propertyWrites=scene.writes,netHeapKB=collectgarbage('count')-heap}end
        task.wait()
    end end
    scene:destroy()
    return {frames=rows,viewport={844,390},mobile=true,backend='Studio Edit captured GUI replay; native directives removed',
        editableImagesCreated=0,limitations={'GUI replay only; excludes game simulation, mesh composition and GPU time','No Play controls; viewport is a sized GUI root, not device emulation'}}
end,debug.traceback)
gui:Destroy();temp:Destroy()
if not ok then Http.HttpEnabled=originalHttp;error(result)end
local sent,message=pcall(function()Http:PostAsync(base..'/result',Http:JSONEncode(result),Enum.HttpContentType.ApplicationJson)end)
Http.HttpEnabled=originalHttp
assert(sent,message)
return 'Phone gate Edit replay complete'
'''

def studio_replay(mcp, game, studio_id, raw):
    state=mcp.tool('get_studio_state', {'studio_id':studio_id})
    text='\n'.join(c.get('text','') for c in state.get('content',[]))
    if 'Current Studio Mode: Edit' not in text:
        return {'state':text,'status':'skipped-user-play-or-unavailable','fallback':'Lune interpreter + real sheet metadata'}
    payload={'replays':raw['replays'],'placeId':122448396735545 if game=='Dash Queen' else 131388266857137,
             'sceneSource':(ROOT/'runtime/GpuScene.luau').read_text().replace('--!native',''),
             'profileSource':(ROOT/'runtime/MobileProfile.luau').read_text()}
    class Handler(BaseHTTPRequestHandler):
        result=None
        def do_GET(self):
            data=json.dumps(payload).encode();self.send_response(200);self.end_headers();self.wfile.write(data)
        def do_POST(self):
            Handler.result=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            self.send_response(200);self.end_headers();self.wfile.write(b'OK')
        def log_message(self,*args): pass
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        code=STUDIO_CODE.replace('BASE_URL',json.dumps('http://127.0.0.1:'+str(server.server_port)))
        mcp.tool('execute_luau', {'studio_id':studio_id,'datamodel_type':'Edit','code':code})
        if Handler.result is None: raise RuntimeError('Studio replay did not return metrics')
        result=Handler.result; result['status']='measured'; result['state']=text
        result['hostMs']=summarize(result['frames'],'hostMs')
        result['phases']={phase:{'hostMs':summarize([f for f in result['frames'] if f['phase']==phase],'hostMs')} for phase in {f['phase'] for f in result['frames']}}
        return result
    finally: server.shutdown();server.server_close()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline',action='store_true',help='Explicit Lune-only run; no Studio connection')
    parser.add_argument('--output',type=Path,default=ROOT/'.cache/mobile-perf-gate.json')
    args=parser.parse_args();args.output=args.output.resolve();args.output.parent.mkdir(parents=True,exist_ok=True)
    report={'schemaVersion':1,'generatedAtUTC':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'games':[],
            'budgetMs':16.67,'phoneEstimates':'p95 host CPU x 3.5 / x 5.0; estimates, not measured phone FPS',
            'vramDefinition':'Exact decoded base-level RGBA8 w*h*4 bytes for the named metadata sheet set; excludes driver/mips/meshes',
            'fullDevice60fpsPass':False,'coverage':'Incomplete device/GPU coverage; CPU gate can fail but cannot certify live phone FPS'}
    mcp=None
    if not args.offline:
        try: mcp=StudioMCP()
        except Exception as exc: report['studioConnectionError']=str(exc)
    failures=False
    try:
        for game,repo,studio_id in GAMES:
            raw_path=args.output.parent/(repo+'-mobile-perf-raw.json')
            if raw_path.exists(): raw_path.unlink()
            command=['lune','run',str(ROOT/'tools/mobile_perf_runner.luau'),game,raw_path.as_posix(),ROOT.parent.as_posix()]
            print('Measuring '+game+' (interpreter, active gameplay)...',flush=True)
            try: result=subprocess.run(command,cwd=ROOT.parent/repo,capture_output=True,text=True,encoding='utf-8',timeout=180)
            except (OSError,subprocess.SubprocessError) as exc:
                report['games'].append({'game':game,'error':str(exc)});failures=True;continue
            if result.returncode or '[Stack Begin]' in result.stdout+result.stderr or not raw_path.exists():
                report['games'].append({'game':game,'error':result.stdout+result.stderr});failures=True;continue
            raw=json.loads(raw_path.read_text());groups=metrics(raw)
            entry={k:v for k,v in raw.items() if k not in ('frames','replays')};entry['phases']=groups;entry['rawReport']=str(raw_path)
            if mcp:
                try: entry['studio']=studio_replay(mcp,game,studio_id,raw)
                except Exception as exc: entry['studio']={'status':'error','error':str(exc)}
            else: entry['studio']={'status':'offline' if args.offline else 'unavailable'}
            for phase,p in groups.items():
                replay=entry['studio'].get('phases',{}).get(phase)
                if replay:
                    p['studioGuiReplayMs']=replay['hostMs']
                    p['combinedCpuEstimateMs']={key:p['headlessSubmissionMs'][key]+replay['hostMs'][key] for key in ('mean','p95')}
                    p['estimateBasis']='Lune simulation/submission + Studio GUI replay; sum of phase p95s, not paired frame latency'
                    for name,multiplier in [('midPhone',3.5),('budgetPhone',5.0)]:
                        ms=p['combinedCpuEstimateMs']['p95']*multiplier
                        p['estimates'][name]={'multiplier':multiplier,'p95Ms':ms,'estimatedFPS':1000/ms,'cpu60fpsPass':ms<16.67}
                else:p['estimateBasis']='Lune simulation/submission + headless retained 2D projection'
            entry['cpuGatePass']=not raw['errors'] and raw['editableImagesCreated']==0 and all(
                p['estimates']['budgetPhone']['cpu60fpsPass'] for p in groups.values())
            failures |= not entry['cpuGatePass'];report['games'].append(entry)
    finally:
        if mcp:mcp.close()
        args.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print('\nGame / phase                 Host mean/p95  Mid x3.5 ms/FPS  Budget x5 ms/FPS  CPU60  Sheets RGBA8 MiB  GUI A/P  Writes/f  Heap KB/f')
    for game in report['games']:
        if 'error'in game: print(game['game']+': ERROR '+game['error'][-1200:]);continue
        for phase,p in game['phases'].items():
            mid,budget=p['estimates']['midPhone'],p['estimates']['budgetPhone']
            print(f"{game['game']+'/'+phase:28} {p['hostMs']['mean']:6.2f}/{p['hostMs']['p95']:6.2f}  "
                  f"{mid['p95Ms']:6.2f}/{mid['estimatedFPS']:5.1f}   {budget['p95Ms']:6.2f}/{budget['estimatedFPS']:5.1f}   "
                  f"{'PASS' if budget['cpu60fpsPass'] else 'FAIL':4}  {p['referenced2DSheetsPeak']:3} {p['referenced2DDecodedRGBA8BytesPeak']/1048576:8.2f} "
                  f"{p['activeGuiNodesPeak']:4}/{p['parkedGuiNodesPeak']:<4} {p['propertyWritesPerFrame']['mean']:8.1f} {p['netHeapKBPerFrame']['mean']:9.1f}")
        print('  Studio: '+str(game['studio'].get('hostMs',game['studio']['status'])))
        for phase,p in game['phases'].items():
            if 'studioGuiReplayMs'in p: print(f"  Studio {phase} GUI mean/p95: {p['studioGuiReplayMs']['mean']:.3f}/{p['studioGuiReplayMs']['p95']:.3f} ms")
        print('  Residency: '+json.dumps(game['residency'])+'; desktop source catalog: '+json.dumps(game['desktopCatalog']))
    print('Phone estimates use Lune simulation/submission + Studio GUI replay where available (sum of phase p95s); otherwise Lune host p95.')
    print('JSON: '+str(args.output));print(report['coverage'])
    return 1 if failures else 2

if __name__=='__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    raise SystemExit(main())
