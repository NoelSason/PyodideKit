import XCTest
@testable import PyodideKit

/// Unit tests that need no Pyodide assets — they run anywhere, including CI.
final class PyodideKitTests: XCTestCase {

    // MARK: micropip freeze parsing

    /// Only wheels micropip actually fetched over the network should be
    /// mirrored. Bundled packages carry a relative file name and are already on
    /// device, so re-downloading them would be pure waste.
    func testWheelRefsSelectsOnlyNetworkFetchedWheels() {
        let freeze = """
        {"packages": {
          "numpy":  {"file_name": "numpy-1.26.4-cp312-cp312-pyodide_2024_0_wasm32.whl"},
          "cowsay": {"file_name": "https://files.pythonhosted.org/x/cowsay-6.1-py3-none-any.whl"}
        }}
        """
        let refs = PyodideWheelCache.wheelRefs(fromFreeze: freeze)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs.first?.fileName, "cowsay-6.1-py3-none-any.whl")
        XCTAssertEqual(refs.first?.url.host, "files.pythonhosted.org")
    }

    func testWheelRefsToleratesGarbage() {
        XCTAssertTrue(PyodideWheelCache.wheelRefs(fromFreeze: "not json").isEmpty)
        XCTAssertTrue(PyodideWheelCache.wheelRefs(fromFreeze: "{}").isEmpty)
        XCTAssertTrue(PyodideWheelCache.wheelRefs(fromFreeze: #"{"packages":{}}"#).isEmpty)
    }

    // MARK: Wheel cache

    func testWheelCachePersistsManifestAcrossInstances() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = PyodideWheelCache(directory: directory)
        await cache.store(topLevel: "cowsay", wheels: [])
        let names = await cache.names()
        XCTAssertEqual(names, ["cowsay"])

        let reopened = PyodideWheelCache(directory: directory)
        let reopenedNames = await reopened.names()
        XCTAssertEqual(reopenedNames, ["cowsay"], "manifest should survive a relaunch")
    }

    func testWheelCacheRemoveForgetsNameButKeepsWheels() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = PyodideWheelCache(directory: directory)
        await cache.store(topLevel: "cowsay", wheels: [])
        // A shared dependency may still be needed by something else, so the
        // wheel stays on disk even when the name is forgotten.
        try? Data("x".utf8).write(to: directory.appendingPathComponent("dep-1.0-py3-none-any.whl"))
        await cache.remove(name: "cowsay")

        let names = await cache.names()
        let wheels = await cache.cachedWheelPaths()
        XCTAssertTrue(names.isEmpty)
        XCTAssertEqual(wheels.count, 1)
    }

    // MARK: Configuration

    func testDefaultConfigurationUsesCustomSchemeNotFile() {
        // Loading Pyodide from file:// is blocked by WebKit's opaque-origin
        // rules. If this ever defaults back to "file", offline boot breaks.
        let config = PyodideConfiguration()
        XCTAssertFalse(config.scheme.isEmpty)
        XCTAssertNotEqual(config.scheme, "file")
        XCTAssertNotEqual(config.scheme, "http")
        XCTAssertNotEqual(config.scheme, "https")
    }

    func testHostPageResourceIsPresentInModuleBundle() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "pyodide_host", withExtension: "html"),
            "pyodide_host.html must ship as a package resource")
        let html = try String(contentsOf: url, encoding: .utf8)
        // The bootstrap must be injected from Swift, never inlined here:
        // a bundled file containing Python source is rejected by App Store
        // validation as an unsigned code object (ITMS-90035).
        XCTAssertTrue(html.contains("PYODIDEKIT_RUNNER_PY"))
        XCTAssertFalse(html.contains("import io, os, sys"),
                       "Python source must not be inlined in the host page")
    }
}
