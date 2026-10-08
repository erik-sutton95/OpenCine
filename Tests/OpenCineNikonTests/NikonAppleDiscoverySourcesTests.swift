#if canImport(Darwin) && !os(watchOS)
    import Darwin
    import Foundation
    import Testing

    @testable import OpenCineNikon

    /// Apple source lifetime tests use the real source/window owner with a manual scheduler and
    /// controllable SDK driver. No test browses a network, opens a USB device or sleeps.
    @Suite struct NikonAppleDiscoverySourcesTests {
        @Test func hardDeadlineStopsAnEmptyBrowseAndRejectsLateResolution() async throws {
            let rig = NikonAppleDiscoveryRig()
            let source = rig.makeSource()
            defer { source.close() }
            let task = Task { await source.bonjour(timeout: .milliseconds(1_400)) }
            try await waitForNikonAppleBrowse {
                rig.browsers.count == 1 && rig.browsers[0].starts == 1
            }
            let browser = rig.browsers[0]

            #expect(rig.clock.scheduledDelays == [.milliseconds(1_400)])
            rig.clock.advance(by: .milliseconds(1_399))
            #expect(browser.stops == 0)
            rig.clock.advance(by: .milliseconds(1))
            #expect(await task.value == [])
            #expect(browser.stops == 1 && rig.clock.pendingCount == 0)

            browser.emitLate(
                .resolved(
                    id: UUID(), name: "Retired", addresses: [nikonAppleSockaddr("192.168.1.20")]))
            browser.emitLate(.failed)
            source.close()
            rig.clock.advance(by: .seconds(5))
            #expect(browser.stops == 1 && rig.clock.pendingCount == 0)
        }

        @Test func firstPrivateResolutionKeepsOriginalSiblingSettleAndSourceIdentity() async throws
        {
            let rig = NikonAppleDiscoveryRig()
            let source = rig.makeSource()
            defer { source.close() }
            let task = Task { await source.bonjour(timeout: .milliseconds(1_400)) }
            try await waitForNikonAppleBrowse {
                rig.browsers.count == 1 && rig.browsers[0].starts == 1
            }
            let browser = rig.browsers[0]
            browser.emit(
                .resolved(
                    id: UUID(), name: "Z_8",
                    addresses: [
                        nikonAppleSockaddr("192.168.1.10"), nikonAppleSockaddr("10.1.2.3"),
                    ]))
            #expect(rig.clock.scheduledDelays == [.milliseconds(1_400), .milliseconds(300)])
            rig.clock.advance(by: .milliseconds(299))
            #expect(browser.stops == 0)
            browser.emit(
                .resolved(id: UUID(), name: "Z_6", addresses: [nikonAppleSockaddr("172.16.4.9")]))
            rig.clock.advance(by: .milliseconds(1))

            #expect(
                await task.value == [
                    DiscoveredCamera(ip: "192.168.1.10", name: "Z_8", source: .bonjour),
                    DiscoveredCamera(ip: "10.1.2.3", name: "Z_8", source: .bonjour),
                    DiscoveredCamera(ip: "172.16.4.9", name: "Z_6", source: .bonjour),
                ])
            #expect(browser.stops == 1 && rig.clock.pendingCount == 0)
        }

        @Test func invalidAddressesNeverAdmitASettleWindow() async throws {
            let rig = NikonAppleDiscoveryRig()
            let source = rig.makeSource()
            defer { source.close() }
            let task = Task { await source.bonjour(timeout: .milliseconds(1_400)) }
            try await waitForNikonAppleBrowse {
                rig.browsers.count == 1 && rig.browsers[0].starts == 1
            }
            let browser = rig.browsers[0]
            browser.emit(
                .resolved(
                    id: UUID(), name: "Other",
                    addresses: [
                        Data(), Data([0, UInt8(AF_INET)]), nikonAppleSockaddr("203.0.113.2"),
                        nikonAppleIPv6Sockaddr(),
                    ]))
            #expect(rig.clock.scheduledDelays == [.milliseconds(1_400)])
            rig.clock.advance(by: .milliseconds(1_400))
            #expect(await task.value == [])
            #expect(browser.stops == 1)
        }

        @Test func serviceChurnReplacesAddressesAndRemovesDepartedService() async throws {
            let rig = NikonAppleDiscoveryRig()
            let source = rig.makeSource()
            defer { source.close() }
            let task = Task { await source.bonjour(timeout: .milliseconds(1_400)) }
            try await waitForNikonAppleBrowse {
                rig.browsers.count == 1 && rig.browsers[0].starts == 1
            }
            let browser = rig.browsers[0]
            let replaced = UUID()
            let removed = UUID()
            let invalidated = UUID()
            let current = UUID()
            browser.emit(
                .resolved(
                    id: replaced, name: "Z_8", addresses: [nikonAppleSockaddr("192.168.1.10")]))
            browser.emit(
                .resolved(
                    id: removed, name: "Gone", addresses: [nikonAppleSockaddr("192.168.1.11")]))
            browser.emit(
                .resolved(
                    id: replaced, name: "Z_8", addresses: [nikonAppleSockaddr("192.168.2.10")]))
            browser.emit(.removed(id: removed))
            browser.emit(
                .resolved(
                    id: invalidated, name: "Changed",
                    addresses: [nikonAppleSockaddr("192.168.1.13")]))
            browser.emit(
                .resolved(
                    id: invalidated, name: "Changed",
                    addresses: [nikonAppleSockaddr("203.0.113.13")]))
            browser.emit(
                .resolved(id: current, name: "Z_6", addresses: [nikonAppleSockaddr("192.168.2.12")])
            )
            rig.clock.advance(by: .milliseconds(300))

            #expect(
                await task.value == [
                    DiscoveredCamera(ip: "192.168.2.10", name: "Z_8", source: .bonjour),
                    DiscoveredCamera(ip: "192.168.2.12", name: "Z_6", source: .bonjour),
                ])
            #expect(rig.clock.scheduledDelays == [.milliseconds(1_400), .milliseconds(300)])
        }

        @Test func cancelledTaskStopsItsWindowWithoutRetiringTheSource() async throws {
            let rig = NikonAppleDiscoveryRig()
            let source = rig.makeSource()
            defer { source.close() }
            let cancelled = Task { await source.bonjour(timeout: .milliseconds(1_400)) }
            try await waitForNikonAppleBrowse {
                rig.browsers.count == 1 && rig.browsers[0].starts == 1
            }
            let old = rig.browsers[0]
            old.emit(
                .resolved(id: UUID(), name: "Old", addresses: [nikonAppleSockaddr("192.168.1.10")]))
            cancelled.cancel()
            #expect(await cancelled.value == [])
            #expect(old.stops == 1 && rig.clock.pendingCount == 0)

            let next = Task { await source.bonjour(timeout: .milliseconds(1_400)) }
            try await waitForNikonAppleBrowse {
                rig.browsers.count == 2 && rig.browsers[1].starts == 1
            }
            let current = rig.browsers[1]
            old.emitLate(
                .resolved(
                    id: UUID(), name: "Stale", addresses: [nikonAppleSockaddr("192.168.1.99")]))
            old.emitLate(.failed)
            current.emit(
                .resolved(
                    id: UUID(), name: "Current", addresses: [nikonAppleSockaddr("192.168.2.10")]))
            rig.clock.advance(by: .milliseconds(300))
            #expect(
                await next.value == [
                    DiscoveredCamera(ip: "192.168.2.10", name: "Current", source: .bonjour)
                ])
            #expect(old.stops == 1 && current.stops == 1)
        }

        @Test func cancellationBeforeWindowStartNeverStartsTheSDK() async {
            let rig = NikonAppleDiscoveryRig()
            let source = rig.makeSource()
            defer { source.close() }
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await source.bonjour(timeout: .milliseconds(1_400))
            }
            #expect(await task.value == [])
            #expect(rig.browsers.allSatisfy { $0.starts == 0 })
            #expect(rig.clock.pendingCount == 0)
        }

        @Test func sourceCloseRetiresAllOwnedWindowsButNeverAnotherInstance() async throws {
            let oldRig = NikonAppleDiscoveryRig()
            let newRig = NikonAppleDiscoveryRig()
            let oldSource = oldRig.makeSource()
            let newSource = newRig.makeSource()
            defer {
                oldSource.close()
                newSource.close()
            }
            let oldOne = Task { await oldSource.bonjour(timeout: .milliseconds(1_400)) }
            let oldTwo = Task { await oldSource.bonjour(timeout: .milliseconds(1_400)) }
            let replacement = Task { await newSource.bonjour(timeout: .milliseconds(1_400)) }
            try await waitForNikonAppleBrowse {
                oldRig.browsers.count == 2 && oldRig.browsers.allSatisfy { $0.starts == 1 }
                    && newRig.browsers.count == 1 && newRig.browsers[0].starts == 1
            }
            oldSource.close()
            #expect(await oldOne.value == [])
            #expect(await oldTwo.value == [])
            #expect(oldRig.browsers.allSatisfy { $0.stops == 1 } && oldRig.clock.pendingCount == 0)
            #expect(newRig.browsers[0].stops == 0)

            for browser in oldRig.browsers {
                browser.emitLate(
                    .resolved(
                        id: UUID(), name: "Old", addresses: [nikonAppleSockaddr("192.168.1.10")]))
                browser.emitLate(.failed)
            }
            oldRig.clock.advance(by: .seconds(5))
            newRig.browsers[0].emit(
                .resolved(id: UUID(), name: "New", addresses: [nikonAppleSockaddr("10.1.2.3")]))
            newRig.clock.advance(by: .milliseconds(300))
            #expect(
                await replacement.value == [
                    DiscoveredCamera(ip: "10.1.2.3", name: "New", source: .bonjour)
                ])
            #expect(await oldSource.bonjour(timeout: .milliseconds(1_400)) == [])
            #expect(oldRig.browsers.count == 2)
            #expect(oldSource.interfaces().isEmpty)
            #expect(await oldSource.usbCameras(start: true) == [])
            #expect(oldRig.interfaceReads == 0 && oldRig.usbStarts.isEmpty)
        }

        @Test func browserFailureReturnsCurrentObservationsAndStopsOnce() async throws {
            let rig = NikonAppleDiscoveryRig()
            let source = rig.makeSource()
            defer { source.close() }
            let task = Task { await source.bonjour(timeout: .milliseconds(1_400)) }
            try await waitForNikonAppleBrowse {
                rig.browsers.count == 1 && rig.browsers[0].starts == 1
            }
            let browser = rig.browsers[0]
            browser.emit(
                .resolved(id: UUID(), name: "Z_8", addresses: [nikonAppleSockaddr("192.168.1.10")]))
            browser.emit(.failed)
            #expect(
                await task.value == [
                    DiscoveredCamera(ip: "192.168.1.10", name: "Z_8", source: .bonjour)
                ])
            browser.emitLate(.failed)
            rig.clock.advance(by: .seconds(5))
            #expect(browser.stops == 1 && rig.clock.pendingCount == 0)
        }

        @Test func interfaceReadsFollowNetworkChurnAndClosedReadsStayRetired() {
            let rig = NikonAppleDiscoveryRig()
            let source = rig.makeSource()
            let first = NikonLocalInterface(name: "en0", address: "192.168.1.42", netmask: nil)
            let second = NikonLocalInterface(name: "en1", address: "10.1.2.42", netmask: "10.0.0.0")
            rig.setInterfaces([first])
            #expect(source.interfaces() == [first])
            rig.setInterfaces([second])
            #expect(source.interfaces() == [second] && rig.interfaceReads == 2)
            source.close()
            #expect(source.interfaces() == [] && rig.interfaceReads == 2)
        }

        @Test func retirementDuringHostReadsRejectsReturnedInterfaceAndUSBRows() async {
            let holder = NikonAppleSourceHolder()
            let source = NikonAppleDiscoverySources(
                interfaces: {
                    holder.source?.close()
                    return [NikonLocalInterface(name: "en0", address: "192.168.1.42")]
                }, usb: { _ in [] }, log: { _ in }, makeBrowser: { NikonAppleTestBrowser() },
                schedule: { _, _ in {} })
            holder.source = source
            #expect(source.interfaces().isEmpty)

            let usbHolder = NikonAppleSourceHolder()
            let usbSource = NikonAppleDiscoverySources(
                interfaces: { [] },
                usb: { _ in
                    usbHolder.source?.close()
                    return [DiscoveredCamera(ip: "usb:borrowed", name: "Z_8", source: .usb)]
                }, log: { _ in }, makeBrowser: { NikonAppleTestBrowser() }, schedule: { _, _ in {} }
            )
            usbHolder.source = usbSource
            #expect(await usbSource.usbCameras(start: true) == [])
        }

        @Test func usbStartAdmissionAndJournalAreSuppliedHostValues() async {
            let rig = NikonAppleDiscoveryRig()
            let source = rig.makeSource()
            let usb = DiscoveredCamera(ip: "usb:borrowed", name: "Z_8", source: .usb)
            rig.setUSB([usb])
            #expect(rig.usbStarts.isEmpty)
            #expect(await source.usbCameras(start: false) == [usb])
            #expect(await source.usbCameras(start: true) == [usb])
            #expect(await source.usbCameras(start: false) == [usb])
            #expect(rig.usbStarts == [false, true, false])
            source.log("presence sweep hits=1 [192.168.1.7(Phone B ch=192.168.1.20)]")
            #expect(rig.logs == ["presence sweep hits=1 [192.168.1.7(Phone B ch=192.168.1.20)]"])
            source.close()
            #expect(await source.usbCameras(start: true) == [])
            #expect(rig.usbStarts == [false, true, false])
            // The immutable borrowed snapshot remains available to another owner; no USB stop,
            // close, transport adoption or PTP operation is part of the source's SDK contract.
            #expect(rig.usbSnapshot == [usb])
        }

        @Test func passiveDiscoveryWithUSBOffRetainsWirePurposeAndPresenceShield() async throws {
            let rig = NikonAppleDiscoveryRig()
            rig.setInterfaces([NikonLocalInterface(name: "en0", address: "192.168.1.42")])
            rig.setUSB([DiscoveredCamera(ip: "usb:borrowed", name: "Z_8", source: .usb)])
            let source = rig.makeSource()
            defer { source.close() }
            let dialer = FakeDialer()
            let rawPresence = Data([1, 2, 3])
            dialer.presences = [
                "192.168.1.7": NikonPresence(
                    deviceName: "Phone B", servedCamera: "192.168.1.20", line: rawPresence)
            ]
            dialer.alive = ["192.168.1.30"]
            dialer.openControlPorts = ["192.168.1.20"]
            dialer.cameras = ["192.168.1.20": "Z_9"]
            let discovery = NikonDiscovery(
                dialer: dialer, sources: source, now: { Date(timeIntervalSince1970: 0) })
            let passive = Task {
                try await discovery.discover(
                    .passive, guid: Data(repeating: 1, count: 16),
                    priorityHosts: ["192.168.1.10", "192.168.1.30", "usb:borrowed"],
                    browsesUSB: false,
                    onPresences: rig.acceptPresences)
            }
            try await waitForNikonAppleBrowse {
                rig.browsers.count == 1 && rig.browsers[0].starts == 1
            }
            rig.browsers[0].emit(
                .resolved(id: UUID(), name: "Z_8", addresses: [nikonAppleSockaddr("192.168.1.10")]))
            rig.clock.advance(by: .milliseconds(300))
            let rows = try await passive.value
            #expect(Set(rows.map(\.ip)) == ["192.168.1.10", "192.168.1.30"])
            #expect(rows.first { $0.ip == "192.168.1.10" }?.source == .bonjour)
            #expect(dialer.dials.filter { $0.purpose == .presence }.count == 254)
            #expect(dialer.controlDials.isEmpty && dialer.ptpInits == 0)
            #expect(rig.usbStarts.isEmpty)
            #expect(rig.presences["192.168.1.7"]?.line == rawPresence)
            #expect(rig.logs == ["presence sweep hits=1 [192.168.1.7(Phone B ch=192.168.1.20)]"])

            let active = Task {
                try await discovery.discover(
                    .active, guid: Data(repeating: 1, count: 16),
                    priorityHosts: ["192.168.1.20"], browsesUSB: false)
            }
            try await waitForNikonAppleBrowse {
                rig.browsers.count == 2 && rig.browsers[1].starts == 1
            }
            rig.clock.advance(by: .milliseconds(1_400))
            let activeRows = try await active.value
            #expect(
                !dialer.controlDials.contains("192.168.1.7")
                    && !dialer.controlDials.contains("192.168.1.20"))
            #expect(dialer.ptpInits == 0)
            #expect(dialer.dials.filter { $0.purpose == .presence }.count == 254)
            #expect(
                activeRows == [
                    DiscoveredCamera(
                        ip: "192.168.1.20", source: .heldByAnotherDevice,
                        heldByDeviceName: "Phone B")
                ])
            #expect(rig.usbStarts.isEmpty)
            #expect(
                rig.clock.scheduledDelays == [
                    .milliseconds(1_400), .milliseconds(300), .milliseconds(1_400),
                ])
        }

        @Test func admittedPassiveDiscoveryStartsThenReadsTheBorrowedUSBSource() async throws {
            let rig = NikonAppleDiscoveryRig()
            let usb = DiscoveredCamera(ip: "usb:borrowed", name: "Z_8", source: .usb)
            rig.setUSB([usb])
            let source = rig.makeSource()
            defer { source.close() }
            let dialer = FakeDialer()
            let discovery = NikonDiscovery(dialer: dialer, sources: source)
            let task = Task {
                try await discovery.discover(.passive, guid: Data(), browsesUSB: true)
            }
            try await waitForNikonAppleBrowse {
                rig.browsers.count == 1 && rig.browsers[0].starts == 1
            }
            #expect(rig.usbStarts == [true])
            rig.clock.advance(by: .milliseconds(1_400))
            #expect(try await task.value == [usb])
            #expect(rig.usbStarts == [true, false])
            #expect(dialer.controlDials.isEmpty && dialer.ptpInits == 0)
        }
    }

    private final class NikonAppleDiscoveryRig: @unchecked Sendable {
        // SAFETY: mutable fake facts and observations are all guarded by lock. SDK/test clock
        // helpers have their own locks; closures never read unguarded captured mutable variables.
        private let lock = NSLock()
        let clock = NikonAppleTestClock()
        private var driverValues: [NikonAppleTestBrowser] = []
        private var interfaces: [NikonLocalInterface] = []
        private var usb: [DiscoveredCamera] = []
        private var interfaceReadCount = 0
        private var starts: [Bool] = []
        private var journal: [String] = []
        private var presenceValues: [String: NikonPresence] = [:]

        var browsers: [NikonAppleTestBrowser] { lock.withLock { driverValues } }
        var interfaceReads: Int { lock.withLock { interfaceReadCount } }
        var usbStarts: [Bool] { lock.withLock { starts } }
        var usbSnapshot: [DiscoveredCamera] { lock.withLock { usb } }
        var logs: [String] { lock.withLock { journal } }
        var presences: [String: NikonPresence] { lock.withLock { presenceValues } }

        func setInterfaces(_ values: [NikonLocalInterface]) {
            lock.withLock { interfaces = values }
        }
        func setUSB(_ values: [DiscoveredCamera]) { lock.withLock { usb = values } }
        func acceptPresences(_ values: [String: NikonPresence]) async {
            lock.withLock { presenceValues = values }
        }

        func makeSource() -> NikonAppleDiscoverySources {
            NikonAppleDiscoverySources(
                interfaces: { [self] in
                    lock.withLock {
                        interfaceReadCount += 1
                        return interfaces
                    }
                },
                usb: { [self] start in
                    lock.withLock {
                        starts.append(start)
                        return usb
                    }
                },
                log: { [self] line in lock.withLock { journal.append(line) } },
                makeBrowser: { [self] in
                    let driver = NikonAppleTestBrowser()
                    lock.withLock { driverValues.append(driver) }
                    return driver
                }, schedule: clock.schedule)
        }
    }

    private final class NikonAppleTestBrowser: NikonBonjourBrowserDriver, @unchecked Sendable {
        // SAFETY: fake driver observations and the intentionally retained stale callback are locked.
        private let lock = NSLock()
        private var callback: (@Sendable (NikonBonjourBrowserEvent) -> Void)?
        private var retiredCallback: (@Sendable (NikonBonjourBrowserEvent) -> Void)?
        private var startCount = 0
        private var stopCount = 0
        private var stopped = false
        var starts: Int { lock.withLock { startCount } }
        var stops: Int { lock.withLock { stopCount } }

        func start(events: @escaping @Sendable (NikonBonjourBrowserEvent) -> Void) {
            lock.withLock {
                guard !stopped else { return }
                startCount += 1
                callback = events
                retiredCallback = events
            }
        }

        func stop() {
            lock.withLock {
                stopCount += 1
                stopped = true
                callback = nil
            }
        }

        func emit(_ event: NikonBonjourBrowserEvent) { lock.withLock { callback }?(event) }
        func emitLate(_ event: NikonBonjourBrowserEvent) {
            lock.withLock { retiredCallback }?(event)
        }
    }

    private final class NikonAppleTestClock: @unchecked Sendable {
        // SAFETY: manual time/deadlines are locked; due actions are invoked outside lock.
        private struct Entry: Sendable {
            let due: Duration
            let action: @Sendable () -> Void
        }
        private let lock = NSLock()
        private var now: Duration = .zero
        private var nextID = 0
        private var entries: [Int: Entry] = [:]
        private var delays: [Duration] = []
        var pendingCount: Int { lock.withLock { entries.count } }
        var scheduledDelays: [Duration] { lock.withLock { delays } }

        func schedule(_ delay: Duration, action: @escaping @Sendable () -> Void)
            -> @Sendable () -> Void
        {
            let id = lock.withLock { () -> Int in
                nextID += 1
                entries[nextID] = Entry(due: now + delay, action: action)
                delays.append(delay)
                return nextID
            }
            return { [weak self] in
                _ = self?.lock.withLock { self?.entries.removeValue(forKey: id) }
            }
        }

        func advance(by duration: Duration) {
            lock.withLock { now += duration }
            while let action = lock.withLock({ () -> (@Sendable () -> Void)? in
                guard
                    let next = entries.filter({ $0.value.due <= now }).min(by: {
                        $0.value.due == $1.value.due ? $0.key < $1.key : $0.value.due < $1.value.due
                    })
                else { return nil }
                entries.removeValue(forKey: next.key)
                return next.value.action
            }) { action() }
        }
    }

    private final class NikonAppleSourceHolder: @unchecked Sendable {
        // SAFETY: a weak source avoids a test-only capture cycle; reads and replacement are locked.
        private let lock = NSLock()
        private weak var stored: NikonAppleDiscoverySources?
        var source: NikonAppleDiscoverySources? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private func waitForNikonAppleBrowse(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<10_000 where !condition() { await Task.yield() }
        try #require(condition(), "Controllable Apple Bonjour driver did not start")
    }

    func nikonAppleSockaddr(_ host: String) -> Data {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        precondition(host.withCString { inet_pton(AF_INET, $0, &address.sin_addr) } == 1)
        return withUnsafeBytes(of: &address) { Data($0) }
    }

    func nikonAppleIPv6Sockaddr() -> Data {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        precondition("fd00::1".withCString { inet_pton(AF_INET6, $0, &address.sin6_addr) } == 1)
        return withUnsafeBytes(of: &address) { Data($0) }
    }
#endif
