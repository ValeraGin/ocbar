class Ocbar < Formula
  desc "OpenConnect client for macOS: SSO via WKWebView, split DNS, split tunneling, menu bar"
  homepage "https://github.com/ValeraGin/ocbar"
  # Репозиторий приватный: tarball с GitHub без авторизации не скачать, а git
  # по тегу работает с теми же учётными данными, что и --HEAD. Поэтому
  # стабильная версия — тег и коммит, а не url + sha256 (D47).
  url "https://github.com/ValeraGin/ocbar.git", tag: "v0.2.0", revision: "REVISION_V0_2_0"
  version "0.2.0"
  head "https://github.com/ValeraGin/ocbar.git", branch: "main"
  license "MIT"

  depends_on "openconnect"
  depends_on :macos => :ventura

  def install
    # Swift идёт с Command Line Tools, полный Xcode не нужен.
    # --disable-sandbox: SwiftPM внутри песочницы brew не может создать свою.
    system "swift", "build", "-c", "release", "--disable-sandbox",
           "--package-path", "auth", "--scratch-path", buildpath/"auth/.build"
    libexec.install "auth/.build/release/ocbar-auth"
    # Приложение меню-бара: SwiftPM даёт исполняемый файл, бандл с
    # Info.plist (LSUIElement) собирает make-app.sh.
    cd("app") { system "./make-app.sh", prefix }
    libexec.install "libexec/ocbar-helper"
    bin.install "bin/ocbar"
    (pkgshare/"swiftbar").install "swiftbar/ocbar.5s.sh"
    (pkgshare/"examples").install Dir["etc/*.example"]
    doc.install Dir["docs/0*.md"], "README.md", "INSTALL.md", "TROUBLESHOOTING.md", "ROADMAP.md", "DECISIONS.md"
  end

  def caveats
    <<~EOS
      Один раз, с паролем — хелпер root:wheel, sudoers.d, LaunchAgent супервизора:
        sudo ocbar install

      Конфиги (образцы в #{pkgshare}/examples):
        ~/.config/ocbar/profiles.conf, zones.conf, networks.conf, autofill.rules

      Меню-бар — приложение (плагин SwiftBar остаётся как запасной вариант):
        ocbar app start                 запустить сейчас
        ocbar app autostart on          запускать при входе в систему
        open #{prefix}/ocbar.app        то же самое руками

      Прокси-режим (Mode = proxy в профиле) нуждается в ocproxy — он не
      зависимость формулы, потому что нужен только этому режиму:
        brew install ocproxy

      Плагин SwiftBar — символической ссылкой в каталог плагинов:
        ln -s #{pkgshare}/swiftbar/ocbar.5s.sh ~/Library/Application\\ Support/SwiftBar/Plugins/

      После brew upgrade openconnect копия бинаря перестаёт совпадать с манифестом
      доверия — ocbar doctor подскажет: sudo ocbar install --trust
    EOS
  end

  test do
    assert_match "ocbar 0.", shell_output("#{bin}/ocbar version")
    assert_match "selftest: всё OK", shell_output("#{bin}/ocbar selftest")
    assert_match "selftest: всё OK", shell_output("#{libexec}/ocbar-auth --selftest")
    assert_match "ocbar-helper", shell_output("#{libexec}/ocbar-helper version")
    assert_predicate prefix/"ocbar.app/Contents/MacOS/ocbar-app", :executable?
    system "plutil", "-lint", prefix/"ocbar.app/Contents/Info.plist"
  end
end
