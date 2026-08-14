#!/bin/bash
#
# Сборка приложения «голос» одной командой.
#
#   ./build.sh          — собрать голос.app в dist/
#   ./build.sh run      — собрать и запустить
#   ./build.sh install  — собрать и положить в /Applications
#   ./build.sh dmg      — собрать установочный образ для GitHub Release
#   ./build.sh test     — собрать движки и прогнать регрессионные тесты
#   ./build.sh clean    — удалить артефакты сборки
#
# Требуется: Command Line Tools (swift, clang) и cmake.
# Xcode целиком не нужен: Metal-ядра компилируются на первом запуске.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="голос"
EXECUTABLE_NAME="Golos"
BUNDLE="dist/${APP_NAME}.app"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="dist/golos-${APP_VERSION}-macos-arm64.dmg"
LEGACY_BUNDLE="dist/Golos.app"
LEGACY_RUSSIAN_BUNDLE="dist/Голос.app"
WHISPER="Vendor/whisper.cpp"
BUILD_DIR="${WHISPER}/build-static"
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

say() { printf "\033[1;36m▸\033[0m %s\n" "$1"; }
die() { printf "\033[1;31m✗\033[0m %s\n" "$1" >&2; exit 1; }

# ─────────────────────────────────────────────── clean

if [[ "${1:-}" == "clean" ]]; then
    say "Удаляю артефакты сборки"
    rm -rf .build dist "${BUILD_DIR}"
    say "Готово. Исходники и Vendor/whisper.cpp на месте."
    exit 0
fi

# ─────────────────────────────────────────────── проверки

command -v swift >/dev/null || die "Не найден swift. Установите Command Line Tools: xcode-select --install"
command -v cmake >/dev/null || die "Не найден cmake. Установите: brew install cmake"

# ─────────────────────────────────────────────── whisper.cpp

if [[ ! -d "$WHISPER" ]]; then
    say "Скачиваю whisper.cpp"
    git clone --depth 1 https://github.com/ggml-org/whisper.cpp "$WHISPER"
fi

if [[ ! -f "${BUILD_DIR}/src/libwhisper.a" ]]; then
    say "Собираю whisper.cpp (это займёт пару минут)"
    # GGML_METAL_EMBED_LIBRARY=OFF: офлайн-компилятор metal есть только в полном
    # Xcode. Вместо него шейдер компилируется на GPU при первом запуске и дальше
    # берётся из системного кэша.
    cmake -B "$BUILD_DIR" -S "$WHISPER" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=OFF \
        -DGGML_ACCELERATE=ON \
        -DGGML_BLAS=ON \
        -DGGML_OPENMP=OFF \
        -DWHISPER_BUILD_EXAMPLES=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_SERVER=OFF \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 >/dev/null
    # Цель `whisper`, а не `all`: цель ggml-metal-lib требует компилятора metal.
    cmake --build "$BUILD_DIR" --target whisper  -j "$(sysctl -n hw.ncpu)" >/dev/null
    cmake --build "$BUILD_DIR" --target parakeet -j "$(sysctl -n hw.ncpu)" >/dev/null
fi

for lib in src/libwhisper.a src/libparakeet.a ggml/src/libggml.a ggml/src/libggml-base.a \
           ggml/src/libggml-cpu.a ggml/src/ggml-metal/libggml-metal.a \
           ggml/src/ggml-blas/libggml-blas.a; do
    [[ -f "${BUILD_DIR}/${lib}" ]] || die "Не собралась библиотека ${lib}"
done

# ─────────────────────────────────────────────── заголовки для Swift

say "Подкладываю заголовки whisper"
mkdir -p Sources/CWhisper/include
for header in include/whisper.h ggml/include/ggml.h ggml/include/ggml-alloc.h \
              ggml/include/ggml-backend.h ggml/include/ggml-cpu.h \
              ggml/include/ggml-metal.h ggml/include/ggml-opt.h \
              ggml/include/gguf.h ggml/include/ggml-cpp.h ggml/include/ggml-blas.h \
              include/parakeet.h; do
    ln -sf "../../../${WHISPER}/${header}" "Sources/CWhisper/include/$(basename "$header")"
done

# Self-test собирается в том же модуле и линкуется с теми же библиотеками, что
# приложение. Это работает и с одними Command Line Tools, где XCTest отсутствует.
if [[ "${1:-}" == "test" ]]; then
    say "Собираю регрессионные тесты"
    swift build --disable-sandbox \
        -Xlinker -force_load -Xlinker "${BUILD_DIR}/ggml/src/ggml-metal/libggml-metal.a" \
        -Xlinker -force_load -Xlinker "${BUILD_DIR}/ggml/src/ggml-blas/libggml-blas.a" \
        -Xlinker -force_load -Xlinker "${BUILD_DIR}/ggml/src/libggml-cpu.a" \
        -Xlinker "${BUILD_DIR}/src/libwhisper.a" \
        -Xlinker "${BUILD_DIR}/src/libparakeet.a" \
        -Xlinker "${BUILD_DIR}/ggml/src/libggml.a" \
        -Xlinker "${BUILD_DIR}/ggml/src/libggml-base.a"
    TEST_BINARY="$(swift build --show-bin-path)/${EXECUTABLE_NAME}"
    [[ -x "$TEST_BINARY" ]] || die "Не найден тестовый бинарник"
    GOLOS_SELF_TEST=1 "$TEST_BINARY"
    say "Все тесты пройдены"
    exit 0
