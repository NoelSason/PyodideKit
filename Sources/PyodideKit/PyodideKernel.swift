//
//  PyodideKernel.swift
//  PyodideKit
//
//  Real CPython inside an Apple app, with no server and no network.
//
//  Python ships as Pyodide (CPython compiled to WebAssembly) and executes in a
//  hidden WKWebView; everything above this file stays native. Runtime assets
//  are served over a custom URL scheme rather than `file://`, which is the
//  single detail that makes offline execution possible — see
//  `PyodideConfiguration.scheme`.
//
//  One kernel is one persistent namespace, like a Jupyter kernel: state carries
//  across `run` calls until `restart()` clears it.
//

import Foundation
import Combine
import CoreGraphics
import WebKit
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public final class PyodideKernel: NSObject, ObservableObject {

    public enum Status: Equatable, Sendable {
        case idle
        case starting
        case ready
        case failed(String)
    }

    // MARK: Published state

    @Published public private(set) var status: Status = .idle

    /// Fraction (0…1) of the On-Demand Resource pack downloaded on first use,
    /// or `nil` when no download is in flight. Kept separate from `status` so
    /// the kernel state machine stays unchanged whether or not ODR is in play.
    @Published public private(set) var downloadProgress: Double?

    /// Called when Python's `input()` needs a value. Receives the prompt text, a
    /// default, and a completion to resume execution with. Pass `nil` to raise
    /// `EOFError` in the running code. If unset, `input()` returns the default.
    public var promptHandler: ((String, String?, @escaping (String?) -> Void) -> Void)?

    // MARK: Configuration

    public let configuration: PyodideConfiguration
    public let wheelCache: PyodideWheelCache
    private let assetPack: PyodideAssetPack

    // MARK: Internal state

    private var webView: WKWebView?
    private var startContinuation: CheckedContinuation<Void, Error>?
    /// Callers that hit `start()` while a boot was already in flight; resolved
    /// together with `startContinuation`, so nobody has to poll `status`.
    private var startWaiters: [CheckedContinuation<Void, Error>] = []
    private var runContinuations: [String: CheckedContinuation<PyodideRunResult, Never>] = [:]
    private var installContinuations: [String: CheckedContinuation<InstallRaw, Never>] = [:]
    private var installLocalContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var kernelGeneration = 0

    /// Per-run inactivity watchdogs. A run resolves only when the reply message
    /// arrives; if the WebContent process is suspended and then jetsammed —
    /// exactly what happens when the app spends a while in the background —
    /// that message never comes and the caller would await it forever.
    private var runWatchdogs: [String: Task<Void, Never>] = [:]

    private static let messageHandlerName = "pyodideKernel"
    private var hostPageURL: String { "\(configuration.scheme):///pyodide_host.html" }

    public init(configuration: PyodideConfiguration = PyodideConfiguration()) {
        self.configuration = configuration
        self.wheelCache = PyodideWheelCache(directory: configuration.wheelCacheDirectory)
        self.assetPack = PyodideAssetPack(
            bundle: configuration.assetBundle, source: configuration.assetSource)
        super.init()
    }

    // MARK: - The kernel bootstrap
    //
    // A persistent namespace plus a runner that captures stdout/stderr, the
    // last-expression repr (Jupyter style), and tracebacks. Supports top-level
    // `await` via `eval_code_async`.
    //
    // This lives here as a Swift string rather than inside `pyodide_host.html`
    // for a non-obvious reason: a bundled file containing Python source is
    // sniffed as an executable script by App Store code-signing validation,
    // which rejects the upload with ITMS-90035. Compiled into the binary it
    // ships as data, and `ensureWebView` injects it before any of the page's
    // own script runs.

    private static let runnerPython = """
    import io, os, sys, base64, contextlib, traceback as _tb, builtins as _builtins
    from js import prompt as _pk_js_prompt
    from pyodide.code import eval_code_async

    # Force matplotlib's non-interactive Agg backend before it is ever imported, so
    # figures render to PNG buffers instead of trying to draw into the (headless)
    # DOM. Captured figures are returned to Swift as base64 PNGs, Jupyter-style.
    os.environ.setdefault("MPLBACKEND", "AGG")

    __pk_ns = {"__name__": "__main__"}

    def __pk_input(prompt=""):
        value = _pk_js_prompt(str(prompt), "")
        if value is None:
            raise EOFError("input cancelled")
        return str(value)

    _builtins.input = __pk_input

    def __pk_capture_figs():
        figs = []
        plt = sys.modules.get("matplotlib.pyplot")
        if plt is None:
            return figs
        try:
            for num in plt.get_fignums():
                buf = io.BytesIO()
                plt.figure(num).savefig(buf, format="png", bbox_inches="tight", dpi=110)
                figs.append(base64.b64encode(buf.getvalue()).decode("ascii"))
            plt.close("all")
        except Exception:
            pass
        return figs

    async def __pk_run(code):
        out = io.StringIO()
        err = io.StringIO()
        result_repr = None
        error = None
        images = []
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                val = await eval_code_async(code, globals=__pk_ns)
                if val is not None:
                    result_repr = repr(val)
            except Exception:
                error = _tb.format_exc()
            images = __pk_capture_figs()
        return [out.getvalue(), err.getvalue(), result_repr, error, images]

    def __pk_reset():
        __pk_ns.clear()
        __pk_ns["__name__"] = "__main__"
        _builtins.input = __pk_input
    """

    // MARK: - Lifecycle

    /// Boots the kernel if needed and returns once Python is ready. Safe to call
    /// repeatedly; concurrent callers share a single boot.
    ///
    /// `downloadPolicy` only matters when assets ship as an On-Demand Resource
    /// pack: `.download` fetches it with progress, while `.useIfPresent` starts
    /// only if the pack is already on device. Use the latter for passive warming
    /// so opening a `.py` file never forces a 70 MB download.
    public func start(downloadPolicy: PyodideDownloadPolicy = .download) async throws {
        switch status {
        case .ready: return
        case .starting:
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                startWaiters.append(continuation)
            }
            return
        default: break
        }

        // Claim the boot synchronously so concurrent callers coalesce via the
        // `.starting` path above rather than racing a second kernel.
        status = .starting

        do {
            let available = try await assetPack.ensureAvailable(
                downloadIfNeeded: downloadPolicy == .download,
                onProgress: { [weak self] fraction in
                    Task { @MainActor in self?.downloadProgress = fraction }
                }
            )
            downloadProgress = nil
            guard available else {
                status = .idle
                let error = PyodideError.boot("The Python runtime isn’t downloaded yet.")
                resolveStartWaiters(.failure(error))
                throw error
            }
        } catch {
            downloadProgress = nil
            status = .idle
            resolveStartWaiters(.failure(error))
            throw error
        }

        let webView = ensureWebView()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            guard let url = URL(string: hostPageURL) else {
                let error = PyodideError.boot("Bad host URL")
                continuation.resume(throwing: error)
                startContinuation = nil
                resolveStartWaiters(.failure(error))
                return
            }
            webView.load(URLRequest(url: url))
        }
    }

    /// Resolves everyone who joined an in-flight boot. Call from every site that
    /// resumes `startContinuation`.
    private func resolveStartWaiters(_ result: Result<Void, Error>) {
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    // MARK: - Execution

    /// Runs `code` in the kernel and returns its captured output.
    ///
    /// Never throws — Python errors come back in `PyodideRunResult.error`, so a
    /// failing cell is data rather than control flow. `cellID` correlates the
    /// async reply with its caller and can be any stable string.
    public func run(_ code: String, cellID: String = UUID().uuidString) async -> PyodideRunResult {
        await withTaskCancellationHandler {
            await runWithoutCancellationHandler(code, cellID: cellID)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelExecution() }
        }
    }

    private func runWithoutCancellationHandler(_ code: String, cellID: String) async -> PyodideRunResult {
        let generation = kernelGeneration
        do { try await start() } catch {
            if error is CancellationError || Task.isCancelled || generation != kernelGeneration {
                return Self.cancelledRunResult
            }
            return PyodideRunResult(error: "Python couldn't start: \(error.localizedDescription)")
        }
        guard !Task.isCancelled, generation == kernelGeneration else { return Self.cancelledRunResult }
        guard let webView else { return PyodideRunResult(error: "No kernel.") }

        let executionID = "\(cellID):\(UUID().uuidString)"
        return await withCheckedContinuation { (continuation: CheckedContinuation<PyodideRunResult, Never>) in
            runContinuations[executionID] = continuation
            armRunWatchdog(for: executionID)
            // `pyodideKitRun` is async, so it returns a Promise. End the script
            // with `undefined;` so evaluateJavaScript doesn't try (and fail) to
            // bridge the Promise — the real result arrives via the message
            // handler.
            let js = "window.pyodideKitRun(\(Self.jsString(executionID)), \(Self.jsString(code))); undefined;"
            webView.evaluateJavaScript(js) { [weak self] _, error in
                guard let self, let error else { return }
                // WKError 5 means the script ran and only its return value was
                // unbridgeable — the real result is still on its way through
                // the message handler, so failing here would discard a
                // successful execution.
                if (error as NSError).isUnsupportedJavaScriptResult { return }
                self.cancelRunWatchdog(for: executionID)
                if let pending = self.runContinuations.removeValue(forKey: executionID) {
                    pending.resume(returning: PyodideRunResult(
                        error: "Execution failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    // MARK: - Inactivity watchdog

    private func armRunWatchdog(for executionID: String) {
        runWatchdogs[executionID]?.cancel()
        let timeout = configuration.runInactivityTimeout
        runWatchdogs[executionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.runWatchdogs.removeValue(forKey: executionID)
            if let pending = self.runContinuations.removeValue(forKey: executionID) {
                pending.resume(returning: PyodideRunResult(
                    error: "Python stopped responding (the kernel may have been reclaimed while the app was in the background). Try again."))
            }
        }
    }

    private func cancelRunWatchdog(for executionID: String) {
        runWatchdogs.removeValue(forKey: executionID)?.cancel()
    }

    /// Fails every in-flight request with `reason` and discards the dead kernel.
    private func kernelDidDie(reason: String) {
        let runs = runContinuations
        let installs = installContinuations
        let localInstalls = installLocalContinuations
        runContinuations.removeAll()
        installContinuations.removeAll()
        installLocalContinuations.removeAll()
        for watchdog in runWatchdogs.values { watchdog.cancel() }
        runWatchdogs.removeAll()

        for (_, continuation) in runs {
            continuation.resume(returning: PyodideRunResult(error: reason))
        }
        for (_, continuation) in installs {
            continuation.resume(returning: InstallRaw(freeze: nil, error: reason))
        }
        for (_, continuation) in localInstalls { continuation.resume() }

        startContinuation?.resume(throwing: PyodideError.boot(reason))
        startContinuation = nil
        resolveStartWaiters(.failure(PyodideError.boot(reason)))

        kernelGeneration += 1
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        status = .idle
    }

    // MARK: - Packages and files

    /// Installs `name` from PyPI via micropip, then mirrors the resolved wheels
    /// into the offline cache so later sessions install it without a network.
    /// Never throws — failures come back in `PyodideInstallResult.error`.
    public func install(_ name: String) async -> PyodideInstallResult {
        await withTaskCancellationHandler {
            await installWithoutCancellationHandler(name)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelExecution() }
        }
    }

    private func installWithoutCancellationHandler(_ name: String) async -> PyodideInstallResult {
        let generation = kernelGeneration
        do { try await start() } catch {
            if error is CancellationError || Task.isCancelled || generation != kernelGeneration {
                return PyodideInstallResult(success: false, error: "Execution cancelled.", wasCancelled: true)
            }
            return PyodideInstallResult(
                success: false, error: "Python couldn't start: \(error.localizedDescription)")
        }
        guard !Task.isCancelled, generation == kernelGeneration else {
            return PyodideInstallResult(success: false, error: "Execution cancelled.", wasCancelled: true)
        }
        guard let webView else { return PyodideInstallResult(success: false, error: "No kernel.") }

        let requestID = UUID().uuidString
        let raw: InstallRaw = await withCheckedContinuation { continuation in
            installContinuations[requestID] = continuation
            let js = "window.pyodideKitInstall(\(Self.jsString(requestID)), \(Self.jsString(name))); undefined;"
            webView.evaluateJavaScript(js) { [weak self] _, error in
                guard let self, error != nil else { return }
                if let pending = self.installContinuations.removeValue(forKey: requestID) {
                    pending.resume(returning: InstallRaw(freeze: nil, error: "Execution failed."))
                }
            }
        }

        if raw.wasCancelled || Task.isCancelled || generation != kernelGeneration {
            return PyodideInstallResult(success: false, error: "Execution cancelled.", wasCancelled: true)
        }
        if let error = raw.error {
            return PyodideInstallResult(success: false, error: Self.friendlyInstallError(error, name: name))
        }
        if let freeze = raw.freeze {
            let wheels = PyodideWheelCache.wheelRefs(fromFreeze: freeze)
            await wheelCache.store(topLevel: name, wheels: wheels)
        }
        return PyodideInstallResult(success: true)
    }

    /// Writes raw bytes into the kernel's in-memory filesystem at `path`,
    /// creating parent directories. Use it to hand Python a CSV, a dataset, or
    /// anything else the code should be able to `open()`.
    @discardableResult
    public func writeFile(path: String, base64: String) async -> Bool {
        guard let webView else { return false }
        // `!!` keeps the completion value a plain Bool. Without it an undefined
        // return trips WKError 5 and every staged file silently "fails".
        let js = "!!window.pyodideKitWriteFile(\(Self.jsString(path)), \(Self.jsString(base64)));"
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js) { result, _ in
                continuation.resume(
                    returning: (result as? NSNumber)?.boolValue ?? (result as? Bool) ?? false)
            }
        }
    }

    /// Convenience over `writeFile(path:base64:)`.
    @discardableResult
    public func writeFile(path: String, data: Data) async -> Bool {
        await writeFile(path: path, base64: data.base64EncodedString())
    }

    /// Re-installs every cached wheel from disk into a freshly-booted kernel, so
    /// packages added in a previous session are available with no network.
    private func reinstallCachedPackages() async {
        let paths = await wheelCache.cachedWheelPaths()
        guard !paths.isEmpty, webView != nil else { return }
        var emfsPaths: [String] = []
        for url in paths {
            guard let data = try? Data(contentsOf: url) else { continue }
            let emfs = "/pyodidekit_pkgs/\(url.lastPathComponent)"
            if await writeFile(path: emfs, base64: data.base64EncodedString()) {
                emfsPaths.append(emfs)
            }
        }
        guard !emfsPaths.isEmpty,
              let webView,
              let data = try? JSONEncoder().encode(emfsPaths),
              let json = String(data: data, encoding: .utf8) else { return }

        let requestID = UUID().uuidString
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            installLocalContinuations[requestID] = continuation
            let js = "window.pyodideKitInstallLocal(\(Self.jsString(requestID)), \(Self.jsString(json))); undefined;"
            webView.evaluateJavaScript(js) { [weak self] _, error in
                guard let self, error != nil else { return }
                if let pending = self.installLocalContinuations.removeValue(forKey: requestID) {
                    pending.resume()
                }
            }
        }
    }

    // MARK: - Teardown

    /// Clears the kernel namespace — a lightweight "restart kernel".
    public func restart() {
        webView?.evaluateJavaScript("window.pyodideKitReset && window.pyodideKitReset();")
    }

    /// Interrupts pending Python work by discarding the WASM page.
    ///
    /// Pyodide cannot preempt arbitrary CPython synchronously — a `while True:`
    /// never yields back to the JS event loop — so tearing down the page and
    /// booting a fresh one is the only dependable stop boundary. Every
    /// continuation is resumed before teardown, and callers receive a result
    /// marked `wasCancelled` that must never be written out as real output.
    @discardableResult
    public func cancelExecution() -> Bool {
        guard hasPendingExecution else { return false }
        tearDownKernel(resolvingPendingAsCancelled: true)
        return true
    }

    public var hasPendingExecution: Bool {
        startContinuation != nil
            || !runContinuations.isEmpty
            || !installContinuations.isEmpty
            || !installLocalContinuations.isEmpty
    }

    /// Tears down the kernel and releases its web context. Call this when the
    /// screen that owns the kernel closes, so the WASM runtime is freed.
    public func shutdown() {
        tearDownKernel(resolvingPendingAsCancelled: true)
        promptHandler = nil
    }

    private func tearDownKernel(resolvingPendingAsCancelled: Bool) {
        kernelGeneration += 1
        for watchdog in runWatchdogs.values { watchdog.cancel() }
        runWatchdogs.removeAll()
        if resolvingPendingAsCancelled {
            startContinuation?.resume(throwing: CancellationError())
            startContinuation = nil
            resolveStartWaiters(.failure(CancellationError()))

            let runs = Array(runContinuations.values)
            runContinuations.removeAll()
            for continuation in runs { continuation.resume(returning: Self.cancelledRunResult) }

            let installs = Array(installContinuations.values)
            installContinuations.removeAll()
            for continuation in installs {
                continuation.resume(returning: InstallRaw(
                    freeze: nil, error: "Execution cancelled.", wasCancelled: true))
            }

            let localInstalls = Array(installLocalContinuations.values)
            installLocalContinuations.removeAll()
            for continuation in localInstalls { continuation.resume() }
        }
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.messageHandlerName)
        webView?.stopLoading()
        webView?.uiDelegate = nil
        webView?.navigationDelegate = nil
        webView = nil
        status = .idle
    }

    private static var cancelledRunResult: PyodideRunResult {
        PyodideRunResult(error: "Execution cancelled.", wasCancelled: true)
    }

    // MARK: - WebView construction

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(
            PyodideSchemeHandler(assetPack: assetPack), forURLScheme: configuration.scheme)
        config.userContentController.add(self, name: Self.messageHandlerName)
        // Hand the host page its Python bootstrap at document start, so the
        // global is in place before the page's own script calls init().
        config.userContentController.addUserScript(
            WKUserScript(
                source: "window.PYODIDEKIT_RUNNER_PY = \(Self.jsString(Self.runnerPython));",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))

        // Deliberately NOT added to any window. An attached WKWebView puts its
        // content view in the key window's responder chain, where it swallows
        // hardware-keyboard modifiers (Shift, Command) from whatever text view
        // the user is actually typing in. Off-window it still executes JS and
        // WASM — execution is all we need, not rendering — so it cannot
        // interfere with input.
        let webView = KernelWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        webView.uiDelegate = self
        // iOS reclaims the WebContent process under memory pressure, routinely
        // so while the app is backgrounded. Without this delegate the kernel
        // silently becomes a corpse that accepts JS and never answers.
        webView.navigationDelegate = self
        self.webView = webView
        return webView
    }

    private static func jsString(_ string: String) -> String {
        // Produce a safely-escaped JS string literal via JSON.
        guard let data = try? JSONEncoder().encode(string),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return json
    }

    /// Turns a raw micropip error into a message that explains the on-device
    /// limitation rather than leaking a Python traceback. Pyodide can only
    /// install pure-Python wheels or ones built for its own WASM target, which
    /// is the failure most people hit first.
    private static func friendlyInstallError(_ raw: String, name: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("can't find a pure python")
            || lower.contains("no matching distribution")
            || lower.contains("pure python wheel") {
            return "“\(name)” isn’t available for on-device Python (no compatible wheel)."
        }
        return raw
    }
}

