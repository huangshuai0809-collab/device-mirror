#!/usr/bin/env python3
"""Package a built app and its complete corresponding source from a Git checkout."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def package(app, output):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){2}(?:-[A-Za-z0-9.]+)?', version):
        raise RuntimeError('Unexpected app version')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    architectures = subprocess.check_output(['lipo', '-archs', str(executable)], text=True).split()
    arch = architectures[0] if len(architectures) == 1 else 'universal'
    if arch not in ('arm64', 'x86_64', 'universal'):
        raise RuntimeError('Unexpected app architecture')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)

    tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    sources = []
    for name in filter(None, tracked):
        path = ROOT / name
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(ROOT):
            raise RuntimeError('Unsupported source file: ' + name)
        sources.append((path, name))
    required = {'LICENSE', 'build.py', 'prepare_vendor.py', 'patch_vendor.py', 'DEPENDENCIES.json',
                'src/main.mm', 'scripts/package_release.py'}
    if not required.issubset({name for _, name in sources}):
        raise RuntimeError('Stage or track all project sources before packaging')

    dependencies = json.loads((ROOT / 'DEPENDENCIES.json').read_text())
    for name, record in dependencies.items():
        relative = 'vendor/' + name + '.tar.gz'
        path = ROOT / relative
        if not path.is_file() or digest(path) != record['sha256']:
            raise RuntimeError('Missing or invalid dependency archive: ' + name)
        sources.append((path, relative))

    output.mkdir(parents=True, exist_ok=True)
    app_name = f'DeviceMirror-{version}-macOS-{arch}.zip'
    source_name = f'DeviceMirror-{version}-source.zip'
    with tempfile.TemporaryDirectory(prefix='package-', dir=output) as scratch:
        scratch = Path(scratch)
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent',
                        str(app), str(scratch / app_name)], check=True)
        prefix = f'DeviceMirror-{version}-source/'
        with zipfile.ZipFile(scratch / source_name, 'w', zipfile.ZIP_DEFLATED) as bundle:
            for path, name in sorted(sources, key=lambda item: item[1]):
                bundle.write(path, prefix + name)
        sums = ''.join(f'{digest(scratch / name)}  {name}\n' for name in (app_name, source_name))
        (scratch / 'SHA256SUMS.txt').write_text(sums)
        for name in (app_name, source_name, 'SHA256SUMS.txt'):
            (scratch / name).replace(output / name)
            print(output / name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / 'dist/Device Mirror.app')
    parser.add_argument('--output', type=Path, default=ROOT / 'release')
    options = parser.parse_args()
    package(options.app.resolve(), options.output.resolve())
