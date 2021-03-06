//
//  Optics.swift
//  ChannelZ
//
//  Created by Marc Prud'hommeaux on 7/5/16.
//  Copyright © 2010-2020 glimpse.io. All rights reserved.
//

// MARK: Lens Support


/// A van Laarhoven Lens type
public protocol LensType {
    associatedtype Root
    associatedtype Value

    func set(_ target: inout Root, _ value: Value)
    func get(_ target: Root) -> Value
}

public extension LensType {
    /// Converts this lens to an optional prism that allows lossy getting/setting of optional values
    ///
    /// - See Also: `ChannelType.prism`
    @inlinable var prism : Lens<Root?, Value?> {
        return Lens<Root?, Value?>(get: { $0.flatMap(self.get) }, set: { (whole, part) in
            if var wholeActual = whole, let part = part {
                self.set(&wholeActual, part)
                whole = wholeActual
            }
        })
    }

    /// Maps this lens to a new lens with the given pair of recripocal functions.
    @inlinable func map<X>(_ getmap: @escaping (Value) -> X, _ setmap: @escaping (X) -> Value) -> Lens<Root, X> {
        return Lens(get: { getmap(self.get($0)) }, set: {
            self.set(&$0, setmap($1))
        })
    }
}

public extension LensType where Value : _OptionalType {

    /// Maps this lens to a new lens with the given pair of reciprocal functions that operate on optional types.
    @inlinable func flatMap<X>(_ getmap: @escaping (Value.Wrapped) -> X, _ setmap: @escaping (X) -> Value.Wrapped) -> Lens<Root, X?> {
        return Lens(get: { a in self.get(a).flatMap(getmap) }, set: { a, c in self.set(&a, c.flatMap(setmap).map(Value.init) ?? nil) })
    }
}

/// A lens provides the ability to access and modify a sub-element of an immutable data structure.
/// Optics composition in Swift is somewhat limited due to the lack of Higher Kinded Types, but
/// they can be used to great effect with a state channel in order to provide owner access and
/// conditional creation for complex immutable state structures.
///
/// See Also: https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md#higher-kinded-types
public struct Lens<Root, Value> : LensType {
    @usableFromInline let getter: (Root) -> Value
    @usableFromInline let setter: (inout Root, Value) -> ()

    @inlinable public init(get: @escaping (Root) -> Value, set: @escaping (inout Root, Value) -> ()) {
        self.getter = get
        self.setter = set
    }

    @inlinable public func set(_ target: inout Root, _ value: Value) {
        return setter(&target, value)
    }

    @inlinable public func get(_ target: Root) -> Value {
        return getter(target)
    }
}

/// A `WritableKeyPath` is fundamentally a `Lens`
extension WritableKeyPath : LensType {
    @inlinable public func get(_ target: Root) -> Value {
        return target[keyPath: self]
    }

    @inlinable public func set(_ target: inout Root, _ value: Value) {
        target[keyPath: self] = value
    }
}

public extension Lens {
    /// Constructs a `Lens` from a `WritableKeyPath`
    @inlinable init(kp: WritableKeyPath<Root, Value>) {
        self.getter = { $0[keyPath: kp] }
        self.setter = { $0[keyPath: kp] = $1 }
    }
}

public protocol LensSourceType : TransceiverType {
    associatedtype Owner : ChannelType

    /// All lens channels have an owner that is itself a TransceiverType
    var channel: Owner { get }
}

/// A Lens on a state channel, which can be used create a property channel on a specific
/// piece of the source state; a LensSource itself does not manage any receivers, but instead
/// relies on the source of the underlying channel.
///
/// The associated lens is used both for getting/setting the source state directly as well
/// as modifying the old/new state pulse values. A lens can be thought of as a 2-way `map` for state values.
public struct LensSource<C: ChannelType, T>: LensSourceType where C.Source : TransceiverType, C.Pulse : MutationType, C.Pulse.RawValue == C.Source.RawValue {
    public typealias Owner = C
    public let channel: C
    public let lens: Lens<C.Source.RawValue, T>

