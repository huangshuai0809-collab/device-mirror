#!/usr/bin/env python3
"""Build Device Mirror with Apple's command line tools; no package manager required."""
import concurrent.futures
import os
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / 'build'
OUT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'dist'
SDK = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
ARCH = subprocess.check_output(['uname', '-m'], text=True).strip()
FLAGS = ['-O2', '-isysroot', SDK, '-mmacosx-version-min=14.0', '-arch', ARCH]

def run(args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)

def compile_group(name, sources, includes, defines=()):
    folder = BUILD / name
    folder.mkdir(parents=True, exist_ok=True)
    header_time = max((h.stat().st_mtime for p in includes for h in p.rglob('*.h')), default=0)
    signature = hashlib.sha256(repr((FLAGS, includes, defines)).encode()).hexdigest()
    stamp = folder / 'configuration.sha256'
    rebuild = not stamp.exists() or stamp.read_text() != signature
    def compile_one(src):
        obj = folder / (str(src.relative_to(ROOT)).replace('/', '_') + '.o')
        if rebuild or not obj.exists() or obj.stat().st_mtime < max(src.stat().st_mtime, header_time):
            run(['xcrun', 'clang', '-c', *FLAGS, '-std=gnu11',
                 '-Wno-deprecated-declarations', '-Wno-multichar',
                 *['-I' + str(p) for p in includes], *['-D' + d for d in defines], src, '-o', obj])
        return obj
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        objects = list(pool.map(compile_one, sources))
    lib = BUILD / ('lib' + name + '.a')
    if lib.exists(): lib.unlink()
    run(['xcrun', 'ar', 'rcs', lib, *objects])
    stamp.write_text(signature)
    return lib

BUILD.mkdir(exist_ok=True)
run([sys.executable,ROOT / 'patch_vendor.py'])
crypto = ROOT / 'vendor/openssl/libcrypto.a'
if not crypto.exists():
    print('Building OpenSSL…', flush=True)
    target = 'darwin64-arm64-cc' if ARCH == 'arm64' else 'darwin64-x86_64-cc'
    run(['./Configure', target, 'no-shared', 'no-tests', 'no-apps', 'no-docs',
         '-mmacosx-version-min=14.0'], cwd=crypto.parent)
    run(['make', '-j8', 'build_libs'], cwd=crypto.parent)

pl = ROOT / 'vendor/libplist'
plist_sources = sorted((pl / 'src').glob('*.c')) + [pl / 'libcnary/node.c', pl / 'libcnary/node_list.c']
plist = compile_group('plist', plist_sources,
    [pl / 'include', pl / 'src', pl, pl / 'libcnary/include'],
    ['PACKAGE_VERSION="2.8.0"', 'HAVE_STRNDUP=1', 'HAVE_STRPTIME=1', 'HAVE_TIMEGM=1',
     'HAVE_LOCALTIME_R=1', 'HAVE_GMTIME_R=1', 'HAVE_TM_TM_GMTOFF=1', 'HAVE_TM_TM_ZONE=1'])
ux = ROOT / 'vendor/uxplay/lib'
airplay = compile_group('airplay', sorted(ux.glob('*.c')) + sorted((ux / 'playfair').glob('*.c')) +
    sorted((ux / 'llhttp').glob('*.c')),
    [ux, ux / 'playfair', ux / 'llhttp', pl / 'include', ROOT / 'vendor/openssl/include'],
    ['PLIST_210', 'PLIST_230', 'NOHOLD', 'OPENSSL_API_COMPAT=0x10101000L'])

app = OUT / 'Device Mirror.app'
macos = app / 'Contents/MacOS'
resources = app / 'Contents/Resources'
macos.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
print('Building native app…', flush=True)
run(['xcrun', 'clang++', *FLAGS, '-std=c++17', '-fobjc-arc', '-fblocks',
     '-Wno-deprecated-declarations', '-Wno-multichar', '-I' + str(ux),
     '-I' + str(ROOT / 'vendor/openssl/include'),
     ROOT / 'src/main.mm', airplay, plist, crypto,
     '-framework', 'Cocoa', '-framework', 'AVFoundation', '-framework', 'CoreMedia',
     '-framework', 'CoreMediaIO', '-framework', 'VideoToolbox', '-framework', 'AudioToolbox',
     '-framework', 'QuartzCore', '-framework', 'Accelerate', '-o', macos / 'DeviceMirror'])
info = {
    'CFBundleExecutable': 'DeviceMirror', 'CFBundleIdentifier': 'local.devicemirror.mac',
    'CFBundleName': 'Device Mirror', 'CFBundleDisplayName': 'Device Mirror',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.1.4',
    'CFBundleVersion': '5', 'LSMinimumSystemVersion': '14.0',
    'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication',
    'NSCameraUsageDescription': '通过 USB 数据线读取你选择的 iPad 屏幕画面，用于在 Mac 窗口中显示。',
    'NSLocalNetworkUsageDescription': '在同一局域网中接收 iPad 的 AirPlay 屏幕镜像。',
    'NSBonjourServices': ['_airplay._tcp', '_raop._tcp'],
    'CFBundleIconFile': 'AppIcon',
    'NSHumanReadableCopyright': 'Device Mirror contributors. GPL-3.0-or-later. Includes UxPlay.',
}
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump(info, f)
for src, dst in [(ROOT / 'vendor/uxplay/LICENSE', 'UxPlay-GPL-3.0.txt'),
                 (pl / 'COPYING', 'libplist-LGPL-2.1.txt'),
                 (ROOT / 'vendor/openssl/LICENSE.txt', 'OpenSSL-Apache-2.0.txt'),
                 (ux / 'llhttp/LICENSE-MIT', 'llhttp-MIT.txt'),
                 (ROOT / 'THIRD-PARTY.md', 'THIRD-PARTY.md')]:
    if src.exists(): shutil.copy2(src, resources / dst)
icon = ROOT / 'assets/AppIcon.icns'
if icon.exists(): shutil.copy2(icon, resources / 'AppIcon.icns')
run(['codesign', '--force', '--sign', '-', app])
print(app)
