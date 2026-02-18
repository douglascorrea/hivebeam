#!/usr/bin/env sh
set -eu

REPO="douglascorrea/hivebeam"
VERSION="latest"
INSTALL_ROOT="${HOME}/.local/hivebeam"
BIN_DIR="${HOME}/.local/bin"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      REPO="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --install-root)
      INSTALL_ROOT="$2"
      shift 2
      ;;
    --bin-dir)
      BIN_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH_RAW="$(uname -m)"

case "$ARCH_RAW" in
  x86_64|amd64)
    ARCH="amd64"
    ;;
  aarch64|arm64)
    ARCH="arm64"
    ;;
  *)
    echo "Unsupported architecture: ${ARCH_RAW}" >&2
    exit 1
    ;;
esac

if [ "$VERSION" = "latest" ]; then
  BASE_URL="https://github.com/${REPO}/releases/latest/download"
  RELEASE_TAG="latest"
else
  RELEASE_TAG="v${VERSION}"
  BASE_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
fi

ARCHIVE="hivebeam-${OS}-${ARCH}.tar.gz"
CHECKSUM_FILE="${ARCHIVE}.sha256"
TMP_DIR="$(mktemp -d)"
ARCHIVE_PATH="${TMP_DIR}/${ARCHIVE}"
CHECKSUM_PATH="${TMP_DIR}/${CHECKSUM_FILE}"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

download() {
  url="$1"
  out="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    echo "curl or wget is required" >&2
    exit 1
  fi
}

download "${BASE_URL}/${ARCHIVE}" "$ARCHIVE_PATH"
download "${BASE_URL}/${CHECKSUM_FILE}" "$CHECKSUM_PATH"

EXPECTED_SUM="$(awk '{print $1}' "$CHECKSUM_PATH")"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SUM="$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')"
else
  ACTUAL_SUM="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
fi

if [ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]; then
  echo "Checksum mismatch for ${ARCHIVE}" >&2
  exit 1
fi

TARGET_DIR="${INSTALL_ROOT}/releases/${RELEASE_TAG}"
CURRENT_LINK="${INSTALL_ROOT}/current"

mkdir -p "$TARGET_DIR" "$BIN_DIR"

tar -xzf "$ARCHIVE_PATH" -C "$TARGET_DIR"
ln -sfn "$TARGET_DIR" "$CURRENT_LINK"

cat > "${BIN_DIR}/hivebeam" <<SCRIPT
#!/usr/bin/env sh
exec "${CURRENT_LINK}/bin/hivebeam" "\$@"
SCRIPT
chmod +x "${BIN_DIR}/hivebeam"

echo "Installed Hivebeam ${RELEASE_TAG} to ${TARGET_DIR}"
echo "Ensure ${BIN_DIR} is in PATH"
