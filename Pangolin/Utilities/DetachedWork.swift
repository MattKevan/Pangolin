//
//  DetachedWork.swift
//  Pangolin
//

import Foundation

/// Runs `operation` off the calling actor and still stops it when the caller is cancelled.
///
/// A plain `Task.detached { ... }.value` does not inherit cancellation, so cancelling the
/// caller would leave long file copies and model runs going to completion.
func runDetached<Value: Sendable>(
    priority: TaskPriority? = nil,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let task = Task.detached(priority: priority, operation: operation)
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}
