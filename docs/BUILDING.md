# Building Device Mirror

## Requirements

- A Mac with macOS 14 or later.
- Apple's Command Line Tools (`xcode-select --install`), including clang and the macOS SDK.
- Python 3, Git, make, Perl, and curl. No Homebrew dependencies are required.

The build targets the current Mac's architecture. The downloadable preview is arm64; Intel builds have not been validated.

## Build from a checkout

From the repository root:

```sh
python3 prepare_vendor.py --download
python3 build.py ./dist
open "./dist/Device Mirror.app"
```

The first command downloads the exact upstream archives in `DEPENDENCIES.json`, checks their SHA-256 digests, and extracts them into `vendor/`. The build applies `patch_vendor.py`, builds the protocol libraries, links the native app, and applies an ad hoc signature. It does not notarize the app or use a Developer ID certificate.

To prepare sources from the complete source release without network access, extract that release and run:

```sh
python3 prepare_vendor.py
python3 build.py ./dist
```

You can also reuse verified original archives with `python3 prepare_vendor.py --cache-dir /path/to/archive-cache`.

## Checks

```sh
"./dist/Device Mirror.app/Contents/MacOS/DeviceMirror" --render-test
"./dist/Device Mirror.app/Contents/MacOS/DeviceMirror" --protocol-test
codesign --verify --deep --strict "./dist/Device Mirror.app"
```

The renderer check covers bitmap ownership, padded rows, color conversion, orientation, continuous scrolling frames, and bounded delivery to the main thread. The protocol check runs a local receiver and simulated client to exercise initial PIN pairing, key exchange, reconnection, and rejection of incorrect PINs. It needs permission to open local sockets.

These checks do not replace testing an actual iPad connection and sharing the window in a meeting. For a manual check, connect over AirPlay, scroll a document, rotate the iPad, and share the app window in Zoom. Then repeat with USB. Verify the mute, pin, and reconnect controls, including a narrow window.

## Package a release

From a Git checkout with the intended source files tracked or staged:

```sh
python3 scripts/package_release.py
```

This creates three release assets in `release/`:

- The app ZIP for the built architecture.
- A complete corresponding source ZIP, including the verified, unmodified dependency archives and local patch.
- `SHA256SUMS.txt` for both ZIPs.

Publish the app and complete source ZIP together. GitHub's automatic source ZIP contains the repository only; it does not include the dependency archives. Review `release/NOTES.md` before posting a release.

Generated libraries, extracted dependencies, app bundles, and ZIPs are ignored by Git. The CI workflow builds and uploads artifacts; it does not publish a release automatically.
