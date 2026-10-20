import Foundation

/// One inserted card, keyed by its physical slot.
public struct NikonStorageCard: Equatable, Sendable {
    /// Authoritative PTP storage identifier.
    public let storageID: UInt32
    /// One-based slot: the physical slot from the storage ID's high word when it follows the Nikon
    /// pattern, otherwise a display number that no other card holds.
    public let slot: Int
    /// Capacity, free space and free frames reported for this card alone.
    public let info: PTPStorageInfo
    /// Whether `slot` is the physical slot rather than a display number. Only a physical slot can
    /// be matched to the body's slot properties.
    public let slotIsPhysical: Bool

    public init(storageID: UInt32, slot: Int, info: PTPStorageInfo, slotIsPhysical: Bool = true) {
        self.storageID = storageID
        self.slot = slot
        self.info = info
        self.slotIsPhysical = slotIsPhysical
    }
}

/// The card slot the body writes stills to and what follows from it: the remaining-shots figure
/// and the slot a remote release should land on.
///
/// Nikon's `ExposureRemaining` (0xD1F1) can count every inserted card (overflow), while the body's
/// own screen counts only the card it writes stills to. With two cards and a known stills slot, the
/// stills card's own `FreeSpaceInImages` is the figure. Counts from several cards are never summed.
public struct NikonCardSlotReadout: Equatable, Sendable {
    /// Every usable card, ordered by physical slot.
    public let cards: [NikonStorageCard]
    /// `PrimarySlot` (0xD156) as described by the body; nil when absent or not a scalar.
    public let primarySlot: NikonScalarPropertyDescriptor?
    /// `ActiveSlot` (0xD1F2) as described by the body; nil when absent or not a scalar.
    public let activeSlot: NikonScalarPropertyDescriptor?

    public init(
        cards: [NikonStorageCard],
        primarySlot: NikonScalarPropertyDescriptor? = nil,
        activeSlot: NikonScalarPropertyDescriptor? = nil
    ) {
        self.cards = cards
        self.primarySlot = primarySlot
        self.activeSlot = activeSlot
    }

    /// Orders storage-info results by physical slot. A card keeps the slot in its `0x000S_xxxx`
    /// storage ID when no other card claims the same one. Any other card (outside the pattern, or
    /// sharing a slot number) gets the lowest free display number in enumeration order, marked as
    /// not physical, so no card is dropped and no known card is moved to another slot.
    public init(
        storage: [(id: UInt32, info: PTPStorageInfo)],
        primarySlot: NikonScalarPropertyDescriptor? = nil,
        activeSlot: NikonScalarPropertyDescriptor? = nil
    ) {
        let patterned = storage.map { Self.physicalSlot(storageID: $0.id) }
        let claims = Dictionary(grouping: patterned.compactMap { $0 }, by: { $0 })
        var taken = Set(claims.filter { $0.value.count == 1 }.keys)
        var cards: [NikonStorageCard] = []
        for (entry, slot) in zip(storage, patterned) {
            if let slot, claims[slot]?.count == 1 {
                cards.append(NikonStorageCard(storageID: entry.id, slot: slot, info: entry.info))
                continue
            }
            let display = (1...).first { !taken.contains($0) }!
            taken.insert(display)
            cards.append(
                NikonStorageCard(
                    storageID: entry.id, slot: display, info: entry.info, slotIsPhysical: false))
        }
        self.init(
            cards: cards.sorted { $0.slot < $1.slot }, primarySlot: primarySlot,
            activeSlot: activeSlot)
    }

    /// The physical slot in a Nikon storage ID's high word (`0x000S_0001`); nil outside it.
    public static func physicalSlot(storageID: UInt32) -> Int? {
        let slot = Int((storageID >> 16) & 0xFF)
        return slot > 0 ? slot : nil
    }

    /// One-based slot a slot property selects: its position in the advertised enumeration, or its
    /// offset from a range minimum. nil when the body gives no usable form. [verify-on-HW]
    public static func slot(selectedBy descriptor: NikonScalarPropertyDescriptor?) -> Int? {
        guard let descriptor else { return nil }
        switch descriptor.form {
        case .enumeration(let values):
            return values.firstIndex(of: descriptor.currentValue).map { $0 + 1 }
        case .range(let minimum, _, _):
            let current = Self.scalar(descriptor.currentValue)
            let low = Self.scalar(minimum)
            return current >= low ? Int(current - low) + 1 : nil
        case .none:
            return nil
        }
    }

    /// The slot the body writes stills to; nil when the body does not say.
    public var stillsSlot: Int? { Self.slot(selectedBy: primarySlot) }

    /// The card the body writes stills to, when it is inserted and its physical slot is known.
    public var stillsCard: NikonStorageCard? {
        guard let stillsSlot else { return nil }
        return cards.first { $0.slotIsPhysical && $0.slot == stillsSlot }
    }

    /// Frames left on the stills card alone. nil with fewer than two cards (the body's own figure
    /// is then that card's) or when the stills card or its count is unknown.
    public var stillsCardShots: Int? {
        guard cards.count >= 2 else { return nil }
        return stillsCard?.info.freeSpaceInImages
    }

    /// The `ActiveSlot` value that points remote releases at the stills card, or nil when nothing
    /// should be written: the body does not let the host set it, it already matches, the stills
    /// card is unknown or full (overflow then legitimately moved on), or only one card is in.
    /// Only the body's own primary-slot choice is followed; that setting itself is never written.
    /// [verify-on-HW]
    public var activeSlotAlignment: [UInt8]? {
        guard cards.count >= 2, let activeSlot, activeSlot.writable,
            let stillsCard, (stillsCard.info.freeSpaceInImages ?? 0) > 0,
            case .enumeration(let values) = activeSlot.form,
            stillsCard.slot <= values.count
        else { return nil }
        let target = values[stillsCard.slot - 1]
        return target == activeSlot.currentValue ? nil : target
    }

    /// Compact diagnostic line: cards, both slot properties as raw bytes, and the resolved slot.
    public var diagnosticSummary: String {
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        func describe(_ descriptor: NikonScalarPropertyDescriptor?) -> String {
            guard let descriptor else { return "absent" }
            let form: String
            switch descriptor.form {
            case .enumeration(let values):
                form = "enum[" + values.map(hex).joined(separator: ",") + "]"
            case .range(let low, let high, let step):
                form = "range[\(hex(low))-\(hex(high))/\(hex(step))]"
            case .none: form = "none"
            }
            return "\(hex(descriptor.currentValue)) \(descriptor.writable ? "rw" : "ro") \(form)"
        }
        let cardList = cards.map { card in
            "slot\(card.slot)=0x\(String(card.storageID, radix: 16)):"
                + (card.info.freeSpaceInImages.map(String.init) ?? "?")
        }.joined(separator: " ")
        return "cards[\(cardList)] primary=\(describe(primarySlot)) active=\(describe(activeSlot)) "
            + "stills=\(stillsSlot.map(String.init) ?? "?")"
    }

    private static func scalar(_ bytes: [UInt8]) -> UInt64 {
        bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }
}
