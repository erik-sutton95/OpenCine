# Third-party notices

OpenCine is licensed under the [Apache License 2.0](LICENSE). It distributes the following
third-party resources, reproduced here with their required license texts. UI resources (Sora,
Lucide, View Assist glyphs) come first, then the Insta360 integration's C code and references.

## Sora

- **Homepage:** <https://github.com/sora-xor/sora-font>
- **Used for:** shared native iOS and Android UI type
- **License:** SIL Open Font License 1.1 (full text in `Sources/MonitorUI/Resources/Fonts/OFL-Sora.txt`)
- **Copyright:** 2019 The Sora Project Authors

## Lucide HUD icons

- **Homepage:** <https://github.com/lucide-icons/lucide>
- **Used for:** HUD and chrome glyphs on iOS and Android (`MonitorIcon` in SwiftUI and Compose).
  Vendored SVGs live in
  `Sources/MonitorUI/Resources/Icons/lucide/` and
  `Android/monitor-ui/src/main/assets/icons/lucide/`; Android also ships VectorDrawables under
  `Android/monitor-ui/src/main/res/drawable/opc_lucide_*.xml`.
- **License:** ISC (full text in those `LICENSE.txt` files). Some glyphs in this set are derived
  from [Feather](https://github.com/feathericons/feather) and are additionally MIT
  (`aperture`, `check`, `chevron-down`, `chevron-left`, `chevron-right`, `chevron-up`, `circle`,
  `circle-plus`, `crosshair`, `download`, `ellipsis`, `info`, `lock`, `maximize`, `minimize`,
  `plus`, `radio`, `share`, `smartphone`, `square`, `trash`, `upload`, `x`, `zoom-in`).
- **Copyright:** 2026 Lucide Icons and Contributors. Feather-derived icons: Copyright 2013-present
  Cole Bemis.

ISC License

Copyright (c) 2026 Lucide Icons and Contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

The MIT License (MIT) (Feather-derived icons listed above)

Copyright (c) 2013-present Cole Bemis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Field Monitor View Assist icons

- **Used for:** the exact 14 tool glyphs extracted from the approved Field Monitor
  design, including Tabler-derived path artwork.
- **Homepage:** <https://github.com/tabler/tabler-icons>
- **License:** MIT. The full license accompanies the SVGs in
  `Sources/MonitorUI/Resources/Icons/assist/LICENSE-Tabler.txt` and
  `Android/monitor-ui/src/main/assets/icons/assist/LICENSE-Tabler.txt`.
- **Copyright:** 2020-2026 Paweł Kuna.

## KCP (ikcp)

`Sources/CKcp/ikcp.c` and `Sources/CKcp/ikcp.h` are KCP by Lin Wei (skywind3000),
<https://github.com/skywind3000/kcp>, under the MIT License reproduced in full in
`Sources/CKcp/LICENSE` (Copyright (c) 2017 Lin Wei). `luna_kcp.c` and `luna_ifaddr.c` are this
project's own thin shims (Apache 2.0).

## Luna protocol references

The Luna bootstrap/framing research used `diamondfsd/luna-ai-cut`, inspected at
`ad47c16929b1b086c0a369fc2b4b5ece5b63f4df`, as an MIT-licensed implementation reference.
The project independently exercised its own authorization identity and verified camera
commands on local hardware. Source links, other references, license distinctions and
measurement provenance are recorded in
OpenInstaCine `docs/research/insta360-protocol-sources.md`.
No official Insta360 SDK or proprietary protocol document is bundled.

MIT License

Copyright (c) 2026 diamondfsd

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