    @usableFromInline init(channel: C, lens: Lens<C.Source.RawValue, T>) {
        self.channel = channel
        self.lens = lens
    }

    @inlinable public func receive(_ x: T) {
        self.rawValue = x
    }

    @inlinable public var rawValue: T {
        get { return lens.get(channel.rawValue) }
        nonmutating set { lens.set(&channel.rawValue, newValue) }
    }

    /// Creates a state tranceiver to the focus of this lens, allowing the access and modification
    /// of a subset of a product type.
    @inlinable public func transceive() -> LensChannel<C, T> {
        return channel.map({ pulse in
            Mutation(old: pulse.old.flatMap(self.lens.get), new: self.lens.get(pulse.new))
        }).resource({ _ in self })
    }
}

/// A `LensChannel` simplifies the type of a channel over a mutating LensSource
public typealias LensChannel<C: ChannelType, X> = Channel<LensSource<C, X>, Mutation<X>> where C.Source : TransceiverType, C.Pulse : MutationType, C.Pulse.RawValue == C.Source.RawValue

public extension ChannelType where Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {
    /// A channel that focused from the current channel through to the given pulse type
    typealias FocusChannel<X> = LensChannel<Self, X>
}

/// A Prism on a state channel, which can be used create a property channel on a specific
/// piece of the source state; a LensSource itself does not manage any receivers, but instead
/// relies on the source of the underlying channel.
public struct PrismSource<C: ChannelType, T>: LensSourceType where C.Source : TransceiverType, C.Pulse : MutationType, C.Pulse.RawValue == C.Source.RawValue {
    public typealias Owner = C
    public let channel: C
    public let lens: Lens<C.Source.RawValue, T>
    public typealias Pulse = T

    @inlinable public func receive(_ x: T) {
        self.rawValue = x
    }

    @inlinable public var rawValue: T {
        get { return lens.get(channel.rawValue) }
        nonmutating set { lens.set(&channel.rawValue, newValue) }
    }

    /// Creates a state tranceiver to the focus of this lens, allowing the access and modification
    /// of a subset of a product type.
    @inlinable public func transceive() -> Channel<PrismSource, Mutation<T>> {
        return channel.map({ pulse in
            Mutation(old: pulse.old.flatMap(self.lens.get), new: self.lens.get(pulse.new))
        }).resource({ _ in self })
    }
}

public extension ChannelType where Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {

    /// A pure channel (whose element is the same as the source) can be lensed such that a derivative
    /// channel can modify sub-elements of a complex data structure
    @inlinable func focus<X>(lens: Lens<Pulse.RawValue, X>) -> FocusChannel<X> {
        return LensSource(channel: self, lens: lens).transceive()
    }

    /// Constructs a Lens channel using the given `WritableKeyPath` that is used as the getter/setter
    @inlinable func focus<X>(_ kp: WritableKeyPath<Pulse.RawValue, X>) -> FocusChannel<X> {
        return focus(lens: Lens(kp: kp))
    }

    /// Constructs a Lens channel using a getter and an inout setter
    @inlinable func focus<X>(get: @escaping (Pulse.RawValue) -> X, set: @escaping (inout Pulse.RawValue, X) -> ()) -> FocusChannel<X> {
        return focus(lens: Lens(get: get, set: set))
    }
}

public extension ChannelType where Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {

    /// Creates an optionally casting prism focus
    @inlinable func cast<T>(_ type: T.Type) -> FocusChannel<T?> {
        let optionalLens = Lens<Pulse.RawValue, T?>(get: { $0 as? T }, set: { (x: inout Pulse.RawValue, y: T?) in
            if let z = y as? Pulse.RawValue {
                x = z
            }
        })
        return focus(lens: optionalLens)
    }

}

public extension ChannelType where Source : LensSourceType {
    /// Simple alias for `source.channel.source`; useful for ascending a lens ownership hierarchy
    @inlinable var owner: Source.Owner { return source.channel }
}

