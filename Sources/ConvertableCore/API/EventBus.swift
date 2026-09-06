import Foundation

/// Fan-out of `Event`s to any number of live subscribers (SSE connections, the menu bar).
public actor EventBus {
    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]

    public init() {}

    public func subscribe() -> (id: UUID, stream: AsyncStream<Event>) {
        let id = UUID()
        let stream = AsyncStream<Event>(bufferingPolicy: .bufferingNewest(64)) { cont in
            self.subscribers[id] = cont
            cont.onTermination = { _ in Task { await self.unsubscribe(id) } }
        }
        return (id, stream)
    }

    public func unsubscribe(_ id: UUID) {
        subscribers[id]?.finish()
        subscribers[id] = nil
    }

    public func publish(_ event: Event) {
        for c in subscribers.values { c.yield(event) }
    }

    public var subscriberCount: Int { subscribers.count }
}
