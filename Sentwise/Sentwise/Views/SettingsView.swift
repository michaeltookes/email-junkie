import SwiftUI

/// The app's settings window. Split into dedicated tabs (item 48) so account
/// management is its own uncluttered page rather than one long scrolling form:
/// General preferences, the Email Account page (with saved accounts), and the
/// AI Provider / voice controls.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            EmailAccountSettingsView()
                .tabItem { Label("Email Account", systemImage: "envelope") }

            SenderRulesSettingsView()
                .tabItem { Label("Sender Rules", systemImage: "line.3.horizontal.decrease.circle") }

            AIProviderSettingsView()
                .tabItem { Label("AI Provider", systemImage: "sparkles") }
        }
        .frame(width: 460, height: 520)
    }
}
