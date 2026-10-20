import Combine
import Sparkle
import SwiftUI

@MainActor
final class UpdaterViewModel: NSObject, ObservableObject, SPUUpdaterDelegate {
	static let shared = UpdaterViewModel()

	@Published private(set) var canCheckForUpdates: Bool = false
	@Published var automaticallyChecksForUpdates: Bool = false {
		didSet {
			guard let updater = updaterController?.updater, updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else {
				return
			}

			updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
		}
	}

	@Published private(set) var isAvailable: Bool = false

	private var updaterController: SPUStandardUpdaterController?
	private var cancellables = Set<AnyCancellable>()

	override private init() {
		super.init()
	}

	func start() {
		if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
			return
		}

		guard updaterController == nil else {
			return
		}

		guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key != "$(SPARKLE_PUBLIC_KEY)" else {
			KLog.log("[Updater] Sparkle public key (SUPublicEDKey) is missing or unset. In-app updater is disabled.", level: .warn)

			return
		}

		let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

		self.updaterController = controller
		self.isAvailable = true

		controller.updater.publisher(for: \.canCheckForUpdates)
			.receive(on: RunLoop.main)
			.sink { [weak self] canCheck in
				self?.canCheckForUpdates = canCheck
			}
			.store(in: &cancellables)

		controller.updater.publisher(for: \.automaticallyChecksForUpdates)
			.receive(on: RunLoop.main)
			.sink { [weak self] autoCheck in
				if self?.automaticallyChecksForUpdates != autoCheck {
					self?.automaticallyChecksForUpdates = autoCheck
				}
			}
			.store(in: &cancellables)
	}

	func checkForUpdates() {
		guard canCheckForUpdates, let updaterController = updaterController else {
			return
		}

		updaterController.checkForUpdates(nil)
	}
}
