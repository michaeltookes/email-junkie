import AppKit
import SwiftUI

/// The branded About tab of Settings (item 65), mirroring ContainerBar's
/// `AboutPane`: the Sentwise owl icon, the app name and version/build read from
/// the bundle, the local-first privacy statement, links to the repo and
/// sentwise.ai, the Check for Updates action, and copyright.
///
/// The updater is injected as plain values plus a closure rather than the
/// `UpdateManager` object so this view stays a value type with no observation —
/// the Settings content is rebuilt each time the tab is shown, which is enough
/// for a one-shot "check now" button.
struct AboutPane: View {
    let canCheckForUpdates: Bool
    let updatesUnavailableReason: String?
    let checkForUpdates: () -> Void

    private var appIcon: NSImage {
        if let named = NSImage(named: "AppIcon") {
            return named
        }
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            return appIcon
        }
        return NSApp.applicationIconImage
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)

                Text("Sentwise")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Version \(appVersion) (\(buildNumber))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Version \(appVersion), build \(buildNumber)")
            }

            Text(AppState.privacyStatement)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)

            Divider()
                .frame(maxWidth: 200)

            VStack(spacing: 10) {
                Link(destination: URL(string: "https://github.com/michaeltookes/sentwise")!) {
                    Label("GitHub Repository", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .accessibilityLabel("Open the Sentwise GitHub repository")

                Link(destination: URL(string: "https://sentwise.ai")!) {
                    Label("sentwise.ai", systemImage: "globe")
                }
                .accessibilityLabel("Open sentwise.ai")
            }

            Divider()
                .frame(maxWidth: 200)

            VStack(spacing: 4) {
                Button("Check for Updates…") {
                    checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!canCheckForUpdates)
                .accessibilityLabel("Check for Sentwise updates")

                if !canCheckForUpdates, let reason = updatesUnavailableReason {
                    Text(reason)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: 320)
                }
            }

            Spacer(minLength: 0)

            Text("\(copyrightYear) Sentwise · Made with Swift and SwiftUI")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var copyrightYear: String {
        String(Calendar.current.component(.year, from: Date()))
    }
}
