class OpenconnectForMac < Formula
  desc "OpenConnect for Mac: SSO, split DNS, split tunnel, menu bar"
  homepage "https://valeragin.github.io/openconnect-for-mac/"
  # Стабильная версия — тег и коммит: версия берётся из имени тега, а хеш
  # архива не нужно считать заранее.
  url "https://github.com/ValeraGin/openconnect-for-mac.git",
      tag:      "v0.26.0",
      revision: "f25aae595ca0cb0fa5aab9c11414bddde5401f4e"
  license "MIT"
  head "https://github.com/ValeraGin/openconnect-for-mac.git", branch: "main"

  depends_on macos: :sonoma
  depends_on "openconnect"

  def install
    # Swift идёт с Command Line Tools, полный Xcode не нужен.
    # --disable-sandbox: SwiftPM внутри песочницы brew не может создать свою.
    system "swift", "build", "-c", "release", "--disable-sandbox",
           "--package-path", "auth", "--scratch-path", buildpath/"auth/.build"
    libexec.install "auth/.build/release/ocmac-auth"
    # Приложение меню-бара: SwiftPM даёт исполняемый файл, бандл с
    # Info.plist (LSUIElement) собирает make-app.sh.
    cd("app") { system "./make-app.sh", prefix }
    libexec.install "libexec/ocmac-helper"
    # Помощники клиента: состояние в JSON, общий журнал, маскировка отчёта,
    # вход в парольную группу и сами проверки. Клиент ищет их в libexec.
    libexec.install "libexec/ocmac-status-json.py"
    libexec.install "libexec/ocmac-logs.py"
    libexec.install "libexec/ocmac-redact.py"
    libexec.install "libexec/ocmac-pwauth.py"
    libexec.install "libexec/ocmac-csd.py"
    libexec.install "libexec/ocmac-migrate.py"
    libexec.install "libexec/ocmac-app-update.py"
    libexec.install "libexec/ocmac-prepare.py"
    # Перевод сообщений клиента: каталог шаблонов и тот, кто его применяет.
    libexec.install "libexec/ocmac-tr.pl"
    libexec.install "libexec/ocmac-en.tsv"
    libexec.install "libexec/ocmac-selftest.sh"
    bin.install "bin/ocmac"
    (pkgshare/"swiftbar").install "swiftbar/ocmac.5s.sh"
    # example.ocmac — образец основного формата (профиль одним файлом); маска
    # *.example его не берёт, поэтому он назван отдельно.
    (pkgshare/"examples").install Dir["etc/*.example"], "etc/example.ocmac", "etc/csd-wrapper.sh"
    doc.install "README.md", "README.ru.md", "INSTALL.md", "TROUBLESHOOTING.md", "SECURITY.md", "CHANGELOG.md"
  end

  def caveats
    <<~EOS
      Один раз, с паролем — хелпер root:wheel, sudoers.d, LaunchAgent супервизора:
        ocmac migrate
        ocmac prepare && sudo ocmac install

      Профиль — один файл на подключение (образцы в #{pkgshare}/examples):
        mkdir -p ~/.config/ocmac/profiles
        cp #{pkgshare}/examples/example.ocmac ~/.config/ocmac/profiles/main.ocmac
      Старый формат (profiles.conf, networks.conf, zones.conf) тоже читается;
      перевести в файл — ocmac export. Правила формы входа — секция [Autofill]
      в самом профиле, пишет их ocmac learn.

      Меню-бар — приложение (плагин SwiftBar остаётся как запасной вариант):
        ocmac app start                 запустить; кладёт копию в ~/Applications,
                                        чтобы OpenConnect for Mac был в лаунчере и Spotlight
        ocmac app autostart on          запускать при входе в систему
      После brew upgrade обновите копию приложения: ocmac app upgrade.
      Установщик и ocmac app start выполняют это автоматически.

      Прокси-режим (Mode = proxy в профиле) нуждается в ocproxy — он не
      зависимость формулы, потому что нужен только этому режиму:
        brew install ocproxy

      Плагин SwiftBar — символической ссылкой в каталог плагинов:
        ln -s #{pkgshare}/swiftbar/ocmac.5s.sh ~/Library/Application\\ Support/SwiftBar/Plugins/

      После brew upgrade openconnect копия бинаря перестаёт совпадать с манифестом
      доверия — ocmac doctor подскажет: sudo ocmac install --trust

      Удаление — строго в таком порядке:
        sudo ocmac uninstall
        brew uninstall openconnect-for-mac
      Наоборот нельзя: без формулы убирать системную часть нечем, и останутся
      root-хелпер с беспарольным sudo, копия openconnect и агент супервизора,
      которого launchd перезапускает. Что удалить после — INSTALL.md, «Удаление».
    EOS
  end

  test do
    # Стабильная сборка — ровно версия формулы; у HEAD версия формулы
    # «HEAD-…», поэтому там сверяется только префикс.
    out = shell_output("#{bin}/ocmac version").strip
    if version.head?
      assert_match(/\Aocmac 0\./, out)
    else
      assert_equal "ocmac #{version}", out
    end
    assert_match "selftest: всё OK", shell_output("#{bin}/ocmac selftest")
    assert_match "selftest: всё OK", shell_output("#{libexec}/ocmac-auth --selftest")
    assert_match "ocmac-helper", shell_output("#{libexec}/ocmac-helper version")
    assert_predicate prefix/"ocmac.app/Contents/MacOS/ocmac-app", :executable?
    plist = prefix/"ocmac.app/Contents/Info.plist"
    system "plutil", "-lint", plist
    assert_equal "OpenConnect for Mac",
                 shell_output("plutil -extract CFBundleDisplayName raw #{plist}").strip
    # Без строки о камере macOS завершает процесс при чтении QR камерой,
    # без схемы ocmac:// не доходят уведомления от приложения.
    refute_empty shell_output("plutil -extract NSCameraUsageDescription raw #{plist}").strip
    assert_equal "ocmac",
                 shell_output("plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw #{plist}").strip
    unless version.head?
      assert_equal version.to_s,
                   shell_output("plutil -extract CFBundleShortVersionString raw #{plist}").strip
    end
  end
end
