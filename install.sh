#!/bin/bash
# Install OpenConnect for Mac and optionally a colleague's profile. Compatible with macOS Bash 3.2.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: /bin/bash install.sh [options]
  --profile FILE        Import a .ocmac profile without replacing an existing one
  --csd FILE            Install its CSD script and set CsdWrapper in the profile
  --language ru|en|system  Set the interface language (default: keep current)
  --head                Install the current main branch instead of the stable release
  --no-start            Do not launch the menu app
  --no-autostart        Do not enable launch at login
  --help                Show this help
Run as your regular macOS user, not with sudo. The helper installer asks for sudo.
EOF
}
fail() { printf 'OpenConnect for Mac installer: %s\n' "$*" >&2; exit 1; }
ask() {
    local answer
    printf '%s [y/N] ' "$1" > /dev/tty
    read -r answer < /dev/tty || return 1
    case "$answer" in y|Y|yes|YES|да|Да) return 0 ;; *) return 1 ;; esac
}
profile='' csd='' language='' head=0 start=1 autostart=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile|--csd|--language)
            [ "$#" -ge 2 ] && [ -n "$2" ] || fail "Missing value for $1"
            case "$1" in --profile) profile=$2 ;; --csd) csd=$2 ;; --language) language=$2 ;; esac
            shift 2 ;;
        --head) head=1; shift ;;
        --no-start) start=0; shift ;;
        --no-autostart) autostart=0; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: $1 (see --help)" ;;
    esac
done
case "$language" in ''|ru|en|system) ;; *) fail 'Language must be ru, en or system' ;; esac
[ -z "$profile" ] || [ -f "$profile" ] || fail "No profile: $profile"
[ -z "$csd" ] || { [ -n "$profile" ] && [ -f "$csd" ]; } || fail '--csd needs --profile and an existing script'
[ "$(uname -s)" = Darwin ] || fail 'macOS is required'
[ "$(id -u)" != 0 ] || fail 'Run without sudo; only the helper needs administrator access'
version=$(sw_vers -productVersion)
major=${version%%.*}; minor=${version#*.}; minor=${minor%%.*}
{ [ "$major" -gt 14 ] || { [ "$major" -eq 14 ] && [ "$minor" -ge 4 ]; }; } || fail 'macOS 14.4 or newer is required'
[ -r /dev/tty ] && [ -w /dev/tty ] || fail 'Run this command in Terminal so you can answer prompts'

config="$HOME/.config/ocmac"
export OCMAC_CONFIG_DIR="$config"
name='' destination='' skip_profile=0
if [ -n "$profile" ]; then
    case "$profile" in *.ocmac) ;; *) fail 'The profile must have a .ocmac extension' ;; esac
    name=$(basename "$profile"); name=${name%.ocmac}
    case "$name" in ''|*[!a-zA-Z0-9._-]*|.*) fail 'Use a profile filename with letters, digits, dots, underscores or hyphens' ;; esac
    destination="$config/profiles/$name.ocmac"
    if [ -e "$destination" ]; then
        printf 'Keeping existing profile: %s\n' "$destination"
        skip_profile=1
    fi
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/ocmac-install.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The Apple tools provide both Git and Swift; /usr/bin/git can be just a stub.
if ! xcrun --find swift >/dev/null 2>&1 || ! git --version >/dev/null 2>&1; then
    ask 'Install Apple Command Line Tools (Git and Swift)? / Установить инструменты Apple?' || fail 'Command Line Tools are required'
    xcode-select --install || fail 'Could not start the Apple installer. Install Command Line Tools, then rerun this script.'
    printf 'Finish installing in the Apple window. Waiting up to 30 minutes…\n'
    ready=0
    for ((attempt=0; attempt<360; attempt++)); do
        if xcrun --find swift >/dev/null 2>&1 && git --version >/dev/null 2>&1; then ready=1; break; fi
        sleep 5
    done
    [ "$ready" = 1 ] || fail 'Tools are not ready. Finish their installation, then rerun this command.'
fi

brew_bin=$(command -v brew || true)
if [ -z "$brew_bin" ]; then
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$candidate" ]; then brew_bin=$candidate; break; fi
    done
fi
if [ -z "$brew_bin" ]; then
    ask 'Homebrew is missing. Install it? / Установить Homebrew?' || fail 'Homebrew is required'
    curl -fLsS --retry 3 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$work/homebrew.sh"
    /bin/bash "$work/homebrew.sh" < /dev/tty
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$candidate" ]; then brew_bin=$candidate; break; fi
    done
    [ -n "$brew_bin" ] || fail 'Homebrew was not installed'
