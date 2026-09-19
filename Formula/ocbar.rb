class Ocbar < Formula
  desc "AnyConnect-compatible VPN client: SSO, split DNS, split tunnel, menu bar"
  homepage "https://github.com/ValeraGin/ocbar"
  # Стабильная версия — тег и коммит: версия берётся из имени тега, а хеш
  # архива не нужно считать заранее.
  url "https://github.com/ValeraGin/ocbar.git",
      tag:      "v0.7.0",
      revision: "764e09796079d4ddd4f32661fcd73fa41cf6c0fc"
  license "MIT"
  head "https://github.com/ValeraGin/ocbar.git", branch: "main"

  depends_on macos: :ventura
  depends_on "openconnect"

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
    # example.ocbar — образец основного формата (профиль одним файлом); маска
    # *.example его не берёт, поэтому он назван отдельно.
    (pkgshare/"examples").install Dir["etc/*.example"], "etc/example.ocbar"
    doc.install "README.md", "README.ru.md", "INSTALL.md", "TROUBLESHOOTING.md", "SECURITY.md", "CHANGELOG.md"
  end

  def caveats
    <<~EOS
      Один раз, с паролем — хелпер root:wheel, sudoers.d, LaunchAgent супервизора:
        sudo ocbar install

      Профиль — один файл на подключение (образцы в #{pkgshare}/examples):
        mkdir -p ~/.config/ocbar/profiles
        cp #{pkgshare}/examples/example.ocbar ~/.config/ocbar/profiles/main.ocbar
      Старый формат (profiles.conf, networks.conf, zones.conf) тоже читается;
      перевести в файл — ocbar export. Правила формы входа — секция [Autofill]
      в самом профиле, пишет их ocbar learn.

      Меню-бар — приложение (плагин SwiftBar остаётся как запасной вариант):
        ocbar app start                 запустить; кладёт копию в ~/Applications,
                                        чтобы ocbar был в лаунчере и Spotlight
        ocbar app autostart on          запускать при входе в систему
      После brew upgrade: ocbar app stop && ocbar app start — обновит и копию.

      Прокси-режим (Mode = proxy в профиле) нуждается в ocproxy — он не
      зависимость формулы, потому что нужен только этому режиму:
        brew install ocproxy

      Плагин SwiftBar — символической ссылкой в каталог плагинов:
        ln -s #{pkgshare}/swiftbar/ocbar.5s.sh ~/Library/Application\\ Support/SwiftBar/Plugins/

      После brew upgrade openconnect копия бинаря перестаёт совпадать с манифестом
      доверия — ocbar doctor подскажет: sudo ocbar install --trust

      Удаление — строго в таком порядке:
        sudo ocbar uninstall
        brew uninstall ocbar
      Наоборот нельзя: без формулы убирать системную часть нечем, и останутся
      root-хелпер с беспарольным sudo, копия openconnect и агент супервизора,
      которого launchd перезапускает. Что удалить после — INSTALL.md, «Удаление».
    EOS
  end

  test do
    # Стабильная сборка — ровно версия формулы; у HEAD версия формулы
    # «HEAD-…», поэтому там сверяется только префикс.
    out = shell_output("#{bin}/ocbar version").strip
    if version.head?
      assert_match(/\Aocbar 0\./, out)
    else
      assert_equal "ocbar #{version}", out
    end
    assert_match "selftest: всё OK", shell_output("#{bin}/ocbar selftest")
    assert_match "selftest: всё OK", shell_output("#{libexec}/ocbar-auth --selftest")
    assert_match "ocbar-helper", shell_output("#{libexec}/ocbar-helper version")
    assert_predicate prefix/"ocbar.app/Contents/MacOS/ocbar-app", :executable?
    plist = prefix/"ocbar.app/Contents/Info.plist"
    system "plutil", "-lint", plist
    # Без строки о камере macOS завершает процесс при чтении QR камерой,
    # без схемы ocbar:// не доходят уведомления от приложения.
    refute_empty shell_output("plutil -extract NSCameraUsageDescription raw #{plist}").strip
    assert_equal "ocbar",
                 shell_output("plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw #{plist}").strip
    unless version.head?
      assert_equal version.to_s,
                   shell_output("plutil -extract CFBundleShortVersionString raw #{plist}").strip
    end
  end
end
