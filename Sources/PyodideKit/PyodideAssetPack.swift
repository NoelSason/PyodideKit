//
//  PyodideAssetPack.swift
//  PyodideKit
//
//  Resolves the runtime assets, and — when they ship as an On-Demand Resource
//  pack — owns the single NSBundleResourceRequest that keeps them mounted.
//
//  The full runtime is ~70 MB with the scientific wheels included. Shipping
//  that in the base app download penalises every user, including the ones who
//  never open anything Python-shaped. As an ODR pack tagged `python-runtime`
//  it is fetched on first use instead, and the request is retained for the
//  process lifetime so several kernels can share one mount.
//

import Foundation

@MainActor
public final class PyodideAssetPack {

    private let bundle: Bundle
    private let source: PyodideAssetSource
    #if os(iOS) || targetEnvironment(macCatalyst)
    private var request: NSBundleResourceRequest?
    #endif
    private var isAvailable = false

    public init(bundle: Bundle, source: PyodideAssetSource) {
        self.bundle = bundle
        self.source = source
    }

    /// Ensures the assets are on device. With `downloadIfNeeded == false` this
    /// only reports whether they are already present and never touches the
    /// network. Returns `true` when the assets resolve through the bundle.
    ///
    /// On platforms without On-Demand Resources (macOS), an `.onDemandResource`
    /// source degrades to a plain bundle lookup.
    @discardableResult
    public func ensureAvailable(
        downloadIfNeeded: Bool,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Bool {
        if isAvailable { return true }

        #if os(iOS) || targetEnvironment(macCatalyst)
        guard case .onDemandResource(let tag) = source else {
            isAvailable = isOnDevice
            return isAvailable
        }

        // The bytes may already be on device, in which case there is nothing to
        // fetch and no reason to touch the network. Check before asking the OS.
        if isOnDevice { isAvailable = true; return true }

        let request = self.request ?? NSBundleResourceRequest(tags: [tag], bundle: bundle)
        self.request = request

        if !downloadIfNeeded {
            let present: Bool = await withCheckedContinuation { continuation in
                request.conditionallyBeginAccessingResources { available in
                    continuation.resume(returning: available)
                }
            }
            if present { isAvailable = true } else { self.request = nil }
            return present
        }

        request.loadingPriority = NSBundleResourceRequestLoadingPriorityUrgent
        onProgress(0)
        let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            onProgress(progress.fractionCompleted)
        }
        defer { observation.invalidate() }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                request.beginAccessingResources { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            self.request = nil   // let a later attempt retry cleanly
            // The fetch failed, but the pack may be on device anyway — an
            // embedded pack, or one the OS already mounted. Only give up if the
            // files genuinely aren't there.
            if isOnDevice { isAvailable = true; onProgress(1); return true }
            throw Self.readableError(error)
        }
        isAvailable = true
        onProgress(1)
        return true
        #else
        isAvailable = isOnDevice
        return isAvailable
        #endif
    }

    /// Whether the assets resolve through the bundle right now.
    ///
    /// True for a build that embeds its asset packs — which Debug builds should
    /// do, so the app keeps working once it is detached from Xcode's local ODR
    /// server. That server disappears the moment you unplug the device, and
    /// without an embedded pack every Python run then fails on a connection
    /// error that looks nothing like the actual cause.
    public var isOnDevice: Bool {
        url(forAsset: "pyodide.js") != nil
    }

    /// Resolves one runtime file, tolerating both a folder reference and a
    /// bundle that flattened the assets into its root.
    func url(forAsset name: String) -> URL? {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        if case .bundled(let subdirectory) = source, let subdirectory {
            if let url = bundle.url(forResource: base, withExtension: ext, subdirectory: subdirectory) {
                return url
            }
        }
        if case .onDemandResource = source {
            if let url = bundle.url(forResource: base, withExtension: ext, subdirectory: "Pyodide") {
                return url
            }
        }
        return bundle.url(forResource: base, withExtension: ext)
    }

    /// An ODR fetch failure surfaces as a URL-loading error whose message is
    /// pure plumbing ("Could not connect to the server."). Callers tend to
    /// splice this straight into a notebook cell or a terminal, so translate it
    /// into something a reader can act on.
    private static func readableError(_ error: Error) -> Error {
        guard (error as NSError).domain == NSURLErrorDomain else { return error }
        return PyodideError.boot(
            "The Python runtime needs a one-time download to finish setting up, and the network isn’t reachable right now. Try again once you’re connected.")
    }
}
