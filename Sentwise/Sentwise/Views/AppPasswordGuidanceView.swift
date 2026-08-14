import SwiftUI

/// Connect-screen guidance for getting the app-specific credential IMAP needs,
/// tailored to the provider detected from the typed email or configured host
/// (item 43). Shared by onboarding and Settings so the copy stays in one place.
struct AppPasswordGuidanceView: View {
    let email: String
    let explicitHostFallback: String?

    private var guidance: CredentialGuidance {
        CredentialGuidance.forEmail(email, explicitHostFallback: explicitHostFallback)
    }

    var body: some View {
        DisclosureGroup(guidance.title) {
            VStack(alignment: .leading, spacing: 6) {
                Text(guidance.passwordWontWorkNote)
                    .font(.caption)
                    .foregroundStyle(.primary)

                ForEach(Array(guidance.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let url = guidance.url {
                    Link("Open \(guidance.providerName) settings", destination: url)
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
    }
}
