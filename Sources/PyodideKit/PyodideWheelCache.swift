//
//  PyodideWheelCache.swift
//  PyodideKit
//
//  Offline cache of Python wheels installed at runtime via micropip.
//
//  The kernel ships a fixed wheel set. When code installs something extra from
//  PyPI, micropip resolves the whole dependency closure and reports each
//  wheel's URL through `freeze()`. Mirroring those wheels to disk is what makes
//  the second launch work on a plane: the kernel re-installs them from the
//  local filesystem at boot, with dependency resolution switched off because
//  the closure is already on disk.
//

import Foundation

/// One wheel resolved by micropip: its filename and the URL it came from.
public struct WheelRef: Equatable, Sendable {
    public let fileName: String
    public let url: URL

    public init(fileName: String, url: URL) {
        self.fileName = fileName
        self.url = url
    }
}

public actor PyodideWheelCache {

    private let fileManager = FileManager.default
    private let directory: URL
    private let manifestURL: URL

    /// Top-level package names explicitly installed (not their transitive
    /// dependencies), so a UI can list what the user actually asked for.
    public private(set) var installedNames: Set<String> = []

    public init(directory: URL) {
        self.directory = directory
        self.manifestURL = directory.appendingPathComponent("manifest.json")
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: manifestURL),
           let names = try? JSONDecoder().decode([String].self, from: data) {
            installedNames = Set(names)
        }
    }

    // MARK: Query

    /// Local paths of every cached wheel, for offline re-install at kernel boot.
    public func cachedWheelPaths() -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "whl" }
    }

    public func isEmpty() -> Bool { cachedWheelPaths().isEmpty }

    public func names() -> [String] { installedNames.sorted() }

    // MARK: Mutation

    /// Downloads the given wheels into the cache (skipping ones already
    /// present) and records `topLevel` as explicitly installed. Returns the
    /// number of new wheels written.
    ///
    /// Network errors are tolerated per wheel: a failed mirror only means that
    /// package won't be available offline next launch, and it still installed
    /// successfully in the current session. Failing the whole install here
    /// would be a worse trade.
    @discardableResult
    public func store(topLevel: String, wheels: [WheelRef]) async -> Int {
        var added = 0
        for wheel in wheels {
            let destination = directory.appendingPathComponent(wheel.fileName)
            if fileManager.fileExists(atPath: destination.path) { continue }
            do {
                let (tmp, _) = try await URLSession.shared.download(from: wheel.url)
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: tmp, to: destination)
                added += 1
            } catch {
                continue
            }
        }
        installedNames.insert(topLevel)
        persistManifest()
        return added
    }

    /// Removes an explicitly-installed package from the manifest. The wheels
    /// stay on disk, because dependencies may be shared with something else
    /// that is still installed.
    public func remove(name: String) {
        installedNames.remove(name)
        persistManifest()
    }

    /// Deletes every cached wheel and forgets the manifest.
    public func removeAll() {
        for url in cachedWheelPaths() { try? fileManager.removeItem(at: url) }
        installedNames.removeAll()
        persistManifest()
    }

    private func persistManifest() {
        let data = try? JSONEncoder().encode(installedNames.sorted())
        try? data?.write(to: manifestURL, options: .atomic)
    }

    // MARK: micropip freeze parsing

    /// Extracts the network-fetched wheels from micropip's `freeze()` lockfile.
    ///
    /// Packages that shipped in the bundle carry a relative file name, while
    /// anything micropip pulled from PyPI carries an absolute URL — so
    /// filtering on an `http` prefix naturally selects exactly the wheels worth
    /// mirroring, and skips the ones already on disk.
    public static func wheelRefs(fromFreeze json: String) -> [WheelRef] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packages = root["packages"] as? [String: Any] else { return [] }
        var refs: [WheelRef] = []
        for (_, value) in packages {
            guard let package = value as? [String: Any],
                  let fileName = package["file_name"] as? String,
                  fileName.hasPrefix("http"),
                  let url = URL(string: fileName) else { continue }
            refs.append(WheelRef(fileName: url.lastPathComponent, url: url))
        }
        return refs
    }
}
