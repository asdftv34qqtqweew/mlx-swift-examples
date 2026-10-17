//
//  DownloadBannerView.swift
//  MLXChatExample
//
//  Always-visible model download progress: bytes, percent, speed, ETA,
//  and a warning if no data has arrived for a while.
//  Refreshes on a 1-second timer because Progress is not observable by SwiftUI.
//

import SwiftUI

struct DownloadBannerView: View {
    let progress: Progress

    @State private var now = Date()
    @State private var completed: Int64 = 0
    @State private var total: Int64 = 0
    @State private var speed: Double = 0  // bytes per second, smoothed
    @State private var lastSample = Date()
    @State private var lastChange = Date()
    @State private var started = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private var percent: Int {
        total > 0 ? Int(Double(completed) / Double(total) * 100) : 0
    }

    private var etaText: String? {
        guard speed > 1000, total > completed else { return nil }
        let seconds = Int(Double(total - completed) / speed)
        let minutes = seconds / 60
        return minutes > 0 ? "~\(minutes) min left" : "~\(seconds) sec left"
    }

    private var idleSeconds: Int {
        Int(now.timeIntervalSince(lastChange))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if total > 0 {
                ProgressView(value: Double(completed), total: Double(total))
            } else {
                ProgressView()
            }

            HStack {
                Text("\(bytes(completed)) of \(bytes(total))  (\(percent)%)")
                    .bold()
                Spacer()
                Text(speed > 0 ? "\(bytes(Int64(speed)))/s" : "-")
            }
            .font(.footnote)

            HStack {
                Text("Elapsed \(Int(now.timeIntervalSince(started)))s")
                Spacer()
                if let etaText { Text(etaText) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if idleSeconds >= 20 {
                Text("No new data for \(idleSeconds)s. Still waiting; keep the app open and the screen on.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .onReceive(timer) { date in
            // A parent Progress only advances completedUnitCount when a child
            // (one file) finishes. fractionCompleted includes partial progress.
            let current = Int64(progress.fractionCompleted * Double(max(progress.totalUnitCount, 0)))
            let dt = max(date.timeIntervalSince(lastSample), 0.001)
            if current != completed {
                let instant = Double(current - completed) / dt
                speed = speed == 0 ? instant : (speed * 0.7 + instant * 0.3)
                lastChange = date
            } else if date.timeIntervalSince(lastChange) > 5 {
                speed = 0
            }
            completed = current
            total = progress.totalUnitCount
            lastSample = date
            now = date
        }
    }
}