// MARK: - input() bridge

extension PyodideKernel: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        guard let promptHandler else {
            completionHandler(defaultText ?? "")
            return
        }
        promptHandler(prompt, defaultText, completionHandler)
    }
}

// MARK: - Process lifecycle

extension PyodideKernel: WKNavigationDelegate {
    /// The WebContent process died, usually jetsam while backgrounded. Resolve
    /// everything in flight rather than leaving callers awaiting a message that
    /// can never arrive; the next `start()` boots a fresh kernel.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        kernelDidDie(reason: "The Python kernel was reclaimed by the system. Run it again to restart.")
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        kernelDidDie(reason: "Python couldn't load: \(error.localizedDescription)")
    }
}

// MARK: - JS to Swift bridge

extension PyodideKernel: WKScriptMessageHandler {
    public func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        handle(type: type, body: body)
    }

    private func handle(type: String, body: [String: Any]) {
        switch type {
        case "ready":
            // Re-install packages cached from prior sessions before reporting
            // ready, so offline imports just work on the first cell.
            let generation = kernelGeneration
            Task { [weak self] in
                guard let self else { return }
                await self.reinstallCachedPackages()
                guard generation == self.kernelGeneration, self.webView != nil else { return }
                self.status = .ready
                self.startContinuation?.resume()
                self.startContinuation = nil
                self.resolveStartWaiters(.success(()))
            }

        case "installed":
            guard let requestID = body["reqID"] as? String,
                  let continuation = installContinuations.removeValue(forKey: requestID) else { return }
            continuation.resume(returning: InstallRaw(freeze: body["freeze"] as? String, error: nil))

        case "installedLocal":
            if let requestID = body["reqID"] as? String,
               let continuation = installLocalContinuations.removeValue(forKey: requestID) {
                continuation.resume()
            }

        case "installError":
            if let requestID = body["reqID"] as? String {
                if let continuation = installContinuations.removeValue(forKey: requestID) {
                    continuation.resume(returning: InstallRaw(
                        freeze: nil, error: (body["error"] as? String) ?? "Install failed."))
                } else if let continuation = installLocalContinuations.removeValue(forKey: requestID) {
                    continuation.resume()
                }
            }

        case "fatal":
            let message = (body["error"] as? String) ?? "Python failed to start."
            status = .failed(message)
            startContinuation?.resume(throwing: PyodideError.boot(message))
            startContinuation = nil
            resolveStartWaiters(.failure(PyodideError.boot(message)))

        case "result":
            guard let executionID = body["cellID"] as? String else { return }
            cancelRunWatchdog(for: executionID)
            guard let continuation = runContinuations.removeValue(forKey: executionID) else { return }
            continuation.resume(returning: PyodideRunResult(
                stdout: (body["stdout"] as? String) ?? "",
                stderr: (body["stderr"] as? String) ?? "",
                result: body["result"] as? String,
                error: body["error"] as? String,
                images: (body["images"] as? [String]) ?? [],
                svgs: (body["svgs"] as? [String]) ?? []))

        default:
            break
        }
    }
}