fi
brew_prefix=$("$brew_bin" --prefix)
export PATH="$brew_prefix/bin:$brew_prefix/sbin:$PATH"
# Keep new Terminal windows usable, too; do not change an existing Homebrew setup.
if ! /bin/zsh -lc 'command -v brew' >/dev/null 2>&1; then
    printf -v brew_quoted '%q' "$brew_bin"
    shell_line="eval \"\$($brew_quoted shellenv)\""
    touch "$HOME/.zprofile"
    if ! grep -Fqx "$shell_line" "$HOME/.zprofile"; then printf '\n%s\n' "$shell_line" >> "$HOME/.zprofile"; fi
fi
"$brew_bin" tap ValeraGin/openconnect-for-mac
# New Homebrew requires explicit trust for third-party taps; older versions do not.
if "$brew_bin" help trust >/dev/null 2>&1; then "$brew_bin" trust ValeraGin/openconnect-for-mac; fi
formula=ValeraGin/openconnect-for-mac/openconnect-for-mac
if [ "$head" = 1 ]; then
    # Build beside the linked release; reinstall does not accept --HEAD.
    # Keep the current client available until the new build succeeds.
    "$brew_bin" install --HEAD --fetch-HEAD --skip-link "$formula"
    "$brew_bin" unlink "$formula"
    "$brew_bin" link --HEAD "$formula"
elif ! "$brew_bin" list --versions "$formula" >/dev/null 2>&1; then
    "$brew_bin" install "$formula"
else
    "$brew_bin" upgrade "$formula"
fi
ocmac="$("$brew_bin" --prefix "$formula")/bin/ocmac"
[ -x "$ocmac" ] || fail 'Homebrew did not provide the ocmac executable'
"$ocmac" migrate
# Migration may have populated this filename: never replace it with an import.
if [ -n "$destination" ] && [ -e "$destination" ]; then
    printf 'Keeping existing profile: %s\n' "$destination"
    skip_profile=1
fi

if [ -n "$profile" ] && [ "$skip_profile" = 0 ]; then
    # Older releases accepted unknown profile keys and would silently omit CSD.
    if [ -z "$csd" ] && grep -Eiq '^[[:space:]]*CsdScriptBase64[[:space:]]*=' "$profile"; then
        printf '[Connection]\nUrl = vpn.example.test\nCsdScriptBase64 = !\n' > "$work/csd-capability.ocmac"
        if "$ocmac" profile-check "$work/csd-capability.ocmac" >/dev/null 2>&1; then
            if [ "$head" = 0 ]; then
                "$brew_bin" upgrade "$formula"
                ocmac="$("$brew_bin" --prefix "$formula")/bin/ocmac"
            fi
            if "$ocmac" profile-check "$work/csd-capability.ocmac" >/dev/null 2>&1; then
                fail 'Installed ocmac cannot read CsdScriptBase64. A newer release or --head is required.'
            fi
        fi
    fi
    # Validate before copying scripts or asking for administrator access.
    "$ocmac" profile-check "$profile"
    if [ -n "$csd" ]; then
        target="$config/csd/$name.sh"
        if [ -e "$target" ]; then
            printf 'Keeping existing CSD script: %s\n' "$target"
            [ -x "$target" ] || fail "Existing CSD script is not executable: $target"
        else
            /bin/bash -n "$csd"
            mkdir -p "$config/csd"
            install -m 700 "$csd" "$target"
        fi
        # Only the Connection section is changed; routes, DNS and auth rules survive.
        awk -v target="$target" '
            /^\[/ { connection=(tolower($0) ~ /^\[connection\][[:space:]]*$/) }
            connection && tolower($0) ~ /^[[:space:]]*(csdwrapper|csdscriptbase64)[[:space:]]*=/ { next }
            { print }
            tolower($0) ~ /^\[connection\][[:space:]]*$/ { print "CsdWrapper = " target }
        ' "$profile" > "$work/$name.ocmac"
        profile="$work/$name.ocmac"
    fi
    "$ocmac" import "$profile" "$name"
fi
if [ -n "$language" ]; then defaults write ru.ocmac.app InterfaceLanguage -string "$language"; fi
# Install after importing the profile: the helper copies its CSD script as well.
"$ocmac" app upgrade
"$ocmac" prepare
sudo -- "$ocmac" install < /dev/tty
if [ "$autostart" = 1 ]; then "$ocmac" app autostart on; fi
if [ "$start" = 1 ]; then "$ocmac" app stop; "$ocmac" app start; fi
printf '\nOpenConnect for Mac installed. Open your .ocmac profile, enter your username and connect.\n'
printf 'OpenConnect for Mac установлен. Откройте файл .ocmac, введите свой логин и подключитесь.\n'
