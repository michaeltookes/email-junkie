import XCTest
@testable import EmailJunkie

/// Tests for the first-run onboarding transitions on `AppState` (item 2).
///
/// These exercise the flow's logic — resume-step derivation, the
/// already-configured reconcile rule, and completion — at the `AppState`
/// level with in-memory fakes, not the SwiftUI view.
@MainActor
final class OnboardingTests: XCTestCase {

    // MARK: - Builders

    private func connectedSettings(
        schemaVersion: Int = Settings.currentSchemaVersion,
        onboardingCompleted: Bool = false
    ) -> Settings {
        Settings(
            schemaVersion: schemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            onboardingCompleted: onboardingCompleted
        )
    }

    /// An AppState with both an account and an LLM connected.
    private func makeFullyConnected(
        schemaVersion: Int = Settings.currentSchemaVersion,
        onboardingCompleted: Bool = false
    )
        -> (AppState, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(
            settings: connectedSettings(
                schemaVersion: schemaVersion,
                onboardingCompleted: onboardingCompleted
            )
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        return (appState, persistence)
    }

    /// An AppState with an account connected but no verified LLM.
    private func makeAccountOnly() -> (AppState, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore(seed: [.mailAppPassword: "app-pw"])
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com"
            )
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        return (appState, persistence)
    }

    /// An AppState with nothing connected.
    private func makeDisconnected(onboardingCompleted: Bool = false)
        -> (AppState, AppStateMemoryPersistence) {
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                onboardingCompleted: onboardingCompleted
            )
        )
        let appState = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore(),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        return (appState, persistence)
    }

    // MARK: - Resume step

    func testResumeStepIsConnectAccountWhenNothingConnected() {
        let (appState, _) = makeDisconnected()
        XCTAssertEqual(appState.onboardingResumeStep, .connectAccount)
    }

    func testResumeStepIsConnectProviderWhenOnlyAccountConnected() {
        let (appState, _) = makeAccountOnly()
        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.onboardingResumeStep, .connectProvider)
    }

    func testResumeStepIsSendBehaviorWhenFullyConnected() {
        let (appState, _) = makeFullyConnected()
        XCTAssertTrue(appState.canFinishOnboarding)
        XCTAssertEqual(appState.onboardingResumeStep, .sendBehavior)
    }

    // MARK: - Reconcile (already-configured install)

    func testReconcileMarksLegacyConfiguredInstallCompleteAndSkipsFlow() {
        let (appState, persistence) = makeFullyConnected(
            schemaVersion: Settings.onboardingCompletionSchemaVersion - 1,
            onboardingCompleted: false
        )

        let needsOnboarding = appState.reconcileOnboardingState()

        XCTAssertFalse(needsOnboarding)
        XCTAssertTrue(appState.onboardingCompleted)
        XCTAssertTrue(persistence.loadSettings().onboardingCompleted,
                      "reconcile must persist the completion so it survives relaunch")
    }

    func testReconcilePreservesPartiallyCompletedCurrentOnboarding() {
        let (appState, persistence) = makeFullyConnected(onboardingCompleted: false)

        let needsOnboarding = appState.reconcileOnboardingState()

        XCTAssertTrue(needsOnboarding)
        XCTAssertFalse(appState.onboardingCompleted)
        XCTAssertFalse(persistence.loadSettings().onboardingCompleted)
        XCTAssertEqual(appState.onboardingResumeStep, .sendBehavior)
    }

    func testReconcileKeepsFlowForFreshInstall() {
        let (appState, persistence) = makeDisconnected(onboardingCompleted: false)

        let needsOnboarding = appState.reconcileOnboardingState()

        XCTAssertTrue(needsOnboarding)
        XCTAssertFalse(appState.onboardingCompleted)
        XCTAssertFalse(persistence.loadSettings().onboardingCompleted)
    }

    func testReconcileLeavesCompletedInstallAlone() {
        let (appState, _) = makeDisconnected(onboardingCompleted: true)
        XCTAssertTrue(appState.onboardingCompleted)
        XCTAssertFalse(appState.reconcileOnboardingState())
    }

    // MARK: - Completion

    func testCompleteOnboardingPersistsAndStartsWatchingWhenReady() {
        let (appState, persistence) = makeFullyConnected(onboardingCompleted: false)

        appState.completeOnboarding()

        XCTAssertTrue(appState.onboardingCompleted)
        XCTAssertTrue(persistence.loadSettings().onboardingCompleted)
        XCTAssertEqual(appState.watchStatus, .watching,
                       "finishing onboarding flips a ready app into watching")
    }

    func testCompleteOnboardingDoesNotWatchWhenNotConnected() {
        // The skip path can complete onboarding even if prerequisites are unmet;
        // it must still persist the flag but not attempt to watch.
        let (appState, persistence) = makeAccountOnly()

        appState.completeOnboarding()

        XCTAssertTrue(appState.onboardingCompleted)
        XCTAssertTrue(persistence.loadSettings().onboardingCompleted)
        XCTAssertEqual(appState.watchStatus, .idle)
    }

    func testCompleteOnboardingIsIdempotent() {
        let (appState, _) = makeFullyConnected(onboardingCompleted: false)

        appState.completeOnboarding()
        appState.completeOnboarding()

        XCTAssertTrue(appState.onboardingCompleted)
    }

    func testCompleteOnboardingDoesNotRestartPausedWatcherWhenAlreadyComplete() {
        let (appState, _) = makeFullyConnected(onboardingCompleted: true)
        appState.watchStatus = .paused

        appState.completeOnboarding()

        XCTAssertEqual(appState.watchStatus, .paused)
    }

    func testInitLoadsPersistedOnboardingFlag() {
        let (appState, _) = makeDisconnected(onboardingCompleted: true)
        XCTAssertTrue(appState.onboardingCompleted)
    }
}