// MARK: Jacket Channel extensions for Lens/Prism/Optional access

public extension ChannelType where Source.RawValue : _WrapperType, Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {

    /// Converts an optional state channel into a non-optional one by replacing nil elements
    /// with the result of the constructor function
    @inlinable func coalesce(_ template: @escaping (Self) -> Pulse.RawValue.Wrapped) -> FocusChannel<Pulse.RawValue.Wrapped> {
        return focus(get: { $0.flatMap({ $0 }) ?? template(self) }, set: { $0 = Source.RawValue($1) })
    }

    /// Converts an optional state channel into a non-optional one by replacing nil elements
    /// with the constant of the value; alias for `coalesce`
    @inlinable func coalesce(_ value: Pulse.RawValue.Wrapped) -> FocusChannel<Pulse.RawValue.Wrapped> {
        return coalesce({ _ in value })
    }
}

public extension ChannelType where Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {

    /// Given two channels that can find and update values based on the specified getters & updaters, create
    /// a `Transceiver` channel that provides access to the underlying merged elements.
    @inlinable func join<T, Join: ChannelType>(_ locator: Join, finder: @escaping (Self.Pulse.RawValue, Join.Pulse.RawValue) -> T, updater: @escaping ((Self.Pulse.RawValue, Join.Pulse.RawValue), T) -> (Self.Pulse.RawValue, Join.Pulse.RawValue)) -> FocusChannel<T> where Join.Source : StateEmitterType, Join.Pulse : MutationType, Join.Pulse.RawValue == Join.Source.RawValue {

        // the selection lens value is a prism over the current selection and the current elements
        let lens = Lens<Pulse.RawValue, T>(get: { elements in
            finder(elements, locator.source.rawValue)
        }, set: { (elements, values) in
            elements = updater((elements, locator.source.rawValue), values).0
        })

        let sel = focus(lens: lens)

        return sel.either(locator).resource({ $0.0 }).map {
            switch $0 {
            case .v1(let v): // change in elements
                return v // the raw values are already resolved by the lens
            case .v2(let i): // change in locator; need to perform another lookup
                return Mutation(old: i.old.flatMap({ finder(self.source.rawValue, $0) }), new: finder(self.source.rawValue, i.new))
            }
        }
    }
}

public extension ChannelType where Source.RawValue : RangeReplaceableCollection, Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {

    /// Combines this sequence state source with a channel of indices and combines them into a prism
    /// where the subselection will be issued whenever a change in either the selection or the underlying
    /// elements occurs; indices that are invalid or become invalid will be silently ignored.
    @inlinable func match<Join: ChannelType>(_ locator: Join, setter: @escaping (Pulse.RawValue, Pulse.RawValue.Index, Pulse.RawValue.Element?) -> Pulse.RawValue, getter: @escaping (Pulse.RawValue, Pulse.RawValue.Index) -> Pulse.RawValue.Element?) -> FocusChannel<Pulse.RawValue> where Join.Source : StateEmitterType, Join.Pulse.RawValue : Sequence, Join.Pulse.RawValue.Element == Pulse.RawValue.Index, Join.Pulse : MutationType, Join.Pulse.RawValue == Join.Source.RawValue {

        typealias Output = Pulse.RawValue
        typealias Query = (input: Pulse.RawValue, indices: Join.Pulse.RawValue)

        func query(_ query: Query) -> Output {
            var elements = Output()
            for index in query.indices {
                if let value = getter(query.input, index) {
                    elements.append(value)
                }
            }
            // assert(elements.count == Array(query.indices).count)
            return elements
        }

        func update(_ query: Query, output: Output) -> Query {
            // assert(output.count == Array(query.indices).count)
            var updated = query.input
            for (index, element) in Swift.zip(query.indices, output) {
                updated = setter(updated, index, element)
            }
            return (updated, query.indices)
        }

        return join(locator, finder: { query(($0, $1)) }, updater: update)
    }

