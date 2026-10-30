"""Read Steam's installed binary KeyValues schema without credentials or APIs."""
from pathlib import Path
import argparse
import hashlib
import json
import struct

def read_keyvalues(data):
    offset=0
    def string():
        nonlocal offset
        end=data.index(0,offset);value=data[offset:end].decode('utf-8');offset=end+1;return value
    def object_():
        nonlocal offset
        result={}
        while True:
            kind=data[offset];offset+=1
            if kind==8:return result
            key=string()
            if kind==0:value=object_()
            elif kind==1:value=string()
            elif kind in (2,3,4,6):
                value=struct.unpack_from('<f' if kind==3 else '<i',data,offset)[0];offset+=4
            elif kind==7:value=struct.unpack_from('<Q',data,offset)[0];offset+=8
            else:raise ValueError(f'Unsupported KeyValues type {kind} at {offset}')
            if key in result:raise ValueError(f'Duplicate schema key {key}')
            result[key]=value
    result=object_()
    if offset!=len(data):raise ValueError('Trailing schema bytes')
    return result

def export_schema(path,app_id):
    raw=Path(path).read_bytes();schema=read_keyvalues(raw)[str(app_id)]
    achievements=[]
    for stat in schema['stats'].values():
        for bit in stat.get('bits',{}).values():
            display=bit['display']
            achievements.append(dict(id=bit['name'],name=display['name'],description=display.get('desc',{}),
                hidden=bool(display.get('hidden',0)),icon=display.get('icon'),lockedIcon=display.get('icon_gray')))
    return dict(appId=app_id,schemaSHA256=hashlib.sha256(raw).hexdigest(),achievements=achievements)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('schema',type=Path);p.add_argument('app_id',type=int);p.add_argument('output',type=Path);a=p.parse_args()
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(export_schema(a.schema,a.app_id),indent=2,ensure_ascii=False),encoding='utf-8')
