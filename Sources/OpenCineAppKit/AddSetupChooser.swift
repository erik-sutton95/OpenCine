import OpenCineCore

/// One host-advertised setup capability, with the words for its current availability.
public struct AddSetupOption: Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: RouteKind
    public var title: String
    public var detail: String
    public var actionTitle: String
    public var enabled: Bool

    public init(
        id: String, kind: RouteKind, title: String, detail: String, actionTitle: String,
        enabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.enabled = enabled
    }
}

/// An optional host capability notice with an explicit action, such as permission for network names.
public struct AddSetupNotice: Equatable, Sendable {
    public var id: String
    public var message: String
    public var actionTitle: String

    public init(id: String, message: String, actionTitle: String) {
        self.id = id
        self.message = message
        self.actionTitle = actionTitle
    }
}

/// The shared setup chooser consumes capabilities and copy, never an app or manufacturer.
public struct AddSetupChooser: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var options: [AddSetupOption]
    public var footer: String?
    public var identifierPrefix: String
    public var notice: AddSetupNotice?

    public init(
        title: String, detail: String, options: [AddSetupOption], footer: String? = nil,
        identifierPrefix: String = "addSetup", notice: AddSetupNotice? = nil
    ) {
        self.title = title
        self.detail = detail
        self.options = options
        self.footer = footer
        self.identifierPrefix = identifierPrefix
        self.notice = notice
    }

    /// Dispatches only a currently advertised, enabled option to its host.
    @discardableResult
    public func select(_ id: String, onSelect: (AddSetupOption) -> Void) -> Bool {
        guard let option = options.first(where: { $0.id == id && $0.enabled }) else { return false }
        onSelect(option)
        return true
    }
}