// MARK: - Kernel web view

#if canImport(UIKit)
/// A WKWebView that never accepts first-responder status, so it cannot capture
/// hardware-keyboard input even if it does end up in a responder chain.
private final class KernelWebView: WKWebView {
    override var canBecomeFirstResponder: Bool { false }
}
#else
private final class KernelWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
}
#endif

// MARK: - Asset scheme handler

/// Serves the host page and the Pyodide runtime files over the configured
/// scheme, with the MIME types WebKit needs. `application/wasm` in particular
/// is not optional — without it the browser refuses to stream-compile the
/// kernel and the boot fails with an opaque error.
private final class PyodideSchemeHandler: NSObject, WKURLSchemeHandler {

    private let assetPack: PyodideAssetPack

    init(assetPack: PyodideAssetPack) {
        self.assetPack = assetPack
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let name = url.lastPathComponent.isEmpty ? "pyodide_host.html" : url.lastPathComponent

        // The host page belongs to PyodideKit; everything else is a runtime
        // asset the host app supplies.
        let fileURL: URL?
        if name == "pyodide_host.html" {
            fileURL = Bundle.module.url(forResource: "pyodide_host", withExtension: "html")
        } else {
            fileURL = MainActor.assumeIsolated { assetPack.url(forAsset: name) }
        }

        BundledAssetServer.serve(
            task, url: url, fileURL: fileURL, contentType: Self.mimeType(for: name))
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        BundledAssetServer.markStopped(task)
    }

    private static func mimeType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "html": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "wasm": return "application/wasm"
        case "json": return "application/json"
        case "zip": return "application/zip"
        case "whl": return "application/zip"
        case "ttf": return "font/ttf"
        case "data": return "application/octet-stream"
        default: return "application/octet-stream"
        }
    }
}
