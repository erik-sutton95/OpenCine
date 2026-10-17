import OpenCineAppKit
import OpenCineCameraVocabulary

extension ControlCapabilities {
    /// Display preferences for the camera's zoom and gimbal controls and color readout.
    /// Other sections can be filled by host services; their current data and connection gates
    /// belong to the live monitor, not to camera support.
    public var displaySections: Set<MonitorDisplayChrome.Section> {
        var sections = Set(MonitorDisplayChrome.Section.allCases)
        if !zoom.isOffered { sections.remove(.zoomChip) }
        if !gimbal.isOffered { sections.remove(.gimbalStick) }
        if !codecColor.isShown || codecColor.offer?.showsColor == false { sections.remove(.color) }
        return sections
    }
}
