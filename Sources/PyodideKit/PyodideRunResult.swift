//
//  PyodideRunResult.swift
//  PyodideKit
//

import Foundation

/// Raw result of executing one chunk of Python.
///
/// Modelled on a Jupyter cell rather than a plain `eval`: `stdout`/`stderr` are
/// captured separately, `result` is the repr of the last expression (and `nil`
/// when the code ends in a statement), and matplotlib figures are drained into
/// `images` instead of being lost to a headless DOM.
public struct PyodideRunResult: Sendable, Equatable {
    /// Everything the code wrote to stdout.
    public var stdout: String
    /// Everything the code wrote to stderr.
    public var stderr: String
    /// `repr()` of the last expression, Jupyter-style. `nil` if the code ended
    /// in a statement or evaluated to `None`.
    public var result: String?
    /// Formatted traceback, if the code raised.
    public var error: String?
    /// Base64-encoded PNGs — matplotlib figures created by this run.
    public var images: [String]
    /// Raw SVG markup, for backends that emit vector output.
    public var svgs: [String]

    /// Transport state only: the run was cancelled rather than completing.
    /// Callers should discard this result rather than persisting it as output.
    public var wasCancelled: Bool

    public init(
        stdout: String = "",
        stderr: String = "",
        result: String? = nil,
        error: String? = nil,
        images: [String] = [],
        svgs: [String] = [],
        wasCancelled: Bool = false
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.result = result
        self.error = error
        self.images = images
        self.svgs = svgs
        self.wasCancelled = wasCancelled
    }
}

/// Outcome of a `micropip` install.
public struct PyodideInstallResult: Sendable, Equatable {
    public var success: Bool
    public var error: String?
    public var wasCancelled: Bool

    public init(success: Bool, error: String? = nil, wasCancelled: Bool = false) {
        self.success = success
        self.error = error
        self.wasCancelled = wasCancelled
    }
}

/// Raw payload from the JS install bridge: micropip's `freeze()` lockfile on
/// success, or an error string.
struct InstallRaw: Sendable {
    var freeze: String?
    var error: String?
    var wasCancelled: Bool = false
}

public enum PyodideError: LocalizedError {
    case boot(String)

    public var errorDescription: String? {
        switch self {
        case .boot(let message): return message
        }
    }
}
