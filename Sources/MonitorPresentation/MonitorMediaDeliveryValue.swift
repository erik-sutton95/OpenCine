import Foundation

/// A delivery screen projects host values and returns typed actions. It owns no files,
/// credentials, network route, export task or destination implementation.
public struct MonitorMediaDeliveryValue: Equatable, Sendable {
    public enum Step: Equatable, Sendable { case destination, options }
    public enum Option: Equatable, Sendable {
        case convertLog, bakeLUT, bakeExposure, includeMetadata, reupload
    }
    public enum Selection: Equatable, Sendable { case outputCurve, format, postExport, project }
    public enum Action: Equatable, Sendable {
        case close, back, begin, hopToInternet, retryProjects, createProject
        case destination(String)
        case option(Option, Bool)
        case selection(Selection, String)
    }
    public struct Choice: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }
    public struct Notice: Equatable, Sendable {
        public let text: String
        public let accented: Bool
        public init(_ text: String, accented: Bool = false) {
            self.text = text
            self.accented = accented
        }
    }
    public struct Destination: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let subtitle: String
        public let enabled: Bool
        public init(id: String, title: String, subtitle: String, enabled: Bool) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.enabled = enabled
        }
    }
    public struct Toggle: Equatable, Sendable {
        public let title: String
        public let help: String
        public let isOn: Bool
        public let enabled: Bool
        public init(_ title: String, help: String, isOn: Bool, enabled: Bool = true) {
            self.title = title
            self.help = help
            self.isOn = isOn
            self.enabled = enabled
        }
    }
    public struct Choices: Equatable, Sendable {
        public let title: String
        public let help: String?
        public let options: [Choice]
        public let selectedID: String?
        public init(_ title: String, help: String? = nil, options: [Choice], selectedID: String?) {
            self.title = title
            self.help = help
            self.options = options
            self.selectedID = selectedID
        }
    }
    public struct Export: Equatable, Sendable {
        public let filename: String?
        public let convertLog: Toggle?
        public let outputCurve: Choices?
        public let bakeLUT: Toggle?
        public let bakeExposure: Toggle?
        public let format: Choices?
        public let includeMetadata: Toggle?
        public let reupload: Toggle?
        public init(
            filename: String? = nil, convertLog: Toggle? = nil, outputCurve: Choices? = nil,
            bakeLUT: Toggle? = nil, bakeExposure: Toggle? = nil, format: Choices? = nil,
            includeMetadata: Toggle? = nil, reupload: Toggle? = nil
        ) {
            self.filename = filename
            self.convertLog = convertLog
            self.outputCurve = outputCurve
            self.bakeLUT = bakeLUT
            self.bakeExposure = bakeExposure
            self.format = format
            self.includeMetadata = includeMetadata
            self.reupload = reupload
        }
    }
    /// An internet-dependent destination supplies either a route gate or project facts.
    /// The host performs every route, auth and project operation returned by the screen.
    public enum Service: Equatable, Sendable {
        case internetGate(
            heading: String, message: String, busy: Bool, busyTitle: String = "Switching networks…")
        case projects(
            heading: String, help: String, signInNotice: String?, loading: Bool, error: String?,
            choices: [Choice]?, selectedID: String?, allowsCreation: Bool = true,
            selectedLabel: String? = nil)

        /// A listed ID takes precedence; a host can supply a known selection outside its choices.
        public var selectedProjectLabel: String? {
            guard
                case .projects(
                    _, _, _, _, _, let choices, let selectedID, _, let selectedLabel
                ) = self
            else { return nil }
            return choices?.first { $0.id == selectedID }?.label ?? selectedLabel
        }

    }
    public struct Footer: Equatable, Sendable {
        public let summary: String?
        public let postExport: Choices?
        public let actionTitle: String
        public let enabled: Bool
        public init(
            summary: String? = nil, postExport: Choices? = nil,
            actionTitle: String, enabled: Bool
        ) {
            self.summary = summary
            self.postExport = postExport
            self.actionTitle = actionTitle
            self.enabled = enabled
        }
    }
    public let step: Step
    public let title: String
    public let selectionLabel: String
    public let notices: [Notice]
    public let destinations: [Destination]
    public let upcoming: [String]
    public let service: Service?
    public let export: Export?
    public let footer: Footer?
    public let status: String?
    public init(
        step: Step, title: String = "Share", selectionLabel: String,
        notices: [Notice] = [], destinations: [Destination] = [], upcoming: [String] = [],
        service: Service? = nil, export: Export? = nil, footer: Footer? = nil, status: String? = nil
    ) {
        self.step = step
        self.title = title
        self.selectionLabel = selectionLabel
        self.notices = notices
        self.destinations = destinations
        self.upcoming = upcoming
        self.service = service
        self.export = export
        self.footer = footer
        self.status = status
    }
}

/// Progress copy and batch weighting belong to the delivery host. The screen displays them.
public struct MonitorMediaDeliveryProgressValue: Equatable, Sendable {
    public let status: String
    public let batch: String?
    public let fraction: Double
    public let preparing: Bool
    public let showsProgress: Bool
    public init(
        status: String, batch: String? = nil, fraction: Double, preparing: Bool,
        showsProgress: Bool? = nil
    ) {
        self.status = status
        self.batch = batch
        self.fraction = fraction
        self.preparing = preparing
        self.showsProgress = showsProgress ?? !preparing
    }
}
