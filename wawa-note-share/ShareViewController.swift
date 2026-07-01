import OSLog
import SwiftUI
import UIKit
import WawaNoteCore

private let logger = Logger(subsystem: "com.wawa-note.share", category: "share-extension")

/// Minimal UIViewController that hosts the SwiftUI ShareExtensionView.
/// Required by NSExtensionPrincipalClass — must be a UIViewController subclass.
final class ShareViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()

    guard let extensionContext = extensionContext else {
      logger.error("No extensionContext available")
      return
    }

    let viewModel = ShareExtensionViewModel(extensionContext: extensionContext)
    let rootView = ShareExtensionView(viewModel: viewModel)

    let hostingController = UIHostingController(rootView: rootView)
    hostingController.view.backgroundColor = .clear

    addChild(hostingController)
    view.addSubview(hostingController.view)
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    hostingController.didMove(toParent: self)
  }
}
