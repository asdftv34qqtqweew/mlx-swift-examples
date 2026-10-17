//
//  StreamingDownloader.swift
//  MLXChatExample
//
//  Plain URLSession downloader for Hugging Face repos: resumable, with a
//  stall watchdog and automatic retries. Replaces #hubDownloader().
//

import Foundation
import MLXLMCommon

private struct DownloadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

nonisolated struct StreamingDownloader: Downloader {

    private struct TreeEntry: Decodable {
        struct LFS: Decodable { let size: Int64? }
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?
        var byteCount: Int64 { lfs?.size ?? size ?? -1 }
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let rev = revision ?? "main"
        let root = URL.applicationSupportDirectory
            .appending(path: "mlx-models")
            .appending(path: id.replacingOccurrences(of: "/", with: "__"))
        let marker = root.appending(path: ".complete")
        if !useLatest, FileManager.default.fileExists(atPath: marker.path) {
            return root
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        guard let listURL = URL(string: "https://huggingface.co/api/models/\(id)/tree/\(rev)?recursive=true") else {
            throw DownloadError(message: "Bad model id: \(id)")
        }
        let (data, response) = try await URLSession.shared.data(from: listURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DownloadError(message: "Could not list files for \(id)")
        }
        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        let files = entries.filter { $0.type == "file" && Self.matches($0.path, patterns) }
        guard !files.isEmpty else {
            throw DownloadError(message: "No matching files in \(id)")
        }

        let total = max(files.reduce(Int64(0)) { $0 + max($1.byteCount, 0) }, 1)
        let progress = Progress(totalUnitCount: total)
        progressHandler(progress)

        var finished: Int64 = 0
        for file in files {
            let destination = root.appending(path: file.path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let expected = file.byteCount
            if expected >= 0, Self.size(of: destination) == expected {
                finished += expected
                progress.completedUnitCount = finished
                progressHandler(progress)
                continue
            }
            let base = finished
            try await Self.fetchFile(
                path: file.path, id: id, revision: rev,
                to: destination, expected: expected
            ) { received in
                progress.completedUnitCount = base + received
                progressHandler(progress)
            }
            finished += max(expected, Self.size(of: destination))
            progress.completedUnitCount = finished
            progressHandler(progress)
        }

        progress.completedUnitCount = progress.totalUnitCount
        progressHandler(progress)
        try? Data().write(to: marker)
        return root
    }

    // MARK: - Helpers

    private static func matches(_ path: String, _ patterns: [String]) -> Bool {
        if patterns.isEmpty { return true }
        return patterns.contains { fnmatch($0, path, 0) == 0 }
    }

    private static func size(of url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func fetchFile(
        path: String,
        id: String,
        revision: String,
        to destination: URL,
        expected: Int64,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        guard let url = URL(string: "https://huggingface.co/\(id)/resolve/\(revision)/\(path)") else {
            throw DownloadError(message: "Bad file path: \(path)")
        }
        let part = destination.appendingPathExtension("part")
        var lastError: Error = DownloadError(message: "Download failed: \(path)")

        for attempt in 1 ... 8 {
            try Task.checkCancellation()

            var have = size(of: part)
            if expected >= 0, have > expected {
                try? FileManager.default.removeItem(at: part)
                have = 0
            }

            if expected < 0 || have < expected {
                var request = URLRequest(url: url)
                request.timeoutInterval = 60
                if have > 0 {
                    request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range")
                }
                let fetcher = Fetcher(partURL: part, resumeFrom: have, onBytes: onProgress)
                do {
                    try await fetcher.run(request: request)
                } catch {
                    lastError = error
                    try await Task.sleep(nanoseconds: UInt64(min(attempt, 5)) * 2_000_000_000)
                    continue
                }
            }

            let got = size(of: part)
            if expected >= 0, got != expected {
                lastError = DownloadError(message: "Size mismatch for \(path): got \(got) of \(expected) bytes")
                if got > expected { try? FileManager.default.removeItem(at: part) }
                continue
            }

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: part, to: destination)
            return
        }
        throw lastError
    }
}

// MARK: - One download attempt, with a stall watchdog

private final class Fetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var _lastActivity = Date()

    // Only touched on the session's serial delegate queue.
    private var handle: FileHandle?
    private var written: Int64
    private var lastReport = Date.distantPast
    private var failure: Error?

    private let partURL: URL
    private let onBytes: @Sendable (Int64) -> Void

    init(partURL: URL, resumeFrom: Int64, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.partURL = partURL
        self.written = resumeFrom
        self.onBytes = onBytes
        super.init()
    }

    var lastActivity: Date {
        lock.lock()
        defer { lock.unlock() }
        return _lastActivity
    }

    private func touch() {
        lock.lock()
        _lastActivity = Date()
        lock.unlock()
    }

    func run(request: URLRequest) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.transfer(request) }
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    if Date().timeIntervalSince(self.lastActivity) > 45 {
                        throw DownloadError(message: "No data received for 45 seconds")
                    }
                }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func transfer(_ request: URLRequest) async throws {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        defer { session.invalidateAndCancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                continuation = c
                lock.unlock()
                touch()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        if let error {
            c?.resume(throwing: error)
        } else {
            c?.resume()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            failure = DownloadError(message: "Invalid server response")
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            failure = DownloadError(message: "Server returned HTTP \(http.statusCode)")
            completionHandler(.cancel)
            return
        }
        do {
            if !FileManager.default.fileExists(atPath: partURL.path) {
                FileManager.default.createFile(atPath: partURL.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: partURL)
            if http.statusCode == 200 {
                try h.truncate(atOffset: 0)
                written = 0
            } else {
                written = Int64(try h.seekToEnd())
            }
            handle = h
            touch()
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        written += Int64(data.count)
        touch()
        let now = Date()
        if now.timeIntervalSince(lastReport) > 0.25 {
            lastReport = now
            onBytes(written)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if error == nil && failure == nil { onBytes(written) }
        finish(failure ?? error)
    }
}
