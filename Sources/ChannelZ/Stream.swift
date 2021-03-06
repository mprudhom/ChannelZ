//
//  Stream.swift
//  ChannelZ
//
//  Created by Marc Prud'hommeaux on 4/3/16.
//  Copyright © 2010-2020 glimpse.io. All rights reserved.
//


/// A `StreamType` emits pulses to receivers added via the `receive` function.
///
/// A stream is a push-based analogue to a pull-based `SequenceType`, where a stream's
/// `Pulse` is the equivalent to a sequence's `Element`.
public protocol StreamType {
    associatedtype Pulse

    /// Adds the given receiver block to be executed with the pulses that pass through this stream.
    ///
    /// - Parameter receiver: the block to be executed whenever this Stream pulses an item
    ///
    /// - Returns: A `Receipt`, which can be used to later `cancel` reception
    @discardableResult
    func receive<R: ReceiverType>(_ receiver: R) -> Receipt where R.Pulse == Pulse

    /// Creates a new form of this stream type with the given reception
    func phase(_ reception: @escaping (@escaping (Self.Pulse) -> Void) -> Receipt) -> Self

    /// Adds a stream phase that drops the first `count` pulses.
    ///
    /// Analogous to `CollectionType.dropFirst`
    ///
    /// - Parameter count: the number of pulses to skip before emitting pulses
    ///
    /// - Returns: A stateful Channel that drops the first `count` pulses.
    func dropFirst(_ count: Int) -> Self

    /// Adds a stream phase that will send only the specified number of pulses.
    ///
    /// Analogous to `CollectionType.prefix`
    ///
    /// - Parameter count: the number of pulses to skip before emitting pulses
    ///
    /// - Returns: A stateful Channel that drops the first `count` pulses.
    func prefix(_ count: Int) -> Self
}


/// A `ReceiverType` is simple able to receive pulses of a certain type.
///
/// A receiver is the push-based analogue to a `generator` in pull-based sequences.
///
/// - See also: `AnyReceiver`, `LazyCollection`
public protocol ReceiverType {
    associatedtype Pulse
    func receive(_ value: Pulse)
}

/// A type-erased receiver of `Pulse`.
///
/// This receiver forwards its `receive()` method to an arbitrary underlying
/// receiver having the same `Pulse` type, hiding the specifics of the
/// underlying `ReceiverType`.
public struct AnyReceiver<Pulse> : ReceiverType {
    public let op: (Pulse) -> Void

    @inlinable public init(_ op: @escaping (Pulse) -> Void) {
        self.op = op
    }

    @inlinable public init<R: ReceiverType>(_ receiver: R) where R.Pulse == Pulse {
        self.init(receiver.receive)
    }

    @inlinable public func receive(_ value: Pulse) {
        self.op(value)
    }
}

/// Utilites for creating the special trap receipt (useful for testing)
public extension StreamType {
    /// Adds a receiver that will retain a certain number of values
    @inlinable func trap(_ capacity: Int = 1) -> TrapReceipt<Self> {
        return TrapReceipt(stream: self, capacity: capacity)
    }
}

public extension StreamType {
    /// Adds the given receiver closure to be executed with the pulses that pass through this stream.
    ///
    /// - Parameter receiver: the closure to be executed whenever this Stream pulses an item
    ///
    /// - Returns: A `Receipt`, which can be used to later `cancel` reception
    @discardableResult
    @inlinable func receive(_ receiver: @escaping (Pulse) -> Void) -> Receipt {
        return receive(AnyReceiver(receiver))
    }
}

/// A TrapReceipt is a receptor to a stream that retains a number of values (default 1) when they are sent by the source
public final class TrapReceipt<C>: Receipt where C: StreamType {
    public var isCancelled: Bool = false
    public let stream: C

    /// Returns the last value to be added to this trap
    @inlinable public var value: C.Pulse? { return caught.last }

    /// All the values currently held in the trap
    public var caught: [C.Pulse]

    public let capacity: Int

    @usableFromInline var receipt: Receipt?

    @inlinable public init(stream: C, capacity: Int) {
        self.stream = stream
        self.caught = []
        self.capacity = capacity

        let receipt = stream.receive({ [weak self] (value) -> Void in
            let _ = self?.receive(value)
            })
        self.receipt = receipt
    }

    @inlinable deinit { receipt?.cancel() }
    @inlinable public func cancel() { receipt?.cancel() }

    @inlinable public func receive(_ value: C.Pulse) {
        if caught.count >= capacity {
            caught.removeFirst(caught.count - capacity + 1)
        }
        
        caught.append(value)
    }
}


public extension StreamType {

    /// Lifts a function to the current Stream and returns a new phase that when received to will pass
    /// the values of the current stream through the Operator function.
    ///
    /// - Parameter receptor: The functon that transforms one receiver to another
    ///
    /// - Returns: The new stream
    @inlinable func lifts(_ receptor: @escaping (@escaping (Pulse) -> Void) -> ((Pulse) -> Void)) -> Self {
        return phase { self.receive(receptor($0)) }
    }

    /// Adds a stream phase which only emits those pulses for which a given predicate holds.
    ///
    /// - Parameter predicate: a function that evaluates the pulses emitted by the source stream,
    ///   returning `true` if they pass the filter
    ///
    /// - Returns: A stateless stream that emits only those pulses in the original stream that the filter evaluates as `true`
    @inlinable func filter(_ predicate: @escaping (Pulse) -> Bool) -> Self {
        return lifts { receive in { item in if predicate(item) { receive(item) } } }
    }

    /// Adds a stream phase that drops any pulses that are immediately emitted upon a receiver being added but
    /// passes any pulses that are emitted after the receiver is added.
    /// In ReactiveX parlance, this convert this `observable` stream from `cold` to `hot`
    ///
    /// - Returns: A stream that drops any pulses that are emitted upon a receiver being added
    @inlinable func subsequent() -> Self {
        return phase { receiver in
            var immediate = true
            let receipt = self.receive { item in if !immediate { receiver(item) } }
            immediate = false
            return receipt
        }
    }
}
