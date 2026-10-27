"""Build the standalone SDK; --test runs Python and Luau regression suites."""
import argparse
import subprocess
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent/'tools'))
from portkit_bake import emit_package
ROOT = Path(__file__).resolve().parent
if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--test', action='store_true'); args = parser.parse_args()
    if args.test:
        subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tests', '-v'], cwd=ROOT, check=True)
        subprocess.run(['lune', 'run', 'tests/runtime.luau'], cwd=ROOT, check=True)
    emit_package(ROOT/'dist/RobloxPortKit.rbxmx', ROOT/'runtime')
