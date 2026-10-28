# OpenConnect for Mac — Homebrew tap

Homebrew packages for [OpenConnect for Mac](https://github.com/ValeraGin/openconnect-for-mac): an independent macOS menu-bar client with SSO, split routes and split DNS.

```sh
brew tap ValeraGin/openconnect-for-mac
brew trust ValeraGin/openconnect-for-mac
brew install ValeraGin/openconnect-for-mac/openconnect-for-mac
ocmac migrate
ocmac prepare && sudo ocmac install
ocmac app start
```

The migration preserves original profiles and credentials. System setup stops the previous VPN session and restores launch at login when it was enabled.

Update with `brew upgrade openconnect-for-mac`, then `ocmac app upgrade` to refresh the visible app and its login item. The installer runs both steps.
Uninstall with `sudo ocmac uninstall`, then `brew uninstall openconnect-for-mac`.

[Website and installer](https://valeragin.github.io/openconnect-for-mac/) · [Инструкция по-русски](https://github.com/ValeraGin/openconnect-for-mac/blob/main/README.ru.md)

The formula and migration rules are maintained in the main repository's `Formula/` directory and published here with each release.
