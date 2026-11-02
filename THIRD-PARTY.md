# Device Mirror 0.1.4

Device Mirror's original application code is licensed under GPL-3.0-or-later.
The complete corresponding source is provided alongside the app.

Bundled components:

- UxPlay v1.73.7, commit df67c212a433cf6dda3676dd40c097900d24e645.
  https://github.com/FDH2/UxPlay
  GPL-3.0-or-later, with individual LGPL files and MIT-licensed llhttp.
  Only its protocol library is used. GStreamer and upstream renderers are not included in the executable.
- libplist 2.8.0. https://github.com/libimobiledevice/libplist
  LGPL-2.1-or-later; see vendor/libplist/COPYING and source notices.
- OpenSSL 3.6.5, commit c8bd5a57108599ac650bbae77fcabe3109dab2e8.
  https://github.com/openssl/openssl
  Apache-2.0; see vendor/openssl/LICENSE.txt and source notices.

Original upstream archives are supplied unmodified. Before building, patch_vendor.py
applies local changes to UxPlay's lib/pairing.h, lib/pairing.c and lib/raop_handlers.h:
correct the legacy SRP-SHA1 proof length from 64 to 20 bytes, add pairing payload/state
checks, and emit fixed pairing-stage messages. Modified files carry dated notices;
the corresponding unified diff is included under patches/.

Device Mirror also adds an AppKit user interface, native Apple video and audio rendering,
USB capture through AVFoundation, and sanitized connection diagnostics. Version 0.1.3
uses Accelerate's vImage CPU conversion and ordinary Core Graphics/AppKit drawing
for window capture compatibility, with owned bitmap storage and bounded frame delivery.
