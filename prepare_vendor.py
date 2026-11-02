#!/usr/bin/env python3
"""Prepare pinned upstream sources from a source bundle, cache, or HTTPS download."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent

def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()

def prepare(download=False, cache_dir=None):
    vendor = ROOT / 'vendor'
    vendor.mkdir(exist_ok=True)
    metadata = json.loads((ROOT / 'DEPENDENCIES.json').read_text())
    for name, record in metadata.items():
        target = vendor / name
        if target.exists():
            print('Already prepared:', name)
            continue
        archive = vendor / (name + '.tar.gz')
        if not archive.exists():
            cached = cache_dir / archive.name if cache_dir else None
            if cached and cached.is_file():
                if digest(cached) != record['sha256']:
                    raise RuntimeError('Cache checksum mismatch: ' + name)
                shutil.copy2(cached, archive)
            elif download:
                url = record['archive_url']
                if not url.startswith('https://codeload.github.com/'):
                    raise RuntimeError('Unexpected archive destination: ' + name)
                partial = archive.with_suffix('.gz.partial')
                try:
                    subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error',
                                    '--retry', '2', '--max-time', '300', url, '-o', str(partial)], check=True)
                    if digest(partial) != record['sha256']:
                        raise RuntimeError('Downloaded archive checksum mismatch: ' + name)
                    partial.replace(archive)
                finally:
                    if partial.exists():
                        partial.unlink()
            else:
                raise RuntimeError('Missing ' + archive.name + '. Run: python3 prepare_vendor.py --download')
        if digest(archive) != record['sha256']:
            raise RuntimeError('Archive checksum mismatch: ' + name)
        with tempfile.TemporaryDirectory(prefix='prepare-' + name + '-', dir=vendor) as scratch:
            scratch = Path(scratch)
            with tarfile.open(archive) as bundle:
                members = bundle.getmembers()
                if not members:
                    raise RuntimeError('Empty archive: ' + name)
                top = Path(members[0].name).parts[0]
                for member in members:
                    path = Path(member.name)
                    if (path.is_absolute() or '..' in path.parts or not path.parts or
                            path.parts[0] != top or not (member.isfile() or member.isdir())):
                        raise RuntimeError('Unsupported archive member: ' + member.name)
                bundle.extractall(scratch)
            (scratch / top).rename(target)
        print('Prepared:', name, record['version'])

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--download', action='store_true', help='Download missing archives from the pinned URLs')
    parser.add_argument('--cache-dir', type=Path, help='Read verified archives from this directory')
    options = parser.parse_args()
    prepare(download=options.download, cache_dir=options.cache_dir)
