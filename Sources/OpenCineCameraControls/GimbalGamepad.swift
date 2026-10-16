#if os(iOS)
    import CoreHaptics
    import GameController
    import OpenCineCameraVocabulary
    import UIKit

    /// What the gamepad drives beyond the stick: zoom, the mapped buttons and the connection note.
    @MainActor
    public protocol GimbalGamepadHost: GimbalStickHost {
        var gamepadConnected: Bool { get set }
        /// The operator holds a pad stick.
        var gimbalPadHeld: Bool { get set }
        /// Live, controllable and free of locks, media browsing, cover panels and chrome editing.
        var gamepadCanDrive: Bool { get }
        var gimbalGamepadStick: GamepadGimbalStick { get }
        var controlNote: String? { get set }
        func handleGamepadAction(_ action: GamepadOperatorAction)
        var zoomReadout: Double { get }
        var zoomMax: Double { get }
        var zoomColorHopPending: Bool { get }
        func updateZoomPinch(magnification: Double)
        func endZoomPinch()
    }

    /// Live-monitor gamepad: discussion #159 map. Selected stick gimbal, L2/R2 analog
    /// zoom, L1/R1 zoom-chip, Cross records, Circle recenters, Square 180,
    /// Triangle tracks, D-pad ISO/shutter.
    @MainActor
    public final class GimbalGamepadBridge<Host: GimbalGamepadHost> {
        private weak var model: Host?
        private var observers: [NSObjectProtocol] = []
        private var padActive = false
        // Compared only while the pad drives, and the first poll sets it.
        private var lastStick = GamepadGimbalStick.parse(nil)
        private var zoomActive = false
        private var zoomAnchor = 1.0
        private var zoomCurrent = 1.0
        private var zoomY = 0.0
        private var zoomPump: Task<Void, Never>?
        private var aDown = false
        private var bDown = false
        private var xDown = false
        private var yDown = false
        private var l1Down = false
        private var r1Down = false
        private var dpadUp = false
        private var dpadDown = false
        private var dpadLeft = false
        private var dpadRight = false
        private var haptics: GamepadLimitHaptics?
        /// The pad whose changes the handler reports; read on the main actor only.
        private weak var boundPad: GCExtendedGamepad?

        public init() {}

        public func attach(model: Host) {
            detach()
            self.model = model
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: .GCControllerDidConnect, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.bindControllers() }
                },
                center.addObserver(
                    forName: .GCControllerDidDisconnect, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.bindControllers() }
                },
            ]
            bindControllers()
        }

        public func detach() {
            noteBlocked()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            for controller in GCController.controllers() {
                controller.extendedGamepad?.valueChangedHandler = nil
            }
            boundPad = nil
            haptics?.detach()
            haptics = nil
            model?.gamepadConnected = false
            model = nil
            aDown = false
            bDown = false
            xDown = false
            yDown = false
            l1Down = false
            r1Down = false
            dpadUp = false
            dpadDown = false
            dpadLeft = false
            dpadRight = false
            zoomActive = false
        }

        public func noteBlocked() {
            if padActive {
                padActive = false
                model?.gimbalPadHeld = false
                model?.endGimbalStick()
            }
            stopZoomPump()
            if zoomActive {
                zoomActive = false
                model?.endZoomPinch()
            }
        }

        public func pulseLimit(
            _ contact: GimbalLimitWatch.Contact, panSign: Double, tiltSign: Double, enabled: Bool
        ) {
            guard enabled, !contact.isEmpty else { return }
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            haptics?.pulse(contact: contact, panSign: panSign, tiltSign: tiltSign)
        }

        private var canDrive: Bool { model?.gamepadCanDrive ?? false }

        private func bindControllers() {
            let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil })
            let gamepad = controller?.extendedGamepad
            haptics?.detach()
            haptics = controller.map(GamepadLimitHaptics.init)
            for item in GCController.controllers() {
                item.extendedGamepad?.valueChangedHandler = nil
            }
            let connected = gamepad != nil
            if connected != model?.gamepadConnected {
                model?.gamepadConnected = connected
                if let model {
                    model.controlNote = connected ? "Gamepad connected" : "Gamepad disconnected"
                }
            }
            boundPad = gamepad
            guard let gamepad else {
                noteBlocked()
                return
            }
            // Pin the callback queue instead of relying on GameController's default, and hand it a
            // handler without actor isolation (GimbalGamepadCallback): the PI-3P / PI-3N crash class.
            controller?.handlerQueue = .main
            gamepad.valueChangedHandler = GimbalGamepadCallback.valueChanged { [weak self] in
                self?.handleBoundPad()
            }
            handle(gamepad)
        }

        private func handleBoundPad() {
            guard let boundPad else { return }
            handle(boundPad)
        }

        private func edge(
            _ down: Bool, was: inout Bool, action: GamepadOperatorAction, on model: Host
        ) {
            if down, !was { model.handleGamepadAction(action) }
            was = down
        }

        private func handle(_ pad: GCExtendedGamepad) {
            guard canDrive, let model else {
                noteBlocked()
                aDown = pad.buttonA.isPressed
                bDown = pad.buttonB.isPressed
                xDown = pad.buttonX.isPressed
                yDown = pad.buttonY.isPressed
                l1Down = pad.leftShoulder.isPressed
                r1Down = pad.rightShoulder.isPressed
                dpadUp = pad.dpad.up.isPressed
                dpadDown = pad.dpad.down.isPressed
                dpadLeft = pad.dpad.left.isPressed
                dpadRight = pad.dpad.right.isPressed
                return
            }
            edge(pad.buttonA.isPressed, was: &aDown, action: GamepadOperatorMap.face(.a), on: model)
            edge(pad.buttonB.isPressed, was: &bDown, action: GamepadOperatorMap.face(.b), on: model)
            edge(pad.buttonX.isPressed, was: &xDown, action: GamepadOperatorMap.face(.x), on: model)
            edge(pad.buttonY.isPressed, was: &yDown, action: GamepadOperatorMap.face(.y), on: model)
            edge(
                pad.leftShoulder.isPressed, was: &l1Down,
                action: GamepadOperatorMap.shoulder(.left),
                on: model)
            edge(
                pad.rightShoulder.isPressed, was: &r1Down,
                action: GamepadOperatorMap.shoulder(.right),
                on: model)
            edge(
                pad.dpad.up.isPressed, was: &dpadUp, action: GamepadOperatorMap.dpad(.up), on: model
            )
            edge(
                pad.dpad.down.isPressed, was: &dpadDown, action: GamepadOperatorMap.dpad(.down),
                on: model)
            edge(
                pad.dpad.left.isPressed, was: &dpadLeft, action: GamepadOperatorMap.dpad(.left),
                on: model)
            edge(
                pad.dpad.right.isPressed, was: &dpadRight, action: GamepadOperatorMap.dpad(.right),
                on: model)

            let stick = model.gimbalGamepadStick
            if GamepadGimbalStick.restHeldMotion(from: lastStick, to: stick, driving: padActive) {
                padActive = false
                model.gimbalPadHeld = false
                model.endGimbalStick()
            }
            lastStick = stick
            let axes = stick.axes(
                leftX: Double(pad.leftThumbstick.xAxis.value),
                leftY: Double(pad.leftThumbstick.yAxis.value),
                rightX: Double(pad.rightThumbstick.xAxis.value),
                rightY: Double(pad.rightThumbstick.yAxis.value))
            let x = axes.x
            let y = axes.y
            let rest =
                GimbalStick.analogCurve(x) == 0 && GimbalStick.analogCurve(y) == 0
            if rest {
                if padActive {
                    padActive = false
                    model.gimbalPadHeld = false
                    model.endGimbalStick()
                }
            } else {
                padActive = true
                // Per controller poll: AppRoot observes gimbalAnalogHeld, so an
                // unchanged write re-evaluated the root body at the poll rate.
                if !model.gimbalPadHeld { model.gimbalPadHeld = true }
                model.updateGimbalStick(x: x, y: y, mapping: .defaults)
            }

            zoomY = CamFov.triggerZoomAxis(
                left: Double(pad.leftTrigger.value),
                right: Double(pad.rightTrigger.value))
            if GimbalStick.linearThrow(zoomY) == 0 {
                stopZoomPump()
                if zoomActive {
                    zoomActive = false
                    model.endZoomPinch()
                }
            } else {
                if !zoomActive {
                    zoomAnchor = model.zoomReadout
                    zoomCurrent = zoomAnchor
                    zoomActive = true
                }
                startZoomPump()
            }
        }

        private func startZoomPump() {
            guard zoomPump == nil else { return }
            zoomPump = Task { @MainActor [weak self] in
                let delay = Duration.milliseconds(
                    Int((CamFov.zoomStepInterval * 1_000).rounded(.up)))
                self?.applyZoom(dt: CamFov.zoomStepInterval)
                var last = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(for: delay)
                    guard let self, !Task.isCancelled else { return }
                    let now = Date()
                    let dt = now.timeIntervalSince(last)
                    last = now
                    self.applyZoom(dt: dt)
                }
            }
        }

        private func stopZoomPump() {
            zoomPump?.cancel()
            zoomPump = nil
        }

        private func applyZoom(dt: TimeInterval) {
            guard zoomActive, let model, canDrive else {
                stopZoomPump()
                if zoomActive {
                    zoomActive = false
                    model?.endZoomPinch()
                }
                return
            }
            if model.zoomColorHopPending {
                let mag = zoomCurrent / max(zoomAnchor, CamFov.minFactor)
                model.updateZoomPinch(magnification: mag)
                return
            }
            zoomCurrent = CamFov.zoomStep(
                current: zoomCurrent, y: zoomY, dt: dt, max: model.zoomMax)
            let mag = zoomCurrent / max(zoomAnchor, CamFov.minFactor)
            model.updateZoomPinch(magnification: mag)
        }
    }

    /// GameController runs `valueChangedHandler` on the controller's `handlerQueue`. A closure
    /// formed inside main-actor code is main-actor isolated in Swift 6, and its entry check traps
    /// when any other queue calls it (PI-3P, PI-3N). This handler is formed outside the actor: it
    /// runs `body` at once on the main thread (the pinned queue) and hops there from any other.
    enum GimbalGamepadCallback {
        nonisolated static func valueChanged(
            _ body: @escaping @MainActor @Sendable () -> Void
        ) -> GCExtendedGamepadValueChangedHandler {
            { _, _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { body() }
                } else {
                    Task { @MainActor in body() }
                }
            }
        }
    }

    @MainActor
    private final class GamepadLimitHaptics {
        private var defaultEngine: CHHapticEngine?
        private var leftEngine: CHHapticEngine?
        private var rightEngine: CHHapticEngine?

        init(controller: GCController) {
            guard let device = controller.haptics else { return }
            defaultEngine = start(device.createEngine(withLocality: .default))
            leftEngine = start(device.createEngine(withLocality: .leftHandle))
            rightEngine = start(device.createEngine(withLocality: .rightHandle))
        }

        public func detach() {
            defaultEngine?.stop(completionHandler: nil)
            leftEngine?.stop(completionHandler: nil)
            rightEngine?.stop(completionHandler: nil)
            defaultEngine = nil
            leftEngine = nil
            rightEngine = nil
        }

        func pulse(contact: GimbalLimitWatch.Contact, panSign: Double, tiltSign: Double) {
            if contact.contains(.pan) {
                if panSign < 0 {
                    play(on: leftEngine ?? defaultEngine)
                } else {
                    play(on: rightEngine ?? defaultEngine)
                }
            }
            if contact.contains(.tilt) {
                play(on: defaultEngine)
            }
        }

        private func start(_ engine: CHHapticEngine?) -> CHHapticEngine? {
            guard let engine else { return nil }
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            do {
                try engine.start()
                return engine
            } catch {
                return nil
            }
        }

        private func play(on engine: CHHapticEngine?) {
            guard let engine else { return }
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.85),
                ], relativeTime: 0)
            do {
                try engine.start()
                let player = try engine.makePlayer(
                    with: CHHapticPattern(events: [event], parameters: []))
                try player.start(atTime: 0)
            } catch {}
        }
    }
#endif