    /// Combines this collection state source with a channel of indices and combines them into a prism
    /// where the subselection will be issued whenever a change in either the selection or the underlying
    /// elements occurs; indices that are invalid or become invalid will be silently ignored.
    @inlinable func subselect<C: ChannelType>(_ locator: C, setter: @escaping (Pulse.RawValue, Pulse.RawValue.Index, Pulse.RawValue.Element?) -> Pulse.RawValue) -> FocusChannel<Pulse.RawValue> where C.Source : StateEmitterType, C.Pulse.RawValue : Sequence, C.Pulse.RawValue.Element == Pulse.RawValue.Index, C.Pulse : MutationType, C.Pulse.RawValue == C.Source.RawValue {

        return match(locator, setter: setter) { collection, index in
            if collection.indices.contains(index) {
                return collection[index]
            } else {
                return nil
            }
        }
    }
    
    /// Combines this collection state source with a channel of indices and combines them into a prism
    /// where the subselection will be issued whenever a change in either the selection or the underlying
    /// elements occurs; indices that are invalid or become invalid will be silently ignored.
    @inlinable func indices<C: ChannelType>(_ indices: C) -> FocusChannel<Pulse.RawValue> where C.Source : StateEmitterType, C.Source.RawValue : Sequence, C.Source.RawValue.Element == Source.RawValue.Index, C.Pulse : MutationType, C.Pulse.RawValue == C.Source.RawValue {
        return subselect(indices) { (seq, idx, val) in
            if seq.indices.contains(idx) {
                var s = seq
                s.replaceSubrange(idx...idx, with: CollectionOfOne(val).compactMap({ $0 }))
                return s
            } else {
                return seq
            }
        }
    }
    
    /// Combines this collection state source with a channel of a single index and combines them into a prism
    /// where the subselection will be issued whenever a change in either the selection or the underlying
    /// elements occurs; indices that are invalid or become invalid will be silently ignored.
    @inlinable func index<C: ChannelType>(_ index: C) -> LensChannel<FocusChannel<Pulse.RawValue>, Pulse.RawValue.Element?> where C.Source : TransceiverType, C.Pulse : MutationType, C.Source.RawValue == C.Pulse.RawValue, C.Source.RawValue == Source.RawValue.Index? {
        
        // TODO: this should return FocusChannel<Value.Element?> instead of LensChannel<FocusChannel<Self.Pulse.Value>, Self.Pulse.Value.Element?>, but since we are relying on the indices function for the subselection implementation, we need to have an extra level of indirection. For example, an integer indexed indexOf currently returns:
        //   Channel<LensSource<Channel<LensSource<Channel<ValueTransceiver<[String]>, Mutation<[String]>>, [String]>, Mutation<[String]>>, String?>, Mutation<String?>>
        // but it should just return:
        //   Channel<LensSource<Channel<ValueTransceiver<[String]>, Mutation<[String]>>, [String]>, Mutation<[String]>>
        
        // optional channel -> collection channel
        let idx: C.FocusChannel<[Source.RawValue.Index]> = index.focus(get: { v in v.flatMap({ [$0] }) ?? [] }, set: { v, c in v = c.first ?? .none })
        
        let ichan: FocusChannel<Pulse.RawValue> = self.indices(idx)
        
        // collection channel -> optional channel
        let fchan: LensChannel<FocusChannel<Pulse.RawValue>, Pulse.RawValue.Element?> = ichan.focus(get: { c in c.first ?? .none }, set: { c, v in
            c.replaceSubrange(c.startIndex..<c.endIndex, with: v.flatMap({ [$0] }) ?? [])
        })
        
        return fchan
    }
    
    
    /// Creates a channel to the underlying collection type where the channel creates an optional
    /// to a given static index; setting to nil removes the index, and setting to a certain value
    /// sets the index
    ///
    /// - Note: When setting the value of an index outside the current indices, any
    ///         intervening gaps will be filled with the duplicated value
    @inlinable func indexOf(_ index: Pulse.RawValue.Index) -> FocusChannel<Pulse.RawValue.Element?> {
        let lens: Lens<Pulse.RawValue, Pulse.RawValue.Element?> = Lens(get: { target in
            target.indices.contains(index) ? target[index] : nil
        }, set: { (target, item) in
            if let item = item {
                while !target.indices.contains(index) {
                    // fill in the gaps
                    target.append(item)
                }
                // set the target index item
                target.replaceSubrange(index...index, with: [item])
            } else {
                if target.indices.contains(index) {
                    target.remove(at: index)
                }
            }
        })
        
        return focus(lens: lens)
    }
    
