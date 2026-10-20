import Foundation
import Testing

@testable import OpenCineNikon

// ZT-04 / ZT-05: two cards, the body names the stills slot. The shots counter follows the
// stills card alone (never a sum), and a remote release is pointed at it when the body lets
// the host choose.

private func le64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8((value >> ($0 * 8)) & 0xFF) } }
private func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) } }

private func card(freeImages: UInt32?) -> PTPStorageInfo {
    let images = freeImages.map(le32) ?? le32(0xFFFF_FFFF)
    let header: [UInt8] = [1, 0, 2, 0, 3, 0]
    return PTPStorageInfo(header + le64(512_000_000_000) + le64(400_000_000_000) + images)!
}

/// A standard UINT8 enumeration descriptor (`GetDevicePropDesc`, 16-bit property code).
private func slotDescriptor(
    _ property: PTPPropertyCode, current: UInt8, values: [UInt8], writable: Bool
) -> NikonScalarPropertyDescriptor {
    let code = UInt16(property.rawValue)
    let bytes: [UInt8] =
        [UInt8(code & 0xFF), UInt8(code >> 8), 0x02, 0x00, writable ? 1 : 0, values[0], current, 2,
         UInt8(values.count), 0] + values
    return NikonScalarPropertyDescriptor.parse(
        Data(bytes), property: property.rawValue, valueByteCount: 1)!
}

/// CFexpress B in slot 1, SD in slot 2, as the tester's Z6III.
private func twoCards(slot1: UInt32?, slot2: UInt32?) -> [(id: UInt32, info: PTPStorageInfo)] {
    [(0x0001_0001, card(freeImages: slot1)), (0x0002_0001, card(freeImages: slot2))]
}

@Test func storageInfoDecodesFreeSpaceInImagesAndItsSentinel() {
    #expect(card(freeImages: 10_141).freeSpaceInImages == 10_141)
    #expect(card(freeImages: nil).freeSpaceInImages == nil)
    let short = PTPStorageInfo([1, 0, 2, 0, 3, 0] + le64(1) + le64(1))
    #expect(short?.freeSpaceInImages == nil)
}

@Test func remainingShotsUseTheStillsCardNotBothCardsSummed() {
    let readout = NikonCardSlotReadout(
        storage: twoCards(slot1: 10_141, slot2: 10_120),
        primarySlot: slotDescriptor(.primarySlot, current: 1, values: [0, 1], writable: true))
    #expect(readout.stillsSlot == 2)
    #expect(readout.stillsCardShots == 10_120)

    // The body's ExposureRemaining reports both cards (overflow); the counter shows the SD card.
    let snapshot = PTPCameraPropertySnapshot()
        .applying(property: .exposureRemaining, data: Data(le32(20_261)))
        .applyingCardSlots(readout)
    #expect(snapshot.shotsRemaining == 10_120)
}

@Test func remainingShotsKeepTheBodysCountWithOneCardOrNoStillsSlot() {
    let reported = PTPCameraPropertySnapshot()
        .applying(property: .exposureRemaining, data: Data(le32(20_261)))
    let oneCard = NikonCardSlotReadout(
        storage: [(0x0002_0001, card(freeImages: 10_120))],
        primarySlot: slotDescriptor(.primarySlot, current: 1, values: [0, 1], writable: true))
    #expect(reported.applyingCardSlots(oneCard).shotsRemaining == 20_261)
    let unnamed = NikonCardSlotReadout(storage: twoCards(slot1: 10_141, slot2: 10_120))
    #expect(reported.applyingCardSlots(unnamed).shotsRemaining == 20_261)
    let uncounted = NikonCardSlotReadout(
        storage: twoCards(slot1: 10_141, slot2: nil),
        primarySlot: slotDescriptor(.primarySlot, current: 1, values: [0, 1], writable: true))
    #expect(reported.applyingCardSlots(uncounted).shotsRemaining == 20_261)
}

@Test func stillsCardCountFollowsFramesTakenBetweenStorageReads() {
    let readout = NikonCardSlotReadout(
        storage: twoCards(slot1: 10_141, slot2: 10_120),
        primarySlot: slotDescriptor(.primarySlot, current: 1, values: [0, 1], writable: true))
    var snapshot = PTPCameraPropertySnapshot()
        .applying(property: .exposureRemaining, data: Data(le32(20_261)))
        .applyingCardSlots(readout)
    snapshot = snapshot.decrementingShotsRemaining()
    #expect(snapshot.shotsRemaining == 10_119)
    // A five-frame burst, then the poll confirms it.
    snapshot = snapshot.applying(property: .exposureRemaining, data: Data(le32(20_255)))
    #expect(snapshot.shotsRemaining == 10_114)
    // RAW to JPEG roughly triples both cards; the estimate rescales until the next storage read.
    snapshot = snapshot.applying(property: .exposureRemaining, data: Data(le32(60_765)))
    #expect(snapshot.shotsRemaining == 30_342)
}

