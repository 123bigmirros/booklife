import Foundation

/// Paged reading consumes one rotation burst; scrolling accepts continued motion.
/// Motion while busy/inactive is consumed, never replayed after recovery.
public struct CrownPageInput {
    private var movement = 0.0
    private var consumed = false
    public init() {}

    public mutating func rotate(by delta: Double, enabled: Bool, mode: ReadingMode = .paged) -> PageDirection? {
        guard delta.isFinite else { return nil }
        guard enabled else { movement = 0; consumed = mode == .paged; return nil }
        guard !consumed else { return nil }
        if movement * delta < 0 { movement = 0 }
        movement += delta
        guard abs(movement) >= 0.5 else { return nil }
        let direction: PageDirection = movement > 0 ? .next : .previous
        consumed = mode == .paged
        movement = 0
        return direction
    }

    public mutating func endRotation() { movement = 0; consumed = false }
}

/// Quantized crown distance for text scrolling. One small detent is one text line;
/// a fast input sample is capped so it cannot skip a screen of unread content.
public struct CrownScrollInput {
    private var movement = 0.0
    public init() {}
    public mutating func rotate(by delta: Double, enabled: Bool) -> Int? {
        guard delta.isFinite else { return nil }
        guard enabled else { movement = 0; return nil }
        if movement * delta < 0 { movement = 0 }
        movement += min(1,max(-1,delta))
        let count = min(4,Int(abs(movement)/0.25))
        guard count > 0 else { return nil }
        let sign = movement > 0 ? 1 : -1
        movement -= Double(sign*count)*0.25
        return sign*count
    }
    public mutating func endRotation() { movement = 0 }
}

/// One bounded sample of live motion while an acknowledgement is in flight.
/// This is not a command queue: stale samples, failures and session changes discard it.
public struct LiveScrollMotion {
    private var lines = 0.0
    private var updatedAt = -Double.infinity
    public init() {}
    public mutating func append(_ value: Double, now: Double, maximumLines: Double = 4) {
        guard now.isFinite, value.isFinite, value != 0 else { return }
        let limit = maximumLines.isFinite ? min(16,max(4,maximumLines)) : 4
        let value = min(limit, max(-limit, value))
        if now - updatedAt > 0.18 || now < updatedAt || lines * value < 0 { lines = 0 }
        lines = min(limit, max(-limit, lines + value)); updatedAt = now
    }
    public mutating func take(now: Double) -> Double? {
        defer { reset() }
        guard now.isFinite, now >= updatedAt, now - updatedAt <= 0.18, lines != 0 else { return nil }
        return lines
    }
    public mutating func reset() { lines = 0; updatedAt = -Double.infinity }
}

/// Same gain as legacy crown input (0.25 rotation = one text line), but 16
/// samples per line. Use only when the receiver advertises fractional input.
public struct ContinuousCrownInput {
    private var movement = 0.0
    public init() {}
    public mutating func rotate(by delta: Double, enabled: Bool, maximumLines: Double = 4) -> Double? {
        guard delta.isFinite else { return nil }
        guard enabled else { endRotation(); return nil }
        if movement * delta < 0 { movement = 0 }
        let limit = maximumLines.isFinite ? min(16,max(4,maximumLines)) : 4
        movement += min(limit/4,max(-limit/4,delta))*4
        let units = Int(min(limit,abs(movement))*16)
        guard units > 0 else { return nil }
        let amount = Double(units)/16 * (movement > 0 ? 1 : -1)
        movement -= amount
        return amount
    }
    public mutating func endRotation() { movement = 0 }
}

/// Apply received crown distance immediately, retaining only sub-line remainder.
/// No playback clock: terminal position follows the latest received input.
public struct TerminalScrollMotion {
    public private(set) var pending = 0.0
    private var lastInput = -Double.infinity
    private var direction = 0.0
    public init() {}
    public mutating func append(_ lines: Double, now: Double) {
        guard lines.isFinite, now.isFinite, lines != 0 else { return }
        if now-lastInput > 0.18 || now < lastInput || direction*lines < 0 { reset() }
        pending = min(32,max(-32,pending+min(16,max(-16,lines))))
        lastInput = now
        direction = lines
    }
    public mutating func step(now: Double) -> Int? {
        guard now.isFinite else { return nil }
        if now-lastInput > 0.18 || now < lastInput { reset(); return nil }
        let lines = Int(pending.rounded(.towardZero))
        guard lines != 0 else { return nil }
        pending -= Double(lines)
        return lines
    }
    public mutating func reset() {
        pending = 0; lastInput = -.infinity; direction = 0
    }
}
