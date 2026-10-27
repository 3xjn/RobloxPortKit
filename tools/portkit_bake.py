"""Dependency-free RGBA atlas, bounded Luau payload and rbxmx helpers."""
from __future__ import annotations
import base64
import hashlib
import json
import re
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path

MODULE_LIMIT = 180_000

def strip_native(source: str) -> str:
    return re.sub(r'^\s*--!native[^\n]*(?:\n|$)', '', source, flags=re.MULTILINE)

def write_blob(out: Path, key: str, raw: bytes, manifest: dict, chunk_size=170_000):
    if not re.fullmatch(r'[A-Za-z0-9_]+', key):
        raise ValueError('key must be a Luau identifier')
    if not 1 <= chunk_size < MODULE_LIMIT - 12:
        raise ValueError('chunk size exceeds ModuleScript limit')
    out.mkdir(parents=True, exist_ok=True)
    encoded = base64.b64encode(zlib.compress(raw, 9)).decode('ascii')
    names = []
    for i, start in enumerate(range(0, len(encoded), chunk_size)):
        name = f'VFS_{key}_{i:03}'
        source = 'return "' + encoded[start:start+chunk_size] + '"\n'
        assert len(source) < MODULE_LIMIT
        (out / (name + '.luau')).write_text(source, encoding='utf8')
        names.append(name)
    manifest[key] = dict(chunks=names, bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())

class AtlasPacker:
    """Stable shelf packing with one-pixel transparent gutters and oversized tiling."""
    def __init__(self, size=1024, first_page=1):
        if not 3 <= size <= 1024:
            raise ValueError('page size must be 3..1024')
        self.size, self.first_page = size, first_page
        self.pages = []
        self._reset()

    def _reset(self):
        self.canvas = bytearray(self.size * self.size * 4)
        self.x = self.y = self.row = self.usedx = self.usedy = 0

    def flush(self):
        if self.usedy:
            w, h = self.usedx, self.usedy
            pixels = b''.join(self.canvas[j*self.size*4:j*self.size*4+w*4] for j in range(h))
            self.pages.append(dict(w=w, h=h, pixels=pixels))
            self._reset()

    def add(self, width, height, pixels):
        if width < 1 or height < 1 or len(pixels) != width * height * 4:
            raise ValueError('invalid RGBA dimensions')
        parts = []
        step = self.size - 2
        for fy in range(0, height, step):
            for fx in range(0, width, step):
                w, h = min(step, width-fx), min(step, height-fy)
                if self.x + w + 2 > self.size:
                    self.x = 0; self.y += self.row; self.row = 0
                if self.y + h + 2 > self.size:
                    self.flush()
                x, y = self.x + 1, self.y + 1
                for j in range(h):
                    a = ((fy+j)*width+fx)*4; b = ((y+j)*self.size+x)*4
                    self.canvas[b:b+w*4] = pixels[a:a+w*4]
                parts.append(dict(page=self.first_page+len(self.pages), x=x, y=y, w=w, h=h, fx=fx, fy=fy))
                self.x += w+2; self.row = max(self.row, h+2)
                self.usedx = max(self.usedx, self.x); self.usedy = max(self.usedy, self.y+self.row)
        return parts

def item(parent, cls, name, source=None):
    # Referents must be unique even when separate folders contain the same name.
    node = ET.SubElement(parent, 'Item', {'class': cls})
    props = ET.SubElement(node, 'Properties')
    ET.SubElement(props, 'string', name='Name').text = name
    if source is not None:
        if len(source) >= MODULE_LIMIT:
            raise ValueError(f'Module too large: {name}')
        ET.SubElement(props, 'ProtectedString', name='Source').text = source
    return node

def add_runtime(parent, directory: Path, name='RobloxPortKit'):
    root = item(parent, 'ModuleScript', name, (directory/'init.luau').read_text('utf8'))
    for path in sorted(directory.glob('*.luau')):
        if path.name != 'init.luau' and not path.name.endswith(('.server.luau', '.client.luau')):
            item(root, 'ModuleScript', path.stem, path.read_text('utf8'))
    return root

def emit_package(destination: Path, directory: Path):
    root = ET.Element('roblox', version='4')
    add_runtime(root, directory)
    destination.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(root)
    ET.ElementTree(root).write(destination, encoding='utf-8', xml_declaration=True)

def sync_vendor(sdk: Path, destination: Path):
    """Explicit local vendoring; ordinary consumer builds never consult a sibling checkout."""
    files = list((sdk/'runtime').glob('*.luau')) + [sdk/'tools/portkit_bake.py', sdk/'README.md'] + list((sdk/'tests').glob('*.*'))
    manifest = {'format': 1, 'files': {}}
    for source in files:
        rel = source.relative_to(sdk)
        target = destination/rel
        target.parent.mkdir(parents=True, exist_ok=True)
        data = source.read_bytes(); target.write_bytes(data)
        manifest['files'][rel.as_posix()] = hashlib.sha256(data).hexdigest()
    (destination/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf8')
    return manifest
