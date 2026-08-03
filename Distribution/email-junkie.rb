cask "email-junkie" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/michaeltookes/email-junkie/releases/download/v#{version}/EmailJunkie-#{version}.dmg"
  name "Email Junkie"
  desc "Local-first macOS menu-bar email assistant that drafts replies in your voice"
  homepage "https://github.com/michaeltookes/email-junkie"

  depends_on macos: ">= :sonoma"

  app "Email Junkie.app"

  zap trash: [
    "~/Library/Application Support/EmailJunkie",
    "~/Library/Caches/com.tookes.EmailJunkie",
    "~/Library/Preferences/com.tookes.EmailJunkie.plist",
  ]
end
