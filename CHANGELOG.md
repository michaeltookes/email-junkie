# Changelog

All notable changes to Sentwise are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-08-14

Initial release.

### Added

- **Post-call follow-up workflow** — paste a call transcript, drop a `.txt`/`.md`/`.vtt`/`.srt` file, or point Sentwise at a watched folder (e.g. Zoom's local recording directory): it drafts the next-steps follow-up email in your voice — recap, action items with owners, proposed next meeting — ready for one-tap approval.
- **Voice learning** — Sentwise studies your Sent mail so drafts sound like you, not like an AI.
- **Inbox reply drafting** — watches your inbox and drafts replies to messages worth answering, with automatic filtering of newsletters, notifications, and no-reply senders.
- **One-tap approval** — native macOS notifications and a review window; approve, edit, or deny every draft. Nothing ever sends without you.
- **Send or save-as-draft** — your choice on approval: send immediately (with a configurable undo window) or save to your provider's Drafts folder.
- **Safety guards** — stale-thread detection blocks replies to conversations that moved on; low-confidence drafts are flagged for your input instead of guessing; offline approvals queue durably and dispatch on reconnect.
- **Supported IMAP mailboxes** — connect with your email address and an app password. Gmail and AT&T/Yahoo are verified live end to end; custom IMAP hosts are supported when their SMTP endpoint follows the derived `smtp.` host on implicit-TLS port 465.
- **Bring-your-own AI** — pluggable providers (Anthropic, OpenAI, and any OpenAI-compatible endpoint including local runtimes like Ollama), with your key stored in the macOS Keychain.
- **Mailbox cleanup tools** — a browser with search and safe bulk cleanup that can drain even huge, neglected inboxes without ever bulk-downloading them.
- **Activity history** — a local, metadata-only log of everything the assistant did and why.
- **Private by design** — local-first storage keeps settings, history, and secrets on your Mac. When you use a remote AI provider, Sentwise sends the relevant mail content, transcript text, and voice profile only to the provider you configure.
- **Signed, notarized, auto-updating** — Developer ID–signed DMG with Sparkle auto-update and a Homebrew cask (`brew install --cask michaeltookes/tap/sentwise`).

[0.1.0]: https://github.com/michaeltookes/sentwise/releases/tag/v0.1.0
