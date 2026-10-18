#if os(iOS)
import LinkPresentation
import OpenCineAppKit
import OpenCineMedia
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension View {
    /// The one share presenter of an app (A2-52). Install it once at the app root: it presents
    /// the delivery's share sheet from the topmost presented controller, so the sheet appears
    /// above any gallery, player or photo cover and also when no media surface is mounted.
    /// The files and the metadata text arrive as typed items; the sheet acknowledges its
    /// share exactly once.
    public func monitorDeliverySharePresenter<Progress: Sendable, Outcome: Sendable>(
        _ model: MonitorDeliveryModel<Progress, Outcome, MonitorDeliveryShareFiles<URL>>
    ) -> some View {
        background(MonitorDeliveryShareHost(model: model).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

/// Reads the model in its own body, so progress ticks never re-evaluate the app root.
private struct MonitorDeliveryShareHost<Progress: Sendable, Outcome: Sendable>: View {
    let model: MonitorDeliveryModel<Progress, Outcome, MonitorDeliveryShareFiles<URL>>
    var body: some View {
        MonitorDeliveryShareAnchor(share: model.state.share) { id in
            model.completeSharePresentation(id: id)
        }
    }
}

private struct MonitorDeliveryShareAnchor: UIViewControllerRepresentable {
    let share: MonitorDeliveryShare<MonitorDeliveryShareFiles<URL>>?
    let complete: @MainActor (UUID) -> Void

    func makeUIViewController(context: Context) -> MonitorDeliveryShareAnchorController {
        MonitorDeliveryShareAnchorController()
    }

    func updateUIViewController(_ anchor: MonitorDeliveryShareAnchorController, context: Context) {
        anchor.complete = complete
        anchor.show(share)
    }
}

/// Holds the one presented activity controller and its share identity.
final class MonitorDeliveryShareAnchorController: UIViewController {
    var complete: (@MainActor (UUID) -> Void)?
    private var wanted: MonitorDeliveryShare<MonitorDeliveryShareFiles<URL>>?
    private weak var presentedSheet: UIActivityViewController?
    private var presentedID: UUID?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reconcile()
    }

    func show(_ share: MonitorDeliveryShare<MonitorDeliveryShareFiles<URL>>?) {
        wanted = share
        reconcile()
    }

    private func reconcile() {
        // A cleared or replaced share retires its sheet without acknowledging it.
        if let sheet = presentedSheet, presentedID != wanted?.id {
            presentedSheet = nil
            presentedID = nil
            sheet.presentingViewController?.dismiss(animated: true)
        }
        guard let share = wanted, presentedID != share.id, let top = topController() else { return }
        guard top.presentedViewController == nil else {
            // A cover is still leaving; present once it has gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.reconcile() }
            return
        }
        presentedID = share.id
        var items: [Any] = share.payload.urls.map { MonitorDeliveryShareItem(fileURL: $0) }
        if let text = share.payload.metadataText, !text.isEmpty { items.append(text) }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let id = share.id
        sheet.completionWithItemsHandler = { [weak self] _, _, _, _ in
            MainActor.assumeIsolated {
                if self?.presentedID == id {
                    self?.presentedID = nil
                    self?.presentedSheet = nil
                }
                self?.complete?(id)
            }
        }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presentedSheet = sheet
        top.present(sheet, animated: true)
    }

    /// The controller every cover was presented from, walked to its frontmost presentation.
    private func topController() -> UIViewController? {
        guard var top = view.window?.rootViewController else { return nil }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top.isBeingDismissed ? nil : top
    }
}

/// A typed file through `NSItemProvider`, so Launch Services resolves share
/// targets without probing sandbox paths.
public final class MonitorDeliveryShareItem: NSObject, UIActivityItemSource {
    let fileURL: URL
    private let contentType: UTType

    /// Creates a provider for an existing file held until its share sheet is dismissed.
    public init(fileURL: URL, contentType: UTType? = nil) {
        self.fileURL = fileURL
        if let contentType {
            self.contentType = contentType
            return
        }
        switch fileURL.pathExtension.lowercased() {
        case "mov": self.contentType = .quickTimeMovie
        case "mp4", "m4v": self.contentType = .mpeg4Movie
        default: self.contentType = UTType(filenameExtension: fileURL.pathExtension) ?? .data
        }
    }

    private func provider() -> NSItemProvider {
        let url = fileURL
        let provider = NSItemProvider()
        provider.suggestedName = url.lastPathComponent
        provider.registerFileRepresentation(
            forTypeIdentifier: contentType.identifier, fileOptions: [.openInPlace], visibility: .all
        ) { completion in
            completion(url, true, nil)
            return nil
        }
        return provider
    }

    public func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        provider()
    }

    public func activityViewController(
        _ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?
    ) -> Any? { provider() }

    public func activityViewController(
        _ controller: UIActivityViewController,
        dataTypeIdentifierForActivityType type: UIActivity.ActivityType?
    ) -> String { contentType.identifier }

    public func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = fileURL.lastPathComponent
        return metadata
    }
}
#endif