fi

# ─────────────────────────────────────────────── Swift

say "Компилирую приложение"
swift build --disable-sandbox -c release \
    -Xlinker -force_load -Xlinker "${BUILD_DIR}/ggml/src/ggml-metal/libggml-metal.a" \
    -Xlinker -force_load -Xlinker "${BUILD_DIR}/ggml/src/ggml-blas/libggml-blas.a" \
    -Xlinker -force_load -Xlinker "${BUILD_DIR}/ggml/src/libggml-cpu.a" \
    -Xlinker "${BUILD_DIR}/src/libwhisper.a" \
    -Xlinker "${BUILD_DIR}/src/libparakeet.a" \
    -Xlinker "${BUILD_DIR}/ggml/src/libggml.a" \
    -Xlinker "${BUILD_DIR}/ggml/src/libggml-base.a"

BINARY="$(swift build --disable-sandbox -c release --show-bin-path)/${EXECUTABLE_NAME}"
[[ -f "$BINARY" ]] || die "Бинарник не собрался"

# ─────────────────────────────────────────────── бандл

say "Собираю ${APP_NAME}.app"
# Убираем прежнее английское имя только из каталога сборки, чтобы после
# переименования рядом не лежали два визуально одинаковых приложения.
rm -rf "$BUNDLE" "$LEGACY_BUNDLE" "$LEGACY_RUSSIAN_BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"

cp "$BINARY" "${BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"
printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

# Metal-шейдер со встроенными заголовками: ggml умеет компилировать его
# в рантайме, но #include внутри исходника ему не разрешить — вклеиваем сами.
say "Готовлю Metal-шейдер"
python3 - "$WHISPER" "${BUNDLE}/Contents/Resources/ggml-metal.metal" <<'PYTHON'
import pathlib, sys

root = pathlib.Path(sys.argv[1]) / "ggml" / "src"
source = (root / "ggml-metal" / "ggml-metal.metal").read_text()
for include, path in [
    ('#include "ggml-common.h"', root / "ggml-common.h"),
    ('#include "ggml-metal-impl.h"', root / "ggml-metal" / "ggml-metal-impl.h"),
]:
    if include not in source:
        sys.exit(f"В ggml-metal.metal не найдено {include!r} — формат ggml изменился")
    source = source.replace(include, path.read_text(), 1)

pathlib.Path(sys.argv[2]).write_text(source)
print(f"  шейдер: {len(source) // 1024} КБ")
PYTHON

# Иконка.
if command -v iconutil >/dev/null; then
    say "Рисую иконку"
    ICONSET="dist/AppIcon.iconset"
    rm -rf "$ICONSET"
    swift Scripts/make_icon.swift "$ICONSET" >/dev/null
    if ! iconutil -c icns "$ICONSET" -o "${BUNDLE}/Contents/Resources/AppIcon.icns"; then
        # На некоторых версиях Command Line Tools iconutil отвергает корректный
        # iconset как Invalid Iconset. ICNS — простой контейнер PNG; локальный
        # упаковщик даёт тот же результат и не зависит от этой утилиты.
        say "iconutil недоступен — упаковываю ICNS напрямую"
        python3 Scripts/make_icns.py "$ICONSET" "${BUNDLE}/Contents/Resources/AppIcon.icns"
    fi
    rm -rf "$ICONSET"
fi

# ─────────────────────────────────────────────── подпись

say "Подписываю"
# Ad-hoc подписи достаточно для локального запуска. Она же даёт стабильный
# идентификатор, по которому macOS запоминает выданные разрешения —
# после пересборки их придётся выдать заново, это нормально.
codesign --force --deep --sign - \
    --entitlements Resources/Golos.entitlements \
    "$BUNDLE" 2>/dev/null || die "Не удалось подписать бандл"

codesign --verify --deep "$BUNDLE" || die "Подпись не прошла проверку"

SIZE=$(du -sh "$BUNDLE" | cut -f1)
say "Готово: ${BUNDLE} (${SIZE})"

# ─────────────────────────────────────────────── запуск

case "${1:-}" in
    run)
        say "Запускаю"
        open "$BUNDLE"
        ;;
    install)
        say "Копирую в /Applications"
        rm -rf "/Applications/${APP_NAME}.app"
        cp -R "$BUNDLE" /Applications/
        say "Установлено: /Applications/${APP_NAME}.app"
        ;;
    dmg)
        command -v hdiutil >/dev/null || die "Не найден hdiutil"
        say "Собираю установочный образ"
        DMG_ROOT="dist/dmg-root"
        rm -rf "$DMG_ROOT" "$DMG" "${DMG}.sha256"
        mkdir -p "$DMG_ROOT"
        ditto "$BUNDLE" "${DMG_ROOT}/${APP_NAME}.app"
        ln -s /Applications "${DMG_ROOT}/Программы"
        cp Resources/INSTALL.txt "${DMG_ROOT}/как установить.txt"
        hdiutil create \
            -volname "${APP_NAME} ${APP_VERSION}" \
            -srcfolder "$DMG_ROOT" \
            -format UDZO \
            -ov \
            "$DMG" >/dev/null
        rm -rf "$DMG_ROOT"
        shasum -a 256 "$DMG" > "${DMG}.sha256"
        say "Готово: ${DMG} ($(du -h "$DMG" | cut -f1))"
        ;;
esac