    /// Creates a prism lens channel, allowing access to a collection's mapped lens
    @inlinable func prism<T>(_ lens: Lens<Pulse.RawValue.Element, T>) -> FocusChannel<[T]> {
        let prismLens = Lens<Pulse.RawValue, [T]>(get: { $0.map(lens.get) }) {
            (elements: inout Pulse.RawValue, values: [T]) in
            for (i, val) in Swift.zip(elements.indices, values.makeIterator()) {
                var e = elements[i]
                lens.set(&e, val)
                elements.replaceSubrange(i...i, with: [e])
            }
        }
        return focus(lens: prismLens)
    }
    
    /// Creates a prism lens channel from the given keypath, allowing access to a collection's mapped lens
    @inlinable func prism<T>(_ kp: WritableKeyPath<Pulse.RawValue.Element, T>) -> FocusChannel<[T]> {
        return prism(Lens(kp: kp))
    }
    
    /// Returns an accessor to the collection's range of elements
    @inlinable func range(_ range: ClosedRange<Pulse.RawValue.Index>) -> FocusChannel<Pulse.RawValue.SubSequence> {
        let rangeLens = Lens<Pulse.RawValue, Pulse.RawValue.SubSequence>(get: { $0[range] }) {
            (elements: inout Pulse.RawValue, values: Pulse.RawValue.SubSequence) in
            elements.replaceSubrange(range, with: Array(values))
        }
        return focus(lens: rangeLens)
    }
}

public extension ChannelType where Source.RawValue : MutableCollection, Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {

    /// Combines this collection state source with a channel of indices and combines them into a prism
    /// where the subselection will be issued whenever a change in either the selection or the underlying
    /// elements occurs; indices that are invalid or become invalid will be silently ignored.
    /// Array elements cannot be removed, so updated with a mismatched number of indices will be ignored.
//    public func fixed<C: ChannelType>(_ indices: C) -> FocusChannel<[Self.Value.Element]> where C.Source : StateEmitterType, C.Value : Sequence, C.Value.Element == Value.Index, C.Pulse : MutationType, C.Value == C.Value {
//        return subselect(indices) { (seq, idx, val) in
//            var seq = seq
//            if let val = val, seq.indices.contains(idx) {
//                seq[idx] = val // FIXME: what to do with missing values?
//            }
//            return seq
//        }
//    }
}

/// Development function that pretends to return any T, but really just crashes
//@available(*, deprecated, message: "crashes always!") func die<T>() -> T { fatalError("DIE: \(T.self)") }

public extension ChannelType where Source.RawValue : KeyIndexed & Collection, Source.RawValue.Index : KeyIndexedIndexType, Source.RawValue.Key == Source.RawValue.Index.Key, Source.RawValue.Value == Source.RawValue.Index.Value, Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {

    /// Combines this collection state source with a channel of indices and combines them into a prism
    /// where the subselection will be issued whenever a change in either the selection or the underlying
    /// elements occurs; indices that are invalid or become invalid will be represented by nil in the
    /// pulsed collection; nulling out individual members of existant keys will have no effect.
    @inlinable func keyed<S: Sequence>(_ indices: TransceiverChannel<S>) -> FocusChannel<[Pulse.RawValue.Value?]> where S.Iterator.Element == Pulse.RawValue.Key {

        return join(indices, finder: { dict, keys in
            var values: [Pulse.RawValue.Value?] = []
            for key in keys {
                values.append(dict[key])
            }
            return values
            }, updater: { dkeys, values in
                var dict = dkeys.0
                for (key, value) in Swift.zip(dkeys.1, values) {
                    dict[key] = value
                }
                return (dict, dkeys.1)
        })
    }
}


