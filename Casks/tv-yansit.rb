# Homebrew tap (mstkyvz/homebrew-tap) icin cask sablonu.
# Yeni surumde version ve sha256 guncellenir.
cask "tv-yansit" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/mstkyvz/tv-yansit/releases/download/v#{version}/TVYansit-#{version}.zip"
  name "TV Yansıt"
  desc "Mirror your Mac screen or a single window to older smart TVs via their web browser"
  homepage "https://github.com/mstkyvz/tv-yansit"

  depends_on macos: ">= :ventura"

  app "TV Yansıt.app"

  # Uygulama notarize edilmedigi icin karantina isareti kaldirilir
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/TV Yansıt.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/com.tvyansit.app.plist",
  ]

  caveats <<~EOS
    İlk açılışta Ekran Kaydı izni ver:
      Sistem Ayarları → Gizlilik ve Güvenlik → Ekran ve Sistem Sesi Kaydı
  EOS
end
