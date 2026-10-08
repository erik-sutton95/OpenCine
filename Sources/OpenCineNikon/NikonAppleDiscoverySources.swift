#if canImport(Darwin) && !os(watchOS)
    import Foundation

    /// Instance-owned Apple discovery sources for NikonDiscovery. Bonjour windows are passive,
    /// independently owned and cancellable. USB starts only when NikonDiscovery admits it; the host
    /// supplies the existing browser that also owns its transport/prewarm and permission lifecycle.
    public final class NikonAppleDiscoverySources: NikonDiscoverySources, @unchecked Sendable {
        // SAFETY: dependencies are immutable Sendable values. The close flag and owned windows are
        // guarded by lock; source-read callbacks and continuations run outside that lock.
        private let readInterfaces: @Sendable () -> [NikonLocalInterface]
        private let readUSB: @Sendable (Bool) -> [DiscoveredCamera]
        private let writeLog: @Sendable (String) -> Void
        private let makeBrowser: @Sendable () -> any NikonBonjourBrowserDriver
        private let schedule: NikonBonjourSchedule
        private let lock = NSLock()
        private var closed = false
        private var windows: [UUID: NikonBonjourWindow] = [:]

        /// Network-only sources, for a host without ImageCaptureCore camera discovery.
        public convenience init(log: @escaping @Sendable (String) -> Void = { _ in }) {
            self.init(
                interfaces: NikonAppleNetworkInterfaces.snapshot, usb: { _ in [] }, log: log,
                makeBrowser: { NikonNetServiceBrowserDriver() },
                schedule: NikonBonjourScheduling.schedule)
        }

        #if os(iOS)
            /// Uses the host's already-owned USB browser. Constructing the source does not start the
            /// browser or request permission. Closing a source never closes a borrowed USB session.
            public convenience init(
                usbBrowser: USBCameraDeviceBrowser,
                log: @escaping @Sendable (String) -> Void = { _ in }
            ) {
                self.init(
                    interfaces: NikonAppleNetworkInterfaces.snapshot,
                    usb: { start in
                        if start { usbBrowser.start() }
                        return usbBrowser.attachedCameras()
                    }, log: log, makeBrowser: { NikonNetServiceBrowserDriver() },
                    schedule: NikonBonjourScheduling.schedule)
            }
        #endif

        init(
            interfaces: @escaping @Sendable () -> [NikonLocalInterface],
            usb: @escaping @Sendable (Bool) -> [DiscoveredCamera],
            log: @escaping @Sendable (String) -> Void,
            makeBrowser: @escaping @Sendable () -> any NikonBonjourBrowserDriver,
            schedule: @escaping NikonBonjourSchedule
        ) {
            readInterfaces = interfaces
            readUSB = usb
            writeLog = log
            self.makeBrowser = makeBrowser
            self.schedule = schedule
        }

        deinit { close() }

        /// A fresh OS snapshot for each pass; no retained subnet or interface cache.
        public func interfaces() -> [NikonLocalInterface] {
            guard lock.withLock({ !closed }) else { return [] }
            let interfaces = readInterfaces()
            return lock.withLock { closed ? [] : interfaces }
        }

        /// One `_ptp._tcp.` / `local.` browse. Resolves each found service for at most one second;
        /// the first valid resolution retains the original 300ms sibling-settle window.
        public func bonjour(timeout: Duration) async -> [DiscoveredCamera] {
            let id = UUID()
            let window = lock.withLock { () -> NikonBonjourWindow? in
                guard !closed else { return nil }
                let window = NikonBonjourWindow(driver: makeBrowser(), schedule: schedule)
                windows[id] = window
                return window
            }
            guard let window else { return [] }
            defer { _ = lock.withLock { windows.removeValue(forKey: id) } }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { window.start(timeout: timeout, continuation: $0) }
            } onCancel: {
                window.cancel()
            }
        }

        /// Reads the supplied browser only when this source is still current. The start flag is
        /// passed through unchanged; `false` never requests camera-control authorization.
        public func usbCameras(start: Bool) async -> [DiscoveredCamera] {
            guard !Task.isCancelled, lock.withLock({ !closed }) else { return [] }
            let cameras = readUSB(start)
            guard !Task.isCancelled else { return [] }
            return lock.withLock { closed ? [] : cameras }
        }

        /// Uses the host's existing journal without choosing an app or process-wide logger.
        public func log(_ line: String) { writeLog(line) }

        /// Retires all owned Bonjour windows and refuses later source reads. Does not stop a host's
        /// USB browser, close a camera, send PTP bytes or cancel another source instance's browse.
        public func close() {
            let retiring = lock.withLock { () -> [NikonBonjourWindow] in
                guard !closed else { return [] }
                closed = true
                let current = Array(windows.values)
                windows.removeAll()
                return current
            }
            for window in retiring { window.cancel() }
        }
    }

    /// Internal SDK seam: the shipping NetService driver and controllable test driver use the
    /// same window owner. Names/address bytes are observations; no camera-control action exists here.
    protocol NikonBonjourBrowserDriver: AnyObject, Sendable {
        func start(events: @escaping @Sendable (NikonBonjourBrowserEvent) -> Void)
        func stop()
    }

    enum NikonBonjourBrowserEvent: Sendable {
        case resolved(id: UUID, name: String, addresses: [Data])
        case removed(id: UUID)
        case failed
    }

    typealias NikonBonjourSchedule =
        @Sendable (Duration, @escaping @Sendable () -> Void) -> @Sendable () -> Void

    private final class NikonBonjourWindow: @unchecked Sendable {
        // SAFETY: all state is behind lock. Driver/timer/continuation actions run outside the lock.
        private let driver: any NikonBonjourBrowserDriver
        private let schedule: NikonBonjourSchedule
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[DiscoveredCamera], Never>?
        private var completed: [DiscoveredCamera]?
        private var rows: [UUID: [DiscoveredCamera]] = [:]
        private var order: [UUID] = []
        private var hasFirstResolution = false
        private var deadlines: [@Sendable () -> Void] = []

        init(driver: any NikonBonjourBrowserDriver, schedule: @escaping NikonBonjourSchedule) {
            self.driver = driver
            self.schedule = schedule
        }

        func start(timeout: Duration, continuation: CheckedContinuation<[DiscoveredCamera], Never>)
        {
            let alreadyCompleted = lock.withLock { () -> [DiscoveredCamera]? in
                if let completed { return completed }
                self.continuation = continuation
                return nil
            }
            if let alreadyCompleted {
                continuation.resume(returning: alreadyCompleted)
                return
            }
            addDeadline(schedule(timeout) { [weak self] in self?.finish(cancelled: false) })
            guard lock.withLock({ completed == nil }) else { return }
            driver.start { [weak self] event in self?.receive(event) }
        }

        func cancel() { finish(cancelled: true) }

        private func receive(_ event: NikonBonjourBrowserEvent) {
            switch event {
            case .resolved(let id, let name, let addresses):
                let cameras = addresses.compactMap(NikonAppleNetworkInterfaces.ipv4Address).map {
                    DiscoveredCamera(ip: $0, name: name, source: .bonjour)
                }
                let first = lock.withLock { () -> Bool in
                    guard completed == nil else { return false }
                    guard !cameras.isEmpty else {
                        rows.removeValue(forKey: id)
                        order.removeAll { $0 == id }
                        return false
                    }
                    if rows[id] == nil { order.append(id) }
                    rows[id] = cameras
                    guard !hasFirstResolution else { return false }
                    hasFirstResolution = true
                    return true
                }
                if first {
                    addDeadline(
                        schedule(.milliseconds(300)) { [weak self] in self?.finish(cancelled: false)
                        })
                }
            case .removed(let id):
                lock.withLock {
                    guard completed == nil else { return }
                    rows.removeValue(forKey: id)
                    order.removeAll { $0 == id }
                }
            case .failed:
                finish(cancelled: false)
            }
        }

        private func addDeadline(_ cancel: @escaping @Sendable () -> Void) {
            let cancelNow = lock.withLock { () -> Bool in
                guard completed == nil else { return true }
                deadlines.append(cancel)
                return false
            }
            if cancelNow { cancel() }
        }

        private func finish(cancelled: Bool) {
            let result = lock.withLock {
                () -> (
                    [DiscoveredCamera], CheckedContinuation<[DiscoveredCamera], Never>?,
                    [@Sendable () -> Void]
                )? in
                guard completed == nil else { return nil }
                let output = cancelled ? [] : order.flatMap { rows[$0] ?? [] }
                completed = output
                let waiter = continuation
                continuation = nil
                let cancellations = deadlines
                deadlines.removeAll()
                rows.removeAll()
                order.removeAll()
                return (output, waiter, cancellations)
            }
            guard let (output, waiter, cancellations) = result else { return }
            for cancel in cancellations { cancel() }
            driver.stop()
            waiter?.resume(returning: output)
        }
    }

    private enum NikonBonjourScheduling {
        static func schedule(_ delay: Duration, action: @escaping @Sendable () -> Void)
            -> @Sendable () -> Void
        {
            let item = NikonBonjourScheduledWork(action: action)
            let seconds =
                Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds), execute: item.work)
            return { item.cancel() }
        }
    }

    private final class NikonBonjourScheduledWork: @unchecked Sendable {
        // SAFETY: DispatchWorkItem's cancellation is thread-safe; the value is immutable.
        let work: DispatchWorkItem
        init(action: @escaping @Sendable () -> Void) { work = DispatchWorkItem(block: action) }
        func cancel() { work.cancel() }
    }

    private final class NikonNetServiceBrowserDriver: NSObject, NikonBonjourBrowserDriver,
        NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable
    {
        // SAFETY: SDK operations run on the main run loop. Event/state reads are guarded by lock;
        // source callbacks are called outside the lock, and a stopped driver cannot admit new work.
        private let browser = NetServiceBrowser()
        private let lock = NSLock()
        private var events: (@Sendable (NikonBonjourBrowserEvent) -> Void)?
        private var services: [ObjectIdentifier: (UUID, NetService)] = [:]
        private var stopped = false

        func start(events: @escaping @Sendable (NikonBonjourBrowserEvent) -> Void) {
            let admitted = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                self.events = events
                return true
            }
            guard admitted else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lock.withLock({ !self.stopped }) else { return }
                self.browser.delegate = self
                self.browser.searchForServices(ofType: "_ptp._tcp.", inDomain: "local.")
            }
        }

        func stop() {
            let admitted = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                stopped = true
                events = nil
                return true
            }
            guard admitted else { return }
            DispatchQueue.main.async { [self] in
                browser.stop()
                browser.delegate = nil
                let current = lock.withLock { () -> [NetService] in
                    let current = services.values.map { $0.1 }
                    services.removeAll()
                    return current
                }
                for service in current {
                    service.stop()
                    service.delegate = nil
                }
            }
        }

        func netServiceBrowser(
            _ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool
        ) {
            let admitted = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                if services[ObjectIdentifier(service)] == nil {
                    services[ObjectIdentifier(service)] = (UUID(), service)
                }
                return true
            }
            guard admitted else { return }
            service.delegate = self
            service.resolve(withTimeout: 1.0)
        }

        func netServiceDidResolveAddress(_ sender: NetService) {
            let observation = lock.withLock {
                () -> (UUID, @Sendable (NikonBonjourBrowserEvent) -> Void)? in
                guard !stopped, let (id, _) = services[ObjectIdentifier(sender)], let events else {
                    return nil
                }
                return (id, events)
            }
            if let (id, events) = observation {
                events(.resolved(id: id, name: sender.name, addresses: sender.addresses ?? []))
            }
        }

        func netServiceBrowser(
            _ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool
        ) {
            let observation = lock.withLock {
                () -> (UUID, @Sendable (NikonBonjourBrowserEvent) -> Void)? in
                guard !stopped,
                    let (id, _) = services.removeValue(forKey: ObjectIdentifier(service)),
                    let events
                else { return nil }
                return (id, events)
            }
            service.stop()
            service.delegate = nil
            if let (id, events) = observation { events(.removed(id: id)) }
        }

        func netServiceBrowser(
            _ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]
        ) {
            let callback = lock.withLock { stopped ? nil : events }
            callback?(.failed)
        }
    }
#endif
