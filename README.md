# PyodideKit

Run real CPython inside an iOS, iPadOS, or Mac app. No server, no network, no
Python interpreter to embed and code-sign.

Python arrives as [Pyodide](https://pyodide.org) — CPython compiled to
WebAssembly — and executes in a hidden `WKWebView`. Everything above that is
Swift. NumPy, pandas, and matplotlib work. So does `pip install`, offline, on a
plane.

```swift
import PyodideKit

let kernel = PyodideKernel()
let result = await kernel.run("import numpy as np; np.arange(6).reshape(2, 3)")

print(result.result ?? "")
// [[0 1 2]
//  [3 4 5]]
```

One kernel is one persistent namespace, like a Jupyter kernel. State carries
across `run` calls until you `restart()`.

---

## Why this exists

Getting Pyodide to run on iOS is easy for about twenty minutes, and then it
isn't. The [standard advice](https://github.com/pyodide/pyodide/discussions/4764)
is "run a local HTTP server, then try to get rid of it." Getting rid of it is
the hard part, and it is only the first of several walls.

This package is the far side of those walls, extracted from
[Lectra](https://www.canvascope.org/products/lectra), a shipping iPad app. The
code is 1,000 lines; the value is in which 1,000.

**The six things that cost real time:**

1. **`file://` cannot work.** WebKit treats every `file://` origin as opaque, so
   Pyodide's own `fetch()` of `pyodide.asm.wasm` fails CORS and the boot dies.
   PyodideKit serves the assets over a registered custom scheme via
   `WKURLSchemeHandler`, which gives the page a real origin. That is what makes
   fully offline execution possible without a local HTTP server.

2. **Bundling Python source gets your app rejected.** App Store validation
   sniffs a bundled file containing Python source as an unsigned executable and
   rejects the upload with **ITMS-90035**. This fails at submission, not at
   build, which is a bad time to discover it. PyodideKit keeps the kernel
   bootstrap as a Swift string literal and injects it with a `WKUserScript` at
   `.atDocumentStart`, so it ships as data.

3. **iOS kills your kernel and never tells you.** The WebContent process is
   reclaimed under memory pressure — routinely while backgrounded. The web view
   stays alive and keeps accepting JavaScript, but the reply never comes and
   your `await` hangs forever. PyodideKit handles
   `webViewWebContentProcessDidTerminate` and arms a per-run inactivity watchdog
   as a backstop.

4. **An on-window web view eats your keyboard.** An attached `WKWebView` puts
   its content view in the responder chain, where it swallows hardware-keyboard
   modifiers from whatever text view the user is actually typing in. The kernel
   view is deliberately never added to a window — it still executes JS and WASM,
   because execution is all we need.

5. **`WKError 5` is not an error.** WebKit reports "JavaScript execution
   returned a result of an unsupported type" whenever a script's completion
   value can't be bridged — including every `async` function, which returns a
   Promise. Treating that as failure silently discards runs that actually
   succeeded.

6. **`pip install` has to survive a relaunch.** micropip resolves a dependency
   closure at install time and reports it via `freeze()`. PyodideKit mirrors
   those wheels to disk and re-installs them from the local filesystem at boot
   with dependency resolution off, so the second launch needs no network.

There is also a seventh, which is just arithmetic: the runtime is ~70 MB with
the scientific stack. PyodideKit supports shipping it as an
[On-Demand Resource](https://developer.apple.com/documentation/foundation/nsbundleresourcerequest)
pack so it stays out of the initial app download.

---

## Where this came from

PyodideKit is not a proof of concept. Every problem it solves was found the
expensive way, in production, building
**[Lectra](https://www.canvascope.org/products/lectra)** — an iPad app for
Pencil notes, PDFs, and Python notebooks, shipping on the
[App Store](https://apps.apple.com/us/app/lectra-notes/id6759754531).

Lectra needed real Python on-device: students run pandas and matplotlib against
their own coursework, on an iPad, often with no connection. Getting there meant
working through the CORS wall, the ITMS-90035 rejection, the kernels that died
silently in the background, and the keyboard that stopped working whenever the
notebook was open. That code ran for real users before it became this package.

I extracted the runtime layer and open sourced it because none of it was the
interesting part of Lectra, and every iOS developer reaching for Pyodide has to
rediscover the same six walls alone. There was no Swift package for this. Now
there is one, and it is MIT — use it in anything, commercial or not.

---

## Install

```swift
.package(url: "https://github.com/NoelSason/PyodideKit.git", from: "0.1.0")
```

Then fetch the runtime. It is not committed to this repo — it is upstream's to
distribute, it is large, and a vendored copy would go stale:

```bash
scripts/fetch-pyodide.sh
```

That stages a `Runtime/` directory. Drag it into Xcode as a **folder reference**
(blue, not yellow) named `Pyodide`, and confirm it landed in *Build Phases →
Copy Bundle Resources*.

To trim the download, pass the packages you actually need:

```bash
scripts/fetch-pyodide.sh --packages "numpy,micropip"
```

---

## Usage

### Running code

`run` never throws. Python errors come back as data, because a failing cell is a
normal outcome, not exceptional control flow:

```swift
let result = await kernel.run("1 / 0")
result.error      // "Traceback (most recent call last): ... ZeroDivisionError"
result.stdout     // ""
```

Results follow Jupyter semantics — a trailing *expression* reports its `repr`, a
trailing *statement* reports nothing:

```swift
await kernel.run("21 * 2").result   // "42"
await kernel.run("x = 42").result   // nil
```

Top-level `await` works:

```swift
await kernel.run("import asyncio; await asyncio.sleep(0.1); 'done'")
```

### Plots

matplotlib is forced to the Agg backend before it can try to draw into a
headless DOM. Figures come back as base64 PNGs:

```swift
let result = await kernel.run("""
import matplotlib.pyplot as plt
plt.plot([1, 4, 9])
""")

if let png = result.images.first, let data = Data(base64Encoded: png) {
    imageView.image = UIImage(data: data)
}
```

### Handing Python a file

```swift
await kernel.writeFile(path: "data.csv", data: csvData)
let result = await kernel.run("import pandas as pd; pd.read_csv('data.csv').describe()")
```

### Installing packages

```swift
let installed = await kernel.install("cowsay")
```

Pure-Python wheels and anything built for Pyodide's WASM target will install.
Packages with C extensions that upstream hasn't built will not, and PyodideKit
translates micropip's message into something a user can read.

Installed wheels are mirrored to disk and reinstalled automatically on the next
boot, with no network.

### `input()`

Python's `input()` is bridged to a callback so you can present whatever UI you
like. Pass `nil` to raise `EOFError` in the running code:

```swift
kernel.promptHandler = { prompt, defaultValue, respond in
    presentTextField(message: prompt) { entered in respond(entered) }
}
```

### Stopping runaway code

Pyodide cannot preempt arbitrary CPython — a `while True:` never yields back to
the JS event loop — so the only dependable stop boundary is discarding the page:

```swift
kernel.cancelExecution()
```

Every in-flight call resolves with `wasCancelled == true`. **Discard those
results rather than displaying them**; they are transport state, not output. The
next `run` boots a fresh kernel automatically. Cancelling the enclosing Swift
`Task` does the same thing.

### On-Demand Resources

```swift
let kernel = PyodideKernel(configuration: PyodideConfiguration(
    assetSource: .onDemandResource(tag: "python-runtime")
))

// Explicit use: download with progress.
try await kernel.start(downloadPolicy: .download)

// Passive warming: start only if the pack is already on device, so opening a
// .py file never triggers a 70 MB download the user didn't ask for.
try await kernel.start(downloadPolicy: .useIfPresent)
```

Observe `kernel.downloadProgress` to show a progress bar.

> Xcode serves ODR packs from a local server while the device is attached to the
> debugger. That server vanishes the moment you unplug, and every Python run
> then fails with a connection error that looks nothing like the actual cause.
> Set **Embed Asset Packs In Product Bundle** for Debug builds.

---

## Configuration

```swift
PyodideConfiguration(
    assetBundle: .main,
    assetSource: .bundled(subdirectory: "Pyodide"),
    scheme: "pyodidekit",          // must be unique to your app
    wheelCacheDirectory: nil,      // defaults to Application Support
    runInactivityTimeout: 180
)
```

Change `scheme` if you register another custom scheme, or if you run more than
one kernel from different asset sets.

---

## Requirements

iOS 16+ · iPadOS 16+ · Mac Catalyst 16+ · macOS 13+ · Swift 5.9+

On macOS there are no On-Demand Resources, so `.onDemandResource` degrades to a
plain bundle lookup.

---

## Performance

No benchmarks are published here yet, because none have been run rigorously
enough to quote. The shape of the cost, though, is worth knowing before you
design around it:

- **Boot dominates everything.** Instantiating the WASM kernel is orders of
  magnitude more expensive than executing code in it, and importing a large
  package like pandas is expensive again on first use.
- **Execution afterwards is cheap.** A warm kernel running small snippets is not
  where your time goes.

The practical consequence: start the kernel before the user needs it, and keep
one alive rather than creating one per execution. `start()` is safe to call
early and repeatedly — concurrent callers share a single boot.

Contributions of real measurements are welcome.

## Limitations

- **No threading, no subprocesses, no sockets.** This is WASM in a browser
  engine. `requests` will not work; use `pyodide.http` or do networking in Swift.
- **Only Pyodide-compatible wheels.** Pure Python always; C extensions only if
  upstream built them for the WASM target.
- **Memory is bounded by the WebContent process.** Large DataFrames will get you
  reclaimed.
- **Not a security sandbox against the host app.** It is a WASM sandbox, which
  is a real boundary for the *Python* code, but treat untrusted input with the
  same care you would anywhere else.

## Testing

```bash
swift test
```

Unit tests run anywhere. The end-to-end kernel tests skip unless the Pyodide
assets are staged into a bundle — run them from an app target to exercise them
for real.

## License

MIT — see [LICENSE](LICENSE).

Pyodide and the Python packages it loads are **not** redistributed here and
carry their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

PyodideKit is an independent wrapper and is not affiliated with the Pyodide
project.
