import Foundation
import Network
import SwiftUI

// MARK: - Pending Operation

/// An operation that failed due to lack of connectivity and should be retried
/// automatically when the network returns.
struct PendingOperation: Identifiable {
  let id: UUID
  let label: String
  let createdAt: Date
  let retryBlock: @MainActor @Sendable () async -> Void

  init(
    id: UUID = UUID(), label: String, retryBlock: @MainActor @Sendable @escaping () async -> Void
  ) {
    self.id = id
    self.label = label
    self.createdAt = Date()
    self.retryBlock = retryBlock
  }
}

// MARK: - Network Monitor Service

@MainActor
@Observable
final class NetworkMonitorService: @unchecked Sendable {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "com.wawanote.network-monitor")

  private(set) var isConnected = true
  var wasDisconnected = false
  private(set) var pendingOperations: [PendingOperation] = []
  private var retryInProgress = false

  deinit { monitor.cancel() }

  nonisolated func start() {
    monitor.pathUpdateHandler = { [weak self] path in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let connected = path.status == .satisfied
        if !connected {
          self.wasDisconnected = true
          AppLog.event("network", "Device went offline")
        } else if !self.isConnected, connected {
          AppLog.event(
            "network",
            "Device reconnected — retrying \(self.pendingOperations.count) pending operation(s)")
          self.wasDisconnected = false
          self.drainPendingOperations()
        }
        self.isConnected = connected
      }
    }
    monitor.start(queue: queue)
    Task { @MainActor in
      AppLog.event("network", "NetworkMonitor started — isConnected: \(isConnected)")
    }
  }

  nonisolated func stop() {
    monitor.cancel()
    Task { @MainActor in
      AppLog.event("network", "NetworkMonitor stopped")
    }
  }

  // MARK: - Pending operations

  func enqueuePending(_ op: PendingOperation) {
    pendingOperations.append(op)
    AppLog.debug(
      "network", "Enqueued pending operation: \(op.label) (total: \(pendingOperations.count))")
  }

  func clearPendingOperations() {
    pendingOperations.removeAll()
  }

  private func drainPendingOperations() {
    guard !retryInProgress, !pendingOperations.isEmpty else { return }
    retryInProgress = true

    Task { @MainActor in
      var retried = 0

      for op in pendingOperations {
        guard isConnected else {
          AppLog.debug(
            "network",
            "Connectivity lost during retry drain — stopping (retried: \(retried), remaining: \(pendingOperations.count - retried))"
          )
          break
        }
        await op.retryBlock()
        retried += 1
        try? await Task.sleep(for: .milliseconds(300))
      }

      pendingOperations.removeAll()
      retryInProgress = false
      AppLog.event("network", "Drain complete: \(retried) succeeded")
    }
  }
}

// MARK: - Network Status Banner

/// Renders contextual connectivity banners: offline (red), reconnected (green).
struct NetworkStatusBanner: View {
  let isConnected: Bool
  let wasDisconnected: Bool
  let pendingCount: Int

  var body: some View {
    if !isConnected {
      offlineBanner
        .transition(.move(edge: .top).combined(with: .opacity))
    } else if wasDisconnected {
      reconnectedBanner
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
          }
        }
    }
  }

  private var offlineBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "wifi.slash")
        .font(.caption)
      Text("No internet connection")
        .font(.caption)
        .fontWeight(.medium)
      if pendingCount > 0 {
        Text("· \(pendingCount) pending")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.red, in: Capsule())
    .padding(.horizontal, 16)
  }

  private var reconnectedBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "wifi")
        .font(.caption)
      Text("Back online")
        .font(.caption)
        .fontWeight(.medium)
      if pendingCount > 0 {
        Text("Retrying \(pendingCount) operations…")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.green, in: Capsule())
    .padding(.horizontal, 16)
  }
}