/// Bogus protocol since, unlike Array -> CollectionType, Dictionary doesn't have any protocol.
/// Exists merely for the `ChannelType.at` prism.
public protocol KeyIndexed {
    associatedtype Key : Hashable
    associatedtype Value
    subscript (key: Key) -> Value? { get set }
}

extension Dictionary : KeyIndexed {
}

public protocol KeyIndexedIndexType : Comparable {
    associatedtype Key : Hashable
    associatedtype Value

    /// This function is a side-effect of the inability to adopt a protocol and conform
    /// to same-named associatedtypes unless there is a function returning the values.
    func __this() -> DictionaryIndex<Key, Value>
}

extension DictionaryIndex : KeyIndexedIndexType {

    @inlinable public func __this() -> DictionaryIndex<Key, Value> {
        return self
    }

}

public extension ChannelType where Source.RawValue : KeyIndexed, Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {
    /// Creates a state channel to the given key in the underlying `KeyIndexed` dictionary
    @inlinable func atKey(_ key: Pulse.RawValue.Key) -> FocusChannel<Pulse.RawValue.Value?> {
        let lens: Lens<Pulse.RawValue, Pulse.RawValue.Value?> = Lens(get: { $0[key] }, set: { $0[key] = $1 })
        return focus(lens: lens)
    }

//    /// Combines this collection state source with a channel of indices and combines them into a prism
//    /// where the subselection will be issued whenever a change in either the selection or the underlying
//    /// elements occurs; indices that are invalid or become invalid will be silently ignored.
//    @inlinable func sub<C: ChannelType>(_ index: C) -> FocusChannel<[Value.Value]> where C.Source : TransceiverType, C.Pulse : MutationType, C.Source.Value == C.Pulse.Value, C.Source.Value == [Source.Value.Key] {
//        return die()
//    }
//
//    /// Combines this collection state source with a channel of indices and combines them into a prism
//    /// where the subselection will be issued whenever a change in either the selection or the underlying
//    /// elements occurs; indices that are invalid or become invalid will be silently ignored.
//    @inlinable func at<C: ChannelType>(_ index: C) -> FocusChannel<Value.Value?> where C.Source : TransceiverType, C.Pulse : MutationType, C.Source.Value == C.Pulse.Value, C.Source.Value == Source.Value.Key? {
//
////        return sub.focus(lens: Lens(get: { _ in die() }, set: { _, _ in dieg() }))
//
//        // TODO: this should return FocusChannel<Value.Element?> instead of LensChannel<FocusChannel<Self.Pulse.Value>, Self.Pulse.Value.Element?>, but since we are relying on the indices function for the subselection implementation, we need to have an extra level of indirection. For example, an integer indexed indexOf currently returns:
//        //   Channel<LensSource<Channel<LensSource<Channel<ValueTransceiver<[String]>, Mutation<[String]>>, [String]>, Mutation<[String]>>, String?>, Mutation<String?>>
//        // but it should just return:
//        //   Channel<LensSource<Channel<ValueTransceiver<[String]>, Mutation<[String]>>, [String]>, Mutation<[String]>>
//
////        // optional channel -> collection channel
////        let idx: C.FocusChannel<[Source.Value.Index]> = index.focus(get: { v in v.flatMap({ [$0] }) ?? [] }, set: { v, c in v = c.first ?? .none })
////
////        let ichan: FocusChannel<Value> = self.indices(idx)
////
////        // collection channel -> optional channel
////        let fchan: LensChannel<FocusChannel<Value>, Value.Element?> = ichan.focus(get: { c in c.first ?? .none }, set: { c, v in
////            c.replaceSubrange(c.startIndex..<c.endIndex, with: v.flatMap({ [$0] }) ?? [])
////        })
////
////        return fchan
//
//        return die()
//    }

}

