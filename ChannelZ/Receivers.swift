//
//  Receptors.swift
//  ChannelZ
//
//  Created by Marc Prud'hommeaux <marc@glimpse.io>
//  License: MIT (or whatever)
//

import Dispatch

/// An `Receipt` is the result of `receive`ing to a Observable or Channel
public protocol Receipt {

    /// Whether the receipt is cancelled or not
    var cancelled: Bool { get }

    /// Disconnects this receptor from the source
    func cancel()
}

// A receipt implementation
public class ReceiptOf: Receipt {
    public var cancelled: Bool { return cancelCounter > 0 }
    private var cancelCounter: Int64 = 0

    let canceler: () -> ()

    public init(canceler: () -> ()) {
        self.canceler = canceler
    }

    /// Creates a Receipt backed by one or more other Receipts
    public init(receipts: [Receipt]) {
        // no receipts means that it is cancelled already
        if receipts.count == 0 { cancelCounter = 1 }
        self.canceler = { for s in receipts { s.cancel() } }
    }

    /// Creates a Receipt backed by another Receipt
    public convenience init(receipt: Receipt) {
        self.init(receipts: [receipt])
    }

    /// Creates an empty cancelled Receipt
    public convenience init() {
        self.init(receipts: [])
    }

    /// Disconnects this receipt from the source observable
    public func cancel() {
        // only cancel the first time
        if OSAtomicIncrement64(&cancelCounter) == 1 {
            canceler()
        }
    }
}

///// A no-op receipt that warns that an attempt was made to receive to a deallocated weak target
//struct DeallocatedTargetReceptor : Receptor {
//    func cancel() { }
//    func request() { }
//}


/// How many levels of re-entrancy are permitted when flowing state observations
public var ChannelZReentrancyLimit: Int = 1

#if DEBUG_CHANNELZ
    /// Global number of times a reentrant invocation was made
    public var ChannelZReentrantReceptions = Int64(0)
#endif

public final class ReceiverList<T> {
    public typealias Receptor = T -> ()
    public let maxdepth: Int
    /// The counter for the current pulse that is in the process of being emitted; this can be used to
    /// distinguish between distinct pulse events
    public internal(set) var pulseCount: Int64 = 0
    private var receivers: [(index: Int64, receptor: Receptor)] = []
    private var entrancy: Int64 = 0
    private var receptorIndex: Int64 = 0
    private let lockQueue = dispatch_queue_create("io.Glimpse.ReceiverList.LockQueue", nil)

    public var count: Int { return receivers.count }

    public init(maxdepth: Int = ChannelZReentrancyLimit) {
        self.maxdepth = maxdepth
    }

    private func synchronized<X>(lockObj: AnyObject, closure: () -> X) -> X {
        var retVal: X?
        dispatch_sync(lockQueue) {
            retVal = closure()
        }
        return retVal!
    }

    public func receive(element: T) {
        let currentEntrancy = OSAtomicIncrement64(&entrancy)
        defer { OSAtomicDecrement64(&entrancy) }
        if currentEntrancy > maxdepth + 1 {
            reentrantChannelReception(element)
        } else {
            OSAtomicIncrement64(&pulseCount)
            for (_, receptor) in receivers {
                receptor(element)
            }
        }
    }

    public func reentrantChannelReception(element: Any) {
        #if DEBUG_CHANNELZ
            print("ChannelZ reentrant channel short-circuit; break on \(#function) to debug", element.dynamicType)
            OSAtomicIncrement64(&ChannelZReentrantReceptions)
        #endif
    }

    /// Adds a receiver that will return a receipt that simply removes itself from the list
    public func addReceipt(receptor: Receptor) -> Receipt {
        let token = addReceiver(receptor)
        return ReceiptOf(canceler: { self.removeReceptor(token) })
    }

    /// Adds a custom receiver block and returns a token that can later be used to remove the receiver
    public func addReceiver(receptor: Receptor) -> Int64 {
        precondition(entrancy == 0, "cannot add to receivers while they are flowing")
        let index = OSAtomicIncrement64(&receptorIndex)
        receivers.append((index, receptor))
        return index
    }

    public func removeReceptor(index: Int64) {
        receivers = receivers.filter { $0.index != index }
    }

    /// Clear all the receivers
    public func clear() {
        receivers = []
    }
}

/// A TrapReceipt is a receptor to a channel that retains a number of values (default 1) when they are sent by the source
public class TrapReceipt<C where C: ChannelType>: Receipt {
    public var cancelled: Bool = false
    public let channel: C

    /// Returns the last value to be added to this trap
    public var value: C.Element? { return values.last }

    /// All the values currently held in the trap
    public var values: [C.Element]

    public let capacity: Int

    private var receipt: Receipt?

    public init(channel: C, capacity: Int) {
        self.channel = channel
        self.values = []
        self.capacity = capacity
        self.values.reserveCapacity(capacity)

        let receipt = channel.receive({ [weak self] (value) -> Void in
            let _ = self?.receive(value)
        })
        self.receipt = receipt
    }

    deinit { receipt?.cancel() }
    public func cancel() { receipt?.cancel() }

    public func receive(value: C.Element) {
        while values.count >= capacity {
            values.removeAtIndex(0)
        }

        values.append(value)
    }
}
