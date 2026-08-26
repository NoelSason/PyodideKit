# Third-party notices

PyodideKit itself is MIT licensed (see `LICENSE`). It contains no third-party
code.

What it *loads* at runtime is third-party, and this repository deliberately does
not redistribute any of it. `scripts/fetch-pyodide.sh` downloads the official
Pyodide release directly from upstream, so what lands in your app is upstream's
own build, unmodified.

If you ship an app built with PyodideKit, you are redistributing everything
below and are responsible for its notices. The practical version: each wheel
carries its own license text inside its `.dist-info/` directory, so bundling the
wheels as-is satisfies the attribution requirements for the Python packages.
Pyodide's own MPL-2.0 terms are the part worth reading properly.

## Pyodide

- **Project:** https://github.com/pyodide/pyodide
- **License:** Mozilla Public License 2.0
- **Covers:** `pyodide.js`, `pyodide.asm.js`, `pyodide.asm.wasm`,
  `python_stdlib.zip`, `pyodide-lock.json`

MPL-2.0 is a file-level copyleft. Shipping Pyodide unmodified inside a
proprietary app is explicitly allowed and does not affect the license of your
own code. If you *modify* Pyodide's own files, you must make those modified
files available under MPL-2.0. PyodideKit does not modify them.

CPython itself is under the Python Software Foundation License, and is
redistributed as part of Pyodide.

## micropip

- **Project:** https://github.com/pyodide/micropip
- **License:** Mozilla Public License 2.0

## Default package set

The wheels `scripts/fetch-pyodide.sh` stages by default, and their licenses:

| Package | License |
| --- | --- |
| numpy | BSD 3-Clause |
| pandas | BSD 3-Clause |
| matplotlib | Matplotlib License (BSD-compatible, PSF-derived) |
| matplotlib-pyodide | Mozilla Public License 2.0 |
| pillow | MIT-CMU |
| fonttools | MIT |
| kiwisolver | BSD 3-Clause |
| pyparsing | MIT |
| cycler | BSD 3-Clause |
| packaging | Apache-2.0 / BSD-2-Clause (dual) |
| python-dateutil | Apache-2.0 / BSD-3-Clause (dual) |
| pytz | MIT |
| six | MIT |

Anything installed at runtime via `micropip` carries its own license, which is
not enumerated here — if you let users install arbitrary packages, that
obligation follows the package.

## Not affiliated with Pyodide

PyodideKit is an independent wrapper. It is not endorsed by, affiliated with, or
maintained by the Pyodide project. Please do not file PyodideKit bugs on
Pyodide's tracker.
