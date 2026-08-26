//
//  BundledAssetServer.swift
//  PyodideKit
//
//  Serves bundle-shipped files for the kernel's WKURLSchemeHandler.
//
//  Two details that are easy to get wrong and painful to debug:
//
//  1. WebKit delivers scheme-task callbacks on the main thread, and the
//     payloads here are large — the WASM kernel alone is ~10 MB, and the wheels
//     are bigger. Reading them synchronously on main stutters the whole UI on
//     every boot and every import, so the read happens on a background queue
//     and only the reply hops back.
//
//  2. A task WebKit has already stopped must never be spoken to again — doing
//     so raises an Objective-C exception that no Swift `try` can catch, and the
//     app dies. Hence the liveness set: handlers forward their `stop` callback
//     to `markStopped`, and an in-flight read that loses the race drops its
//     reply on the floor.
//

import Foundation
import WebKit

enum BundledAssetServer {
    nonisolated private static let queue = DispatchQueue(
        label: "pyodidekit.bundled-assets", qos: .userInitiated)
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var liveTasks: Set<ObjectIdentifier> = []

    /// Forward the scheme handler's `stop` callback here so an in-flight read
    /// never replies to a task WebKit has abandoned.
    static func markStopped(_ task: WKURLSchemeTask) {
        lock.lock(); defer { lock.unlock() }
        liveTasks.remove(ObjectIdentifier(task))
    }

    /// Reads `fileURL` off the main thread and replies on main with a 200 and
    /// `contentType`. A nil `fileURL` fails the task with `.fileDoesNotExist`.
    static func serve(_ task: WKURLSchemeTask, url: URL, fileURL: URL?, contentType: String) {
        lock.lock()
        liveTasks.insert(ObjectIdentifier(task))
        lock.unlock()

        queue.async {
            let data = fileURL.flatMap { try? Data(contentsOf: $0, options: [.mappedIfSafe]) }
            DispatchQueue.main.async {
                guard consumeIfLive(task) else { return }
                guard let data else {
                    task.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": contentType,
                        "Content-Length": String(data.count),
                        "Access-Control-Allow-Origin": "*",
                    ])!
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    /// Replies immediately with in-memory bytes (no disk read, no queue hop).
    static func serveData(_ task: WKURLSchemeTask, url: URL, data: Data?, contentType: String) {
        guard let data else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": contentType,
                "Content-Length": String(data.count),
                "Access-Control-Allow-Origin": "*",
            ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private static func consumeIfLive(_ task: WKURLSchemeTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return liveTasks.remove(ObjectIdentifier(task)) != nil
    }
}

/// WebKit reports "JavaScript execution returned a result of an unsupported
/// type" (WKError 5) whenever a script's completion value can't be bridged to
/// Objective-C. For fire-and-forget dispatch — where the real answer comes back
/// through a script message — that is not a failure, and treating it as one
/// abandons a command that is still running.
extension NSError {
    var isUnsupportedJavaScriptResult: Bool {
        domain == WKErrorDomain && code == WKError.javaScriptResultTypeIsUnsupported.rawValue
    }
}
