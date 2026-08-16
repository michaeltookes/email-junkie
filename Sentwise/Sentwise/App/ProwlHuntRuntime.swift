import Foundation

/// Runtime switches for local Prowl accessibility hunts. The documented Prowl
/// app bundle lives under `.prowl/DerivedData`, which enables an isolated mode
/// before startup automation can touch the user's live account.
struct ProwlHuntRuntime {
    static let environmentKey = "SENTWISE_PROWL_HUNT_MODE"
    static let launchArgument = "--sentwise-prowl-hunt-mode"
    static let xctestConfigurationEnvironmentKey = "XCTestConfigurationFilePath"

    let isEnabled: Bool

    static var current: ProwlHuntRuntime {
        ProwlHuntRuntime(
            isEnabled: isEnabled(
                environment: ProcessInfo.processInfo.environment,
                arguments: ProcessInfo.processInfo.arguments,
                bundlePath: Bundle.main.bundlePath
            )
        )
    }

    var allowsStartupSideEffects: Bool {
        !isEnabled
    }

    var shouldOpenOnboardingAtLaunch: Bool {
        !isEnabled
    }

    func makePersistenceProvider() -> PersistenceProvider {
        isEnabled ? MemoryPersistenceProvider() : PersistenceService.shared
    }

    func makeSecretStore() -> SecretStore {
        isEnabled ? InMemorySecretStore() : KeychainStore.shared
    }

    static func isEnabled(
        environment: [String: String],
        arguments: [String],
        bundlePath: String
    ) -> Bool {
        if isTruthy(environment[environmentKey]) {
            return true
        }
        if arguments.contains(launchArgument) {
            return true
        }
        if environment[xctestConfigurationEnvironmentKey]?.isEmpty == false {
            return true
        }
        return isProwlDerivedDataBundlePath(bundlePath)
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func isProwlDerivedDataBundlePath(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard components.count >= 2 else { return false }
        for index in components.indices.dropLast() {
            let next = components.index(after: index)
            if components[index] == ".prowl", components[next] == "DerivedData" {
                return true
            }
        }
        return false
    }
}
