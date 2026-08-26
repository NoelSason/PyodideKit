//
//  PyodideConfiguration.swift
//  PyodideKit
//
//  Everything host-app-specific about a kernel, in one value. The defaults are
//  what most apps want: assets in `Bundle.main/Pyodide`, wheels cached under
//  Application Support, no On-Demand Resources.
//

import Foundation

/// Where the Pyodide runtime assets (`pyodide.js`, `pyodide.asm.wasm`, the
/// stdlib zip and the bundled wheels) live at runtime.
public enum PyodideAssetSource: Sendable {
    /// Assets ship inside the app bundle. `subdirectory` is the folder-reference
    /// name, or `nil` if they were flattened into the bundle root. Lookup
    /// tolerates both, so `"Pyodide"` is a safe default either way.
    case bundled(subdirectory: String?)

    /// Assets ship as an On-Demand Resource pack with the given tag, so the
    /// ~70 MB of runtime stays out of the initial app download. Only meaningful
    /// on iOS/iPadOS with an App Store or TestFlight build.
    ///
    /// Note that Xcode serves ODR packs from a local server while the device is
    /// attached to the debugger; a Debug build should embed its asset packs so
    /// Python keeps working after you unplug.
    case onDemandResource(tag: String)
}

/// Whether a kernel boot may fetch an On-Demand Resource pack, or should only
/// proceed when the pack is already on device.
public enum PyodideDownloadPolicy: Sendable {
    /// Explicit use — the user asked to run Python. Download if needed.
    case download
    /// Passive warming (e.g. spinning up code intelligence when a `.py` file is
    /// opened). Only proceed if the pack is already present; never trigger a
    /// download the user did not ask for.
    case useIfPresent
}

public struct PyodideConfiguration: Sendable {

    /// Bundle the runtime assets are read from. Defaults to `.main`.
    public var assetBundle: Bundle

    /// How the runtime assets reach the device.
    public var assetSource: PyodideAssetSource

    /// Custom URL scheme the assets are served over.
    ///
    /// This is not cosmetic and it is not optional. Pyodide cannot be loaded
    /// from `file://` inside a `WKWebView` — WebKit treats every `file://`
    /// origin as opaque, so the runtime's own `fetch()` of `pyodide.asm.wasm`
    /// is blocked by CORS and the boot dies. Serving the same bytes over a
    /// registered custom scheme gives the page a real origin, which is what
    /// makes fully offline execution possible without running a local HTTP
    /// server. Pick something unique to your app.
    public var scheme: String

    /// Directory for the offline wheel cache. Defaults to
    /// `Application Support/PyodideKit/wheels`.
    public var wheelCacheDirectory: URL

    /// How long a single `run` may go without a reply before it is failed.
    ///
    /// This exists because iOS reclaims the WebContent process under memory
    /// pressure — routinely so while the app is backgrounded. When that
    /// happens mid-run the reply message never arrives, and a caller awaiting
    /// it would hang forever.
    public var runInactivityTimeout: TimeInterval

    public init(
        assetBundle: Bundle = .main,
        assetSource: PyodideAssetSource = .bundled(subdirectory: "Pyodide"),
        scheme: String = "pyodidekit",
        wheelCacheDirectory: URL? = nil,
        runInactivityTimeout: TimeInterval = 180
    ) {
        self.assetBundle = assetBundle
        self.assetSource = assetSource
        self.scheme = scheme
        self.wheelCacheDirectory = wheelCacheDirectory ?? Self.defaultWheelCacheDirectory()
        self.runInactivityTimeout = runInactivityTimeout
    }

    public static func defaultWheelCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("PyodideKit", isDirectory: true)
            .appendingPathComponent("wheels", isDirectory: true)
    }
}
