import XCTest
@testable import PyodideKit

/// End-to-end tests against a real kernel.
///
/// These need the Pyodide runtime staged into a bundle (see
/// `scripts/fetch-pyodide.sh`), which the SwiftPM test bundle does not carry.
/// They skip rather than fail when the assets are absent, so `swift test` stays
/// green while an app target running the same tests exercises them for real.
@MainActor
final class PyodideKernelIntegrationTests: XCTestCase {

    private func makeKernel() throws -> PyodideKernel {
        let kernel = PyodideKernel()
        let pack = PyodideAssetPack(
            bundle: .main, source: .bundled(subdirectory: "Pyodide"))
        try XCTSkipUnless(pack.isOnDevice, "Pyodide runtime assets not bundled; see scripts/fetch-pyodide.sh")
        return kernel
    }

    func testRunsPython() async throws {
        let kernel = try makeKernel()
        defer { kernel.shutdown() }
        let result = await kernel.run("print(2 + 2)")
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "4")
    }

    /// Jupyter semantics: a trailing expression reports its repr, a trailing
    /// statement reports nothing.
    func testCapturesLastExpressionRepr() async throws {
        let kernel = try makeKernel()
        defer { kernel.shutdown() }
        let expression = await kernel.run("21 * 2")
        XCTAssertEqual(expression.result, "42")
        let statement = await kernel.run("x = 1")
        XCTAssertNil(statement.result)
    }

    func testKernelStatePersistsAcrossRuns() async throws {
        let kernel = try makeKernel()
        defer { kernel.shutdown() }
        _ = await kernel.run("x = 10")
        let result = await kernel.run("print(x * 5)")
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "50")
    }

    func testRestartClearsNamespace() async throws {
        let kernel = try makeKernel()
        defer { kernel.shutdown() }
        _ = await kernel.run("x = 10")
        kernel.restart()
        let result = await kernel.run("print(x)")
        XCTAssertNotNil(result.error, "x should be gone after a restart")
    }

    /// Cancellation must resolve the in-flight run, must not leave anything
    /// that looks like real output, and must leave the kernel usable.
    func testCancellationResolvesCleanlyAndKernelRestarts() async throws {
        let kernel = try makeKernel()
        defer { kernel.shutdown() }
        try await kernel.start()

        let task = Task { await kernel.run("import asyncio\nawait asyncio.sleep(60)") }
        for _ in 0..<100 where !kernel.hasPendingExecution {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(kernel.hasPendingExecution)
        XCTAssertTrue(kernel.cancelExecution())

        let cancelled = await task.value
        XCTAssertTrue(cancelled.wasCancelled)
        XCTAssertTrue(cancelled.stdout.isEmpty)
        XCTAssertTrue(cancelled.stderr.isEmpty)
        XCTAssertNil(cancelled.result)
        XCTAssertTrue(cancelled.images.isEmpty)

        let restarted = await kernel.run("6 * 7")
        XCTAssertFalse(restarted.wasCancelled)
        XCTAssertEqual(restarted.result, "42")
    }

    /// The file-injection bridge: bytes written into the kernel FS must be
    /// readable by pandas.
    func testWriteFileLoadsIntoPandas() async throws {
        let kernel = try makeKernel()
        defer { kernel.shutdown() }
        try await kernel.start()
        let ok = await kernel.writeFile(path: "unit_test.csv", data: Data("a,b\n1,2\n3,4\n".utf8))
        XCTAssertTrue(ok)
        let result = await kernel.run("import pandas as pd; print(pd.read_csv('unit_test.csv').shape)")
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "(2, 2)")
    }

    /// matplotlib figures should come back as base64 PNGs rather than vanishing
    /// into a headless DOM.
    func testCapturesMatplotlibFigure() async throws {
        let kernel = try makeKernel()
        defer { kernel.shutdown() }
        let result = await kernel.run("""
        import matplotlib.pyplot as plt
        plt.plot([1, 2, 3])
        """)
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(result.images.count, 1)
    }

    /// Requires network; skipped rather than failed when offline so the suite
    /// stays green on an air-gapped machine.
    func testInstallsPurePythonPackageFromPyPI() async throws {
        let kernel = try makeKernel()
        defer { kernel.shutdown() }
        let installed = await kernel.install("cowsay")
        if !installed.success, let error = installed.error,
           error.lowercased().contains("network") || error.lowercased().contains("connection") {
            throw XCTSkip("No network for micropip install: \(error)")
        }
        XCTAssertTrue(installed.success, installed.error ?? "")
        let result = await kernel.run("import cowsay; print('ok')")
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
    }
}