@Test func storageIDsOrderByPhysicalSlotAndFallBackToListOrder() {
    let appended = NikonCardSlotReadout(
        storage: [(0x0002_0001, card(freeImages: 2)), (0x0001_0001, card(freeImages: 1))])
    #expect(appended.cards.map(\.slot) == [1, 2])
    #expect(appended.cards.map(\.storageID) == [0x0001_0001, 0x0002_0001])
    let unpatterned = NikonCardSlotReadout(
        storage: [(0x0000_0007, card(freeImages: 1)), (0x0000_0009, card(freeImages: 2))])
    #expect(unpatterned.cards.map(\.slot) == [1, 2])
}

@Test func activeSlotIsPointedAtTheStillsCardOnlyWhenTheBodyAllowsIt() {
    let primary = slotDescriptor(.primarySlot, current: 1, values: [0, 1], writable: true)
    let mismatched = NikonCardSlotReadout(
        storage: twoCards(slot1: 10_141, slot2: 10_120), primarySlot: primary,
        activeSlot: slotDescriptor(.activeSlot, current: 0, values: [0, 1], writable: true))
    #expect(mismatched.activeSlotAlignment == [1])

    let matching = NikonCardSlotReadout(
        storage: twoCards(slot1: 10_141, slot2: 10_120), primarySlot: primary,
        activeSlot: slotDescriptor(.activeSlot, current: 1, values: [0, 1], writable: true))
    #expect(matching.activeSlotAlignment == nil)

    let readOnly = NikonCardSlotReadout(
        storage: twoCards(slot1: 10_141, slot2: 10_120), primarySlot: primary,
        activeSlot: slotDescriptor(.activeSlot, current: 0, values: [0, 1], writable: false))
    #expect(readOnly.activeSlotAlignment == nil)

    // A full stills card: overflow has legitimately moved on, so the active slot stays.
    let full = NikonCardSlotReadout(
        storage: twoCards(slot1: 10_141, slot2: 0), primarySlot: primary,
        activeSlot: slotDescriptor(.activeSlot, current: 0, values: [0, 1], writable: true))
    #expect(full.activeSlotAlignment == nil)
}

@Test func aKnownSlotIsNeverMovedAndAnUnresolvedCardNeverStandsInForTheStillsCard() {
    let slot2ThenUnpatterned: [(id: UInt32, info: PTPStorageInfo)] = [
        (0x0002_0001, card(freeImages: 200)), (0x0000_0007, card(freeImages: 900)),
    ]
    let active = slotDescriptor(.activeSlot, current: 2, values: [1, 2], writable: true)
    let slot1Stills = NikonCardSlotReadout(
        storage: slot2ThenUnpatterned,
        primarySlot: slotDescriptor(.primarySlot, current: 1, values: [1, 2], writable: true),
        activeSlot: active)
    #expect(slot1Stills.cards.map(\.storageID) == [0x0000_0007, 0x0002_0001])
    #expect(slot1Stills.cards.map(\.slot) == [1, 2])
    #expect(slot1Stills.cards.map(\.slotIsPhysical) == [false, true])
    #expect(slot1Stills.stillsCard == nil)
    #expect(slot1Stills.stillsCardShots == nil)
    #expect(slot1Stills.activeSlotAlignment == nil)
    let slot2Stills = NikonCardSlotReadout(
        storage: slot2ThenUnpatterned,
        primarySlot: slotDescriptor(.primarySlot, current: 2, values: [1, 2], writable: true))
    #expect(slot2Stills.stillsCard?.storageID == 0x0002_0001)
    #expect(slot2Stills.stillsCardShots == 200)
    let sharedSlot = NikonCardSlotReadout(
        storage: [(0x0001_0001, card(freeImages: 1)), (0x0001_0002, card(freeImages: 2))],
        primarySlot: slotDescriptor(.primarySlot, current: 1, values: [1, 2], writable: true))
    #expect(sharedSlot.cards.map(\.slot) == [1, 2])
    #expect(sharedSlot.cards.allSatisfy { !$0.slotIsPhysical })
    #expect(sharedSlot.stillsCardShots == nil)
}