public protocol Optical : class {
    associatedtype T: ChannelType where T.Source : TransceiverType, T.Pulse : MutationType, T.Pulse.RawValue == T.Source.RawValue
    
    var optic: T { get }
    
    init(_ optical: T)
}

public extension ChannelType where Source.RawValue : ChooseNType, Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {
    /// Channel for the first option of N choices
    @inlinable var v1Z: FocusChannel<Pulse.RawValue.T1?> {
        return focus(get: { (x: Pulse.RawValue) in x.v1 }, set: { (x: inout Pulse.RawValue, y: Pulse.RawValue.T1?) in x.v1 = y })
    }
}

public extension ChannelType where Source.RawValue : Choose2Type, Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {
    /// Channel for the second option of N choices
    @inlinable var v2Z: FocusChannel<Pulse.RawValue.T2?> {
        return focus(get: { $0.v2 }, set: { (x: inout Pulse.RawValue, y: Pulse.RawValue.T2?) in x.v2 = y })
    }
}

public extension ChannelType where Source.RawValue : Choose3Type, Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {
    /// Channel for the third option of N choices
    @inlinable var v3Z: FocusChannel<Pulse.RawValue.T3?> {
        return focus(get: { $0.v3 }, set: { (x: inout Pulse.RawValue, y: Pulse.RawValue.T3?) in x.v3 = y })
    }
}

public extension ChannelType where Source.RawValue : Choose4Type, Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {
    /// Channel for the fourth option of N choices
    @inlinable var v4Z: FocusChannel<Pulse.RawValue.T4?> {
        return focus(get: { $0.v4 }, set: { (x: inout Pulse.RawValue, y: Pulse.RawValue.T4?) in x.v4 = y })
    }
}

public extension ChannelType where Source.RawValue : Choose5Type, Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {
    /// Channel for the fifth option of N choices
    @inlinable var v5Z: FocusChannel<Pulse.RawValue.T5?> {
        return focus(get: { $0.v5 }, set: { (x: inout Pulse.RawValue, y: Pulse.RawValue.T5?) in x.v5 = y })
    }
}

public extension ChannelType where Source.RawValue : Choose6Type, Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {
    /// Channel for the sixth option of N choices
    @inlinable var v6Z: FocusChannel<Pulse.RawValue.T6?> {
        return focus(get: { $0.v6 }, set: { (x: inout Pulse.RawValue, y: Pulse.RawValue.T6?) in x.v6 = y })
    }
}

public extension ChannelType where Source.RawValue : Choose7Type, Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {
    /// Channel for the seventh option of N choices
    @inlinable var v7Z: FocusChannel<Pulse.RawValue.T7?> {
        return focus(get: { $0.v7 }, set: { (x: inout Pulse.RawValue, y: Pulse.RawValue.T7?) in x.v7 = y })
    }
}

public extension ChannelType where Source.RawValue : Choose8Type, Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {
    /// Channel for the eighth option of N choices
    @inlinable var v8Z: FocusChannel<Pulse.RawValue.T8?> {
        return focus(get: { $0.v8 }, set: { (x: inout Pulse.RawValue, y: Pulse.RawValue.T8?) in x.v8 = y })
    }
}

public extension ChannelType where Source.RawValue : Choose9Type, Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {
    /// Channel for the ninth option of N choices
    @inlinable var v9Z: FocusChannel<Pulse.RawValue.T9?> {
        return focus(get: { $0.v9 }, set: { (x: inout Pulse.RawValue, y: Pulse.RawValue.T9?) in x.v9 = y })
    }
}

public extension ChannelType where Source.RawValue : Choose10Type, Source : TransceiverType, Pulse : MutationType, Pulse.RawValue == Source.RawValue {
    /// Channel for the tenth option of N choices
    @inlinable var v10Z: FocusChannel<Pulse.RawValue.T10?> {
        return focus(get: { $0.v10 }, set: { (x: inout Pulse.RawValue, y: Pulse.RawValue.T10?) in x.v10 = y })
    }
}
