#!/usr/bin/env sh
set -eu

REPO="douglascorrea/hivebeam"
VERSION="latest"
INSTALL_ROOT="${HOME}/.local/hivebeam"
BIN_DIR="${HOME}/.local/bin"
BUILD_FROM_SOURCE="${HIVEBEAM_INSTALL_SOURCE_FALLBACK:-1}"
VERBOSE_DOWNLOAD_ERRORS="${HIVEBEAM_INSTALL_VERBOSE_DOWNLOAD:-0}"

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
    --no-source-fallback)
      BUILD_FROM_SOURCE="0"
      shift 1
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
SOURCE_PATH="${TMP_DIR}/hivebeam-source"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

download() {
  url="$1"
  out="$2"

  if command -v curl >/dev/null 2>&1; then
    if [ "$VERBOSE_DOWNLOAD_ERRORS" = "1" ]; then
      curl -fsSL "$url" -o "$out"
    else
      curl -fsSL "$url" -o "$out" 2>/dev/null
    fi
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url" 2>/dev/null
  else
    echo "curl or wget is required" >&2
    exit 1
  fi
}

ensure_build_deps() {
  if command -v mix >/dev/null 2>&1 && command -v elixir >/dev/null 2>&1; then
    return 0
  fi

  case "$OS" in
    darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install elixir
      else
        echo "Elixir is required. Install Homebrew then run: brew install elixir" >&2
        return 1
      fi
      ;;
    linux)
      if command -v apt-get >/dev/null 2>&1; then
        if command -v sudo >/dev/null 2>&1; then
          sudo apt-get update
          sudo apt-get install -y elixir erlang
        else
          apt-get update
          apt-get install -y elixir erlang
        fi
      elif command -v dnf >/dev/null 2>&1; then
        if command -v sudo >/dev/null 2>&1; then
          sudo dnf install -y elixir erlang
        else
          dnf install -y elixir erlang
        fi
      elif command -v yum >/dev/null 2>&1; then
        if command -v sudo >/dev/null 2>&1; then
          sudo yum install -y elixir erlang
        else
          yum install -y elixir erlang
        fi
      elif command -v pacman >/dev/null 2>&1; then
        if command -v sudo >/dev/null 2>&1; then
          sudo pacman -Sy --noconfirm elixir erlang
        else
          pacman -Sy --noconfirm elixir erlang
        fi
      else
        echo "Could not auto-install Elixir on this Linux distro. Install elixir + erlang and retry." >&2
        return 1
      fi
      ;;
    *)
      echo "Unsupported OS for source fallback: ${OS}" >&2
      return 1
      ;;
  esac
}

install_from_source() {
  ensure_build_deps

  if ! command -v git >/dev/null 2>&1; then
    echo "git is required for source fallback installation" >&2
    exit 1
  fi

  if [ "$VERSION" = "latest" ]; then
    git clone --depth 1 "https://github.com/${REPO}.git" "$SOURCE_PATH"
    RELEASE_TAG="source-latest"
  else
    git clone --depth 1 --branch "$RELEASE_TAG" "https://github.com/${REPO}.git" "$SOURCE_PATH"
    RELEASE_TAG="source-${RELEASE_TAG}"
  fi

  (
    cd "$SOURCE_PATH"
    mix local.hex --force
    mix local.rebar --force
    MIX_ENV=prod mix deps.get
    MIX_ENV=prod mix compile
    MIX_ENV=prod mix release hivebeam
  )

  TARGET_DIR="${INSTALL_ROOT}/releases/${RELEASE_TAG}"
  CURRENT_LINK="${INSTALL_ROOT}/current"
  rm -rf "$TARGET_DIR"
  mkdir -p "$TARGET_DIR" "$BIN_DIR"
  cp -R "$SOURCE_PATH/_build/prod/rel/hivebeam/." "$TARGET_DIR"
  ln -sfn "$TARGET_DIR" "$CURRENT_LINK"
}

install_from_prebuilt() {
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
  rm -rf "$TARGET_DIR"
  mkdir -p "$TARGET_DIR" "$BIN_DIR"
  tar -xzf "$ARCHIVE_PATH" -C "$TARGET_DIR"
  ln -sfn "$TARGET_DIR" "$CURRENT_LINK"
}

PREBUILT_OK=1
if ! download "${BASE_URL}/${ARCHIVE}" "$ARCHIVE_PATH"; then
  PREBUILT_OK=0
fi
if [ "$PREBUILT_OK" -eq 1 ] && ! download "${BASE_URL}/${CHECKSUM_FILE}" "$CHECKSUM_PATH"; then
  PREBUILT_OK=0
fi

if [ "$PREBUILT_OK" -eq 1 ]; then
  install_from_prebuilt
elif [ "$BUILD_FROM_SOURCE" = "1" ]; then
  echo "Prebuilt asset ${ARCHIVE} not found; building from source..." >&2
  install_from_source
else
  echo "Prebuilt asset ${ARCHIVE} not found and source fallback disabled." >&2
  exit 1
fi

cat > "${BIN_DIR}/hivebeam" <<SCRIPT
#!/usr/bin/env sh
exec "${CURRENT_LINK}/bin/hivebeam" "\$@"
SCRIPT
chmod +x "${BIN_DIR}/hivebeam"

echo "Installed Hivebeam ${RELEASE_TAG} to ${TARGET_DIR}"
echo "Ensure ${BIN_DIR} is in PATH"
