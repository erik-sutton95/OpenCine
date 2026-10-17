import Foundation
import OpenCineMedia
import XCTest

/// SIMULATED cumulative observations on a manual clock; no decoder, transport or timer.
final class FeedIncidentRateSamplerTests: XCTestCase {
    func testCounterOwnerReplacementSeedsEvenWhenSuccessorCountsAreLarger() {
        var sampler = FeedIncidentRateSampler()
        let first = FeedIncidentCounterEpoch(
            decoderGeneration: 1, socketGeneration: 1, processedPresentation: false)
        _ = sampler.sample(now: 1, counts: .init(accessUnit: 10), epoch: first)
        XCTAssertEqual(
            sampler.sample(now: 2, counts: .init(accessUnit: 11), epoch: first).observed?
                .accessUnitHz, 1)
        let next = FeedIncidentCounterEpoch(
            decoderGeneration: 2, socketGeneration: 1, processedPresentation: false)
        XCTAssertNil(
            sampler.sample(now: 3, counts: .init(accessUnit: 500), epoch: next).observed?
                .accessUnitHz)
        XCTAssertEqual(
            sampler.sample(now: 4, counts: .init(accessUnit: 501), epoch: next).observed?
                .accessUnitHz, 1)
        XCTAssertNil(
            sampler.sample(
                now: 5, counts: .init(accessUnit: 600),
                epoch: .init(
                    decoderGeneration: 2, socketGeneration: 2, processedPresentation: false)
            ).observed?.accessUnitHz)
        XCTAssertNil(
            sampler.sample(
                now: 6, counts: .init(accessUnit: 700),
                epoch: .init(decoderGeneration: 2, socketGeneration: 2, processedPresentation: true)
            ).observed?.accessUnitHz)
    }
    func testFirstReadingUnavailableStagesAndMeasuredZeroRemainDistinct() {
        var sampler = FeedIncidentRateSampler()
        XCTAssertNil(sampler.sample(now: 10, counts: .init(accessUnit: 4)).observed?.accessUnitHz)
        let next = sampler.sample(now: 12, counts: .init(accessUnit: 4, decodedOutput: 0))
        XCTAssertEqual(next.observed?.accessUnitHz, 0)
        XCTAssertNil(next.observed?.packetHz)
        XCTAssertNil(next.observed?.decodedOutputHz)
        XCTAssertEqual(
            sampler.sample(now: 14, counts: .init(accessUnit: 9, decodedOutput: 0)).observed?
                .accessUnitHz, 2.5)
    }

    func testInvalidAndDuplicateReadingsCannotReplaceBaseline() {
        var sampler = FeedIncidentRateSampler()
        _ = sampler.sample(now: 10, counts: .init(accessUnit: 4))
        for now in [Double.nan, .infinity, -1, 9, 10] {
            XCTAssertNil(
                sampler.sample(now: now, counts: .init(accessUnit: 100)).observed?.accessUnitHz)
        }
        XCTAssertEqual(
            sampler.sample(now: 12, counts: .init(accessUnit: 8)).observed?.accessUnitHz, 2)
    }

    func testCounterAndOwnerResetDoNotInventAZeroRate() {
        var sampler = FeedIncidentRateSampler()
        _ = sampler.sample(now: 1, counts: .init(accessUnit: 100, present: 2))
        let reset = sampler.sample(now: 2, counts: .init(accessUnit: 1, present: 4))
        XCTAssertNil(reset.observed?.accessUnitHz)
        XCTAssertEqual(reset.observed?.presentHz, 2)
        XCTAssertEqual(
            sampler.sample(now: 3, counts: .init(accessUnit: 3)).observed?.accessUnitHz, 2)
        sampler.reset()
        XCTAssertNil(sampler.sample(now: 4, counts: .init(accessUnit: 4)).observed?.accessUnitHz)
    }

    func testCounterBoundsAndAgeClockDomains() {
        var sampler = FeedIncidentRateSampler()
        _ = sampler.sample(now: 1, counts: .init(accessUnit: 0, present: -1))
        let result = sampler.sample(now: 2, counts: .init(accessUnit: Int.max, present: Int.max))
        XCTAssertEqual(result.observed?.accessUnitHz, Double(Int.max))
        XCTAssertNil(result.observed?.presentHz)
        XCTAssertEqual(FeedIncidentRateSampler.age(since: 3, now: 5), 2)
        XCTAssertEqual(FeedIncidentRateSampler.age(since: 5, now: 5), 0)
        XCTAssertNil(FeedIncidentRateSampler.age(since: 6, now: 5))
        XCTAssertNil(FeedIncidentRateSampler.age(since: Double.nan, now: 5))
        XCTAssertNil(FeedIncidentRateSampler.age(since: Optional<Double>.none, now: 5))
        XCTAssertEqual(
            FeedIncidentRateSampler.age(
                since: Date(timeIntervalSince1970: 10),
                now: Date(timeIntervalSince1970: 12)), 2)
    }

    func testOptionalObservationRoundTripsAndLegacyNumericRatesDecode() throws {
        var sampler = FeedIncidentRateSampler()
        _ = sampler.sample(now: 1, counts: .init(accessUnit: 0))
        let rates = sampler.sample(now: 2, counts: .init(accessUnit: 3))
        let data = try FeedIncidentCoding.encoder().encode(rates)
        XCTAssertEqual(
            try FeedIncidentCoding.decoder().decode(FeedIncidentRates.self, from: data), rates)
        let legacy = Data(
            "{\"packetHz\":0,\"accessUnitHz\":3,\"decodeSubmitHz\":0,\"decodeAcceptHz\":0,\"decodedOutputHz\":0,\"assistOutputHz\":0,\"presentHz\":0,\"ackHz\":0}"
                .utf8)
        let decoded = try FeedIncidentCoding.decoder().decode(FeedIncidentRates.self, from: legacy)
        XCTAssertEqual(decoded.accessUnitHz, 3)
        XCTAssertNil(decoded.observed)
    }
}
