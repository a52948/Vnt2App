#!/usr/bin/env bash
set -euo pipefail

BUNDLE_PATH="${1:-build/linux/x64/release/bundle}"
APPIMAGE_ARCH="${2:-x86_64}"
OUTPUT_PATH="${3:-vnt2_app-linux-${APPIMAGE_ARCH}.AppImage}"

if [[ ! -x "${BUNDLE_PATH}/vnt2_app" ]]; then
  echo "Linux bundle not found: ${BUNDLE_PATH}" >&2
  echo "Run 'flutter build linux --release' before packaging." >&2
  exit 1
fi

case "${APPIMAGE_ARCH}" in
  x86_64|aarch64) ;;
  *)
    echo "Unsupported AppImage architecture: ${APPIMAGE_ARCH}" >&2
    exit 1
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_PATH="$(realpath "${BUNDLE_PATH}")"
OUTPUT_PATH="$(realpath -m "${OUTPUT_PATH}")"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

APP_DIR="${WORK_DIR}/AppDir"
TOOL_IMAGE="${WORK_DIR}/appimagetool.AppImage"
TOOL_DIR="${WORK_DIR}/squashfs-root"
TOOL_URL="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${APPIMAGE_ARCH}.AppImage"

echo "Downloading appimagetool for ${APPIMAGE_ARCH}"
wget --quiet --output-document="${TOOL_IMAGE}" "${TOOL_URL}"
chmod +x "${TOOL_IMAGE}"
(
  cd "${WORK_DIR}"
  "${TOOL_IMAGE}" --appimage-extract >/dev/null
)

echo "Preparing AppDir from ${BUNDLE_PATH}"
mkdir -p "${APP_DIR}/usr/share/icons/hicolor/256x256/apps"
cp -a "${BUNDLE_PATH}/." "${APP_DIR}/"
cp "${ROOT_DIR}/assets/app_icon.png" "${APP_DIR}/vnt2_app.png"
cp "${ROOT_DIR}/assets/app_icon.png" \
  "${APP_DIR}/usr/share/icons/hicolor/256x256/apps/vnt2_app.png"

cat >"${APP_DIR}/vnt2_app.desktop" <<'EOF'
[Desktop Entry]
Name=VNT App
Exec=vnt2_app
Icon=vnt2_app
Type=Application
Categories=Network;
EOF

cat >"${APP_DIR}/AppRun" <<'EOF'
#!/usr/bin/env bash
set -e

HERE="$(dirname "$(readlink -f "$0")")"

if [[ "$(id -u)" -ne 0 ]]; then
  SELF="${APPIMAGE:-$(readlink -f "$0")}"
  exec pkexec /usr/bin/env \
    DISPLAY="${DISPLAY:-}" \
    XAUTHORITY="${XAUTHORITY:-}" \
    DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
    WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
    "${SELF}" "$@"
fi

exec "${HERE}/vnt2_app" "$@"
EOF
chmod +x "${APP_DIR}/AppRun"

echo "Creating ${OUTPUT_PATH}"
ARCH="${APPIMAGE_ARCH}" "${TOOL_DIR}/AppRun" "${APP_DIR}" "${OUTPUT_PATH}"
chmod +x "${OUTPUT_PATH}"
echo "Created ${OUTPUT_PATH}"
