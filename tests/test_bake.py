import base64
import hashlib
import json
import random
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from portkit_bake import AtlasPacker, write_blob, emit_package, strip_native, sync_vendor

class BakeTests(unittest.TestCase):
    def test_roundtrip_oversized_atlas(self):
        for width, height in [(1,1),(31,7),(1500,11),(11,1500)]:
            raw = random.Random(width+height).randbytes(width*height*4)
            packer = AtlasPacker(); parts = packer.add(width,height,raw); packer.flush()
            recovered = bytearray(len(raw))
            for part in parts:
                page = packer.pages[part['page']-1]
                self.assertLessEqual(max(page['w'],page['h']),1024)
                for y in range(part['h']):
                    a=((part['y']+y)*page['w']+part['x'])*4
                    b=((part['fy']+y)*width+part['fx'])*4
                    recovered[b:b+part['w']*4]=page['pixels'][a:a+part['w']*4]
            self.assertEqual(raw,recovered)

    def test_chunk_boundary_and_roundtrip(self):
        with tempfile.TemporaryDirectory() as directory:
            out=Path(directory); manifest={}; raw=random.Random(3).randbytes(400000)
            write_blob(out,'Data',raw,manifest)
            sources=[(out/(name+'.luau')).read_text() for name in manifest['Data']['chunks']]
            self.assertTrue(all(len(s)<180000 for s in sources))
            self.assertEqual(zlib.decompress(base64.b64decode(''.join(json.loads(s[7:]) for s in sources))),raw)
            self.assertEqual(manifest['Data']['sha256'],hashlib.sha256(raw).hexdigest())
            with self.assertRaises(ValueError): write_blob(out,'Data',raw,manifest,180000)

    def test_invalid_dimensions(self):
        for size in (0,1025):
            with self.assertRaises(ValueError): AtlasPacker(size)
        with self.assertRaises(ValueError): AtlasPacker().add(2,2,b'bad')

    def test_package_and_vendor(self):
        sdk=Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            destination=Path(directory)
            emit_package(destination/'sdk.rbxmx',sdk/'runtime')
            root=ET.parse(destination/'sdk.rbxmx').getroot().find('Item')
            self.assertEqual(root.attrib['class'],'ModuleScript')
            modules=[i.find('Properties/string').text for i in root.findall('Item')]
            self.assertIn('Stepper',modules)
            self.assertNotIn('SaveServer.server',modules)
            manifest=sync_vendor(sdk,destination/'vendor')
            for path,digest in manifest['files'].items():
                self.assertEqual(hashlib.sha256((destination/'vendor'/path).read_bytes()).hexdigest(),digest)

    def test_strip_native(self):
        self.assertEqual(strip_native('--!native\nreturn 1'),'return 1')

if __name__=='__main__': unittest.main()
