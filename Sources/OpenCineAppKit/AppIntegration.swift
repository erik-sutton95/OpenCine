import OpenCineCore
import SwiftUI

/// One integration as the app lists it, with the typed slots for what only it shows. Shared code
/// never asks which integration an entry is; it renders the slots attached to the entry.
public struct AppIntegration {
    public var integration: any CameraIntegration
    public var slots: IntegrationSlots

    public init(_ integration: any CameraIntegration, slots: IntegrationSlots = IntegrationSlots()) {
        self.integration = integration
        self.slots = slots
    }
}

/// Integration-only views the app composes into the shared screens (extension level 3).
public struct IntegrationSlots {
    /// Pair-page content for steps only this integration has, shown while choosing a camera.
    public var pairing: (() -> AnyView)?
    /// Builds a route to add to a saved camera; `nil` cancels.
    public var addRoute: ((SavedCamera, _ done: @escaping (RouteDraft?) -> Void) -> AnyView)?
    /// Typed setup capabilities and actions, preferred by the shared screen when present.
    public var addSetup:
        (@MainActor (SavedCamera, _ done: @escaping (RouteDraft?) -> Void) -> AddSetupFlow)?
    /// Renders an integration prompt; `nil` falls back to its text.
    public var prompt: ((any IntegrationPrompt) -> AnyView?)?
    /// The app's words for a nearby camera's card and pair-page row; `nil` keeps the shell's.
    public var nearbyCard: ((NearbyCamera) -> NearbyCardCopy)?

    public init(
        pairing: (() -> AnyView)? = nil,
        addRoute: ((SavedCamera, _ done: @escaping (RouteDraft?) -> Void) -> AnyView)? = nil,
        prompt: ((any IntegrationPrompt) -> AnyView?)? = nil,
        nearbyCard: ((NearbyCamera) -> NearbyCardCopy)? = nil,
        addSetup: (
            @MainActor (SavedCamera, _ done: @escaping (RouteDraft?) -> Void) -> AddSetupFlow
        )? = nil
    ) {
        self.pairing = pairing
        self.addRoute = addRoute
        self.addSetup = addSetup
        self.prompt = prompt
        self.nearbyCard = nearbyCard
    }
}

/// A nearby camera's name, subtitle and status as the app words them (a camera held by another
/// device keeps the shell's status).
public struct NearbyCardCopy: Equatable, Sendable {
    public var name: String
    public var subtitle: String
    public var status: String

    public init(name: String, subtitle: String, status: String) {
        self.name = name
        self.subtitle = subtitle
        self.status = status
    }
}
