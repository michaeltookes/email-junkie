import EmailJunkieMail
import SwiftUI

/// A resizable window to search, filter, and browse a mailbox for a message to
/// view or reply to (item 40). Powered by `AppState`'s server-side search, so it
/// stays responsive on large, poorly-organized mailboxes.
struct MailboxBrowserView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            results
        }
        .frame(minWidth: 600, minHeight: 520)
        .sheet(item: $appState.openedBody) { preview in
            MessageBodyView(preview: preview)
        }
        .sheet(item: $appState.generatedDraft) { draft in
            DraftView(draft: draft).environmentObject(appState)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            searchRow
            filterRow
        }
        .padding()
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search mail", text: $appState.browser.keyword)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runSearch() }
                .accessibilityLabel("Search keyword")
            Picker("Folder", selection: $appState.browser.mailbox) {
                Text("Inbox").tag(Mailbox.inbox)
                Text("Sent").tag(Mailbox.sent)
                Text("Drafts").tag(Mailbox.drafts)
                Text("All Mail").tag(Mailbox.allMail)
            }
            .labelsHidden()
            .frame(width: 130)
            Button("Search") { runSearch() }
                .keyboardShortcut(.defaultAction)
                .disabled(appState.browser.isSearching)
        }
    }

    private var filterRow: some View {
        HStack(spacing: 12) {
            TextField("From", text: $appState.browser.sender)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 190)
                .onSubmit { runSearch() }
                .accessibilityLabel("Filter by sender")
            Picker("Show", selection: $appState.browser.readState) {
                Text("All").tag(MailReadState.any)
                Text("Unread").tag(MailReadState.unreadOnly)
                Text("Read").tag(MailReadState.readOnly)
            }
            .frame(width: 170)
            dateFilter("Since", isOn: $appState.browser.useSinceFilter, date: $appState.browser.since)
            dateFilter("Before", isOn: $appState.browser.useBeforeFilter, date: $appState.browser.before)
            Spacer()
        }
        .font(.callout)
    }

    private func dateFilter(_ label: String, isOn: Binding<Bool>, date: Binding<Date>) -> some View {
        HStack(spacing: 4) {
            Toggle(label, isOn: isOn)
            if isOn.wrappedValue {
                DatePicker("", selection: date, displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityLabel("\(label) date")
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if appState.browser.isSearching {
            centered { ProgressView("Searching…") }
        } else if let error = appState.browser.error {
            centered {
                statusLabel(error, systemImage: "exclamationmark.triangle", color: .red)
            }
        } else if appState.browser.results.isEmpty {
            centered {
                statusLabel(
                    appState.browser.hasSearched
                        ? "No messages match your search."
                        : "Search your mailbox to find a message.",
                    systemImage: "tray",
                    color: .secondary
                )
            }
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            resultCountBar
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(appState.browser.results) { message in
                        MailboxBrowserRow(message: message)
                        Divider()
                    }
                    loadMoreFooter
                }
            }
        }
    }

    private var resultCountBar: some View {
        HStack {
            Text("Showing \(appState.browser.results.count) of \(appState.browser.totalMatches)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if appState.browser.isLoadingMore {
            ProgressView().controlSize(.small).padding()
        } else if appState.browser.hasMore {
            Button("Load more") {
                Task { await appState.loadMoreMailboxResults() }
            }
            .padding()
        }
    }

    // MARK: - Helpers

    private func runSearch() {
        Task { await appState.runMailboxSearch() }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusLabel(_ text: String, systemImage: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(color)
            Text(text).font(.callout).foregroundStyle(color)
        }
        .padding()
    }
}

/// One result row: the message summary plus View body / Draft reply actions,
/// reusing the same `AppState` preview/draft actions as Settings.
private struct MailboxBrowserRow: View {
    let message: MailMessage
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                    .font(.callout)
                    .lineLimit(1)
                Text(message.from?.email ?? "unknown sender")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { await appState.previewBody(for: message, mailbox: appState.browser.mailbox) }
            } label: {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.borderless)
            .help("View body")
            .disabled(appState.isFetchingBody)
            .accessibilityLabel("View body")

            Button {
                Task { await appState.generateDraft(for: message, mailbox: appState.browser.mailbox) }
            } label: {
                Image(systemName: "arrowshape.turn.up.left")
            }
            .buttonStyle(.borderless)
            .help("Draft reply")
            .disabled(appState.isGeneratingDraft || !appState.canGenerateDraft)
            .accessibilityLabel("Draft reply")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
