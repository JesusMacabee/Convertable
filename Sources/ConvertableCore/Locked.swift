import Foundation

/// A value guarded by a lock, so it can be shared between threads and captured by
/// concurrently-running closures under Swift 6's strict concurrency checking.
/// (`Mutex` from the Synchronization module would do the same, but needs macOS 15.)
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    public init(_ value: Value) { storage = value }

    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&storage)
    }

    public var value: Value {
        get { withLock { $0 } }
        set { withLock { $0 = newValue } }
    }
}
