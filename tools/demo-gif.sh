#!/bin/bash
# Анимация для README и сайта: assets/demo.gif (английский интерфейс) и
# assets/ru/demo.gif. Кадры — настоящее меню в витрине на демо-профиле
# (--stage --screenshot menu --frame …), вне экрана; сеть и VPN не трогаются.
#   tools/demo-gif.sh            нужны app/make-app.sh, ffmpeg и ImageMagick
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/app/.build/ocbar.app/Contents/MacOS/ocbar-app"
[ -x "$app" ] || { echo "demo-gif: соберите app/make-app.sh" >&2; exit 1; }
command -v ffmpeg >/dev/null && command -v magick >/dev/null \
    || { echo "demo-gif: нужны ffmpeg и magick (brew install ffmpeg imagemagick)" >&2; exit 1; }
# Сценарий: кадр и сколько секунд он на экране.
frames=(down:1.4 connecting:1.0 connected:2.2 network-busy:0.7 network-off:1.6 pausing:0.7 paused:2.2)
bg="#EEF0EA"   # фон сайта, чтобы анимация не выглядела вырезанной
tmp=$(mktemp -d /private/tmp/ocbar-demo.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
for lang in en ru; do
    out="$root/assets/demo.gif"; [ "$lang" = ru ] && out="$root/assets/ru/demo.gif"
    dir="$tmp/$lang"; mkdir -p "$dir"
    for item in "${frames[@]}"; do
        name=${item%%:*}
        "$app" --stage --light --screenshot menu --frame "$name" --shot "$dir/$name.raw.png" \
            -AppleLanguages "($lang)" >/dev/null 2>&1
        # Серый фон витрины — в фон сайта (и в скруглённых углах меню), затем
        # срезаем до самого меню.
        magick "$dir/$name.raw.png" -fuzz 6% -fill "$bg" -draw "color 0,0 floodfill" \
            -trim +repage "$dir/$name.png"
    done
    # Общий холст по самому большому кадру: меню прижато к верху, как в строке меню.
    w=0; h=0
    for item in "${frames[@]}"; do
        read -r fw fh < <(magick identify -format '%w %h\n' "$dir/${item%%:*}.png")
        if (( fw > w )); then w=$fw; fi
        if (( fh > h )); then h=$fh; fi
    done
    list="$dir/list.txt"; : > "$list"
    for item in "${frames[@]}"; do
        name=${item%%:*}
        magick "$dir/$name.png" -background "$bg" -gravity north -extent "${w}x${h}" \
            -bordercolor "$bg" -border 32 -resize 50% "$dir/$name.final.png"
        printf "file '%s'\nduration %s\n" "$dir/$name.final.png" "${item##*:}" >> "$list"
    done
    # concat берёт длительность последнего кадра, только если он повторён.
    last=${frames[${#frames[@]}-1]}
    printf "file '%s'\n" "$dir/${last%%:*}.final.png" >> "$list"
    ffmpeg -loglevel error -y -f concat -safe 0 -i "$list" \
        -vf "split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=none" \
        -loop 0 "$out"
    echo "demo-gif: $lang → ${out#"$root"/} ($(du -h "$out" | cut -f1 | tr -d ' '))"
done
