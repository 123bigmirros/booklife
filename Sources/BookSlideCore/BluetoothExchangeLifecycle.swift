import Foundation

/// One wire exchange can outlive its caller's timeout. Keep draining that exchange
/// before sending another, so a late acknowledgement can never acknowledge a new turn.
/// Budgets count foreground execution time, not time spent suspended by watchOS.
public struct BluetoothExchangeLifecycle {
    public enum Timeout: Equatable { case replyDelayed, transportStalled }
    public private(set) var id: UUID?
    public private(set) var callerFinished = false
    private var elapsed: TimeInterval = 0
    private var lastUpdate: TimeInterval = 0
    private var active = true
    public init() {}
    public mutating func begin(id: UUID, now: TimeInterval, active: Bool) -> Bool {
        guard self.id == nil else { return false }
        self.id = id; callerFinished = false; elapsed = 0; lastUpdate = now; self.active = active
        return true
    }
    private mutating func advance(_ now: TimeInterval) {
        if active { elapsed += max(0, now - lastUpdate) }
        lastUpdate = now
    }
    public mutating func setActive(_ value: Bool, now: TimeInterval) {
        advance(now); active = value
    }
    public mutating func nextTimeout(after now: TimeInterval) -> TimeInterval? {
        advance(now)
        guard id != nil, active else { return nil }
        return max(0, (callerFinished ? 15 : 5) - elapsed)
    }
    public mutating func timeout(now: TimeInterval) -> Timeout? {
        advance(now)
        guard id != nil, active else { return nil }
        if !callerFinished, elapsed >= 5 {
            callerFinished = true
            return .replyDelayed
        }
        return elapsed >= 15 ? .transportStalled : nil
    }
    /// Used when leaving the foreground. Do not resume a gesture on next wake.
    @discardableResult public mutating func abandonCaller() -> Bool {
        guard id != nil, !callerFinished else { return false }
        callerFinished = true; return true
    }
    /// A foreign/old response never releases the current exchange.
    @discardableResult public mutating func complete(id: UUID) -> Bool {
        guard self.id == id else { return false }
        self.id = nil; return true
    }
}
