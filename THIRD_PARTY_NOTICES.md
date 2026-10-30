# Third-party notices

JS Bay embeds one of the following JavaScript engines in each QuickJS-based
build. Their source is fetched at the pinned revisions recorded below and
patched during the build. The applicable license text for each engine is
included below.

## QuickJS

Source: <https://github.com/bellard/quickjs/tree/e2dc3ebbd874385fbcd48243acad5c8e98c4d451>

```text
QuickJS Javascript Engine

Copyright (c) 2017-2021 Fabrice Bellard
Copyright (c) 2017-2021 Charlie Gordon

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## QuickJS-NG

Source: <https://github.com/quickjs-ng/quickjs/tree/6d46d07d04041b40f4f49eaa7fdebe44c314c699>

```text
The MIT License (MIT)
 
Copyright (c) 2017-2026 Fabrice Bellard
Copyright (c) 2017-2024 Charlie Gordon
Copyright (c) 2023-2026 Ben Noordhuis
Copyright (c) 2023-2026 Saúl Ibarra Corretgé

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Samsung Escargot

Source: <https://github.com/Samsung/escargot>

Used only when building with `-Dbackend=escargot` (experimental spike). Escargot
is primarily LGPL-2.1; some bundled components use other licenses (see
`LICENSE.*` in the Escargot tree). JS Bay does not link Escargot in the default
QuickJS-NG build. Before publishing an Escargot-linked artifact, ship the
LICENSE / NOTICE files from the Escargot revision you vendor and meet LGPL
obligations for that linkage.

## Meta Hermes

Source: <https://github.com/facebook/hermes>

Used only when building with `-Dbackend=hermes` (experimental spike). Hermes is
MIT-licensed; see `vendor/hermes` for NOTICE and third-party licenses.

```text
MIT License

Copyright (c) Meta Platforms, Inc. and affiliates.

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
```

## ICU (International Components for Unicode)

Hermes builds typically link ICU (`icuuc` / `icui18n` / `icudata`). ICU is
Unicode License (Unicode-3.0) / ICU License. Ship the ICU license file from
your ICU prefix when distributing a Hermes-linked artifact. See
<https://unicode-org.github.io/icu/userguide/>.

## Distribution scope

The Android JNI adapter and Apple/Harmony SDK adapters are JS Bay source.
They use platform SDK headers and link platform libraries, but do not copy
third-party source into JS Bay distributions. If a future release adds a
third-party dependency to a shipped artifact, its applicable notices must be
added here before publishing.
