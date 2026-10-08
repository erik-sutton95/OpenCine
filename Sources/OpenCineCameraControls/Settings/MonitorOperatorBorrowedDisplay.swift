#if os(iOS)
import MonitorUI
import SwiftUI

/// Borrows the actual stored layout meanings without creating another preferences namespace.
@MainActor
public struct MonitorOperatorBorrowedDisplay {
    public let layoutHelp: String
    public let choices: [MonitorDisplayChoice]
    public let selection: Binding<String>
    public let expandedSection: Binding<String?>
    public let sections: [MonitorDisplaySection]
    public let order: MonitorDisplayOrderGroup
    public let returnedFromEditor: () -> Void

    public init(layoutHelp: String, choices: [MonitorDisplayChoice], selection: Binding<String>,
        expandedSection: Binding<String?>, sections: [MonitorDisplaySection], order: MonitorDisplayOrderGroup,
        returnedFromEditor: @escaping () -> Void = {}) {
        self.layoutHelp = layoutHelp; self.choices = choices; self.selection = selection
        self.expandedSection = expandedSection; self.sections = sections; self.order = order
        self.returnedFromEditor = returnedFromEditor
    }
}
#endif
