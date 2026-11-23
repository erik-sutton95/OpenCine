import Foundation

/// Where the zoom control sat when it was a disc. The ruler always sits on the trailing edge;
/// the value is kept so existing callers still compile.
public enum MonitorZoomAttachment: Equatable, Sendable {
    case trailing
    case bottom
}
