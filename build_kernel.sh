#!/bin/bash
set -e

ARCH=arm64
KBUILD_BUILD_USER="N4hom"
RDIR="$(pwd)"
TC_DIR="${RDIR}/../toolchains"

GNU_TC_URL="https://github.com/ravindu644/Android-Kernel-Tutorials/releases/download/toolchains/arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz"
CLANG_TC_URL="https://github.com/ravindu644/Android-Kernel-Tutorials/releases/download/toolchains/clang-r383902.tar.gz"
LIBTINFO5_URL="http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2ubuntu0.2_amd64.deb"

RELEASE_TAG="${RELEASE_TAG:-v1.0.0}"
PUBLISH_RELEASE="${PUBLISH_RELEASE:-false}"
GH_REPO="${GH_REPO:-}"
BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"

install_deps() {
  sudo apt update
  sudo apt install -y git lld device-tree-compiler lz4 xz-utils zlib1g-dev \
    openjdk-17-jdk gcc g++ python3 python-is-python3 p7zip-full \
    android-sdk-libsparse-utils erofs-utils default-jdk gnupg flex bison \
    gperf build-essential zip curl libc6-dev libncurses-dev libx11-dev \
    libreadline-dev libgl1 libgl1-mesa-dev make sudo bc grep tofrodos \
    python3-markdown libxml2-utils xsltproc libtinfo6 repo cpio kmod \
    openssl libelf-dev pahole libssl-dev libarchive-tools zstd rsync

  curl -Lo /tmp/libtinfo5.deb "${LIBTINFO5_URL}" && sudo apt install -y /tmp/libtinfo5.deb && rm -f /tmp/libtinfo5.deb
}

derive_toolchain_names() {
  GNU_TC_NAME=$(basename "${GNU_TC_URL}"); GNU_TC_NAME="${GNU_TC_NAME%.tar.xz}"
  CLANG_TC_NAME=$(basename "${CLANG_TC_URL}"); CLANG_TC_NAME="${CLANG_TC_NAME%.tar.gz}"
}

fetch_toolchain() {
  local url="$1" dest="$2" archive="$3" strip_gz="$4"
  [ -d "${dest}" ] && return 0
  curl -L -o "${archive}" "${url}"
  if [ "${strip_gz}" = "gz" ]; then
    mkdir -p "${dest}"; tar -xzf "${archive}" -C "${dest}"
  else
    tar -xf "${archive}" -C "${TC_DIR}"
  fi
}

download_toolchains() {
  mkdir -p "${TC_DIR}"
  fetch_toolchain "${GNU_TC_URL}" "${TC_DIR}/${GNU_TC_NAME}" /tmp/arm-gnu.tar.xz
  fetch_toolchain "${CLANG_TC_URL}" "${TC_DIR}/${CLANG_TC_NAME}" /tmp/clang.tar.gz gz
}

build_kernel() {
  mkdir -p "${RDIR}/out" "${RDIR}/build"
  local cross="${TC_DIR}/${GNU_TC_NAME}/bin/aarch64-none-linux-gnu-"
  local cc="${TC_DIR}/${CLANG_TC_NAME}/bin/clang"
  local args="-C ${RDIR} O=${RDIR}/out -j$(nproc) ARCH=arm64 CROSS_COMPILE=${cross} CC=${cc} CLANG_TRIPLE=aarch64-linux-gnu- KCFLAGS=-w CONFIG_SECTION_MISMATCH_WARN_ONLY=y"

  local t0=$(date +%s)
  make ${args} a04e_defconfig custom.config
  make ${args}
  local d=$(( $(date +%s) - t0 ))
  BUILDTIME=$(printf "%02d:%02d:%02d" $((d/3600)) $((d%3600/60)) $((d%60)))
}

package_anykernel3() {
  VERSION=$(awk '/^VERSION =/{print $3}' Makefile)
  PATCHLEVEL=$(awk '/^PATCHLEVEL =/{print $3}' Makefile)
  SUBLEVEL=$(awk '/^SUBLEVEL =/{print $3}' Makefile)
  LOCALVERSION=$(grep "CONFIG_LOCALVERSION=" "out/.config" | cut -d'"' -f2)
  KVERSION="${VERSION}.${PATCHLEVEL}.${SUBLEVEL}${LOCALVERSION}"

  IMGDIR="${RDIR}/out/arch/arm64/boot"
  AK3_DIR="${IMGDIR}/AnyKernel3"
  AK3_NAME="AnyKernel3-${KVERSION}"
  AK3_FILE="${AK3_DIR}/${AK3_NAME}.zip"

  git clone --depth=1 https://github.com/N4hom-37/AnyKernel3.git "${AK3_DIR}"
  cp "${IMGDIR}/Image" "${AK3_DIR}/Image"
  (cd "${AK3_DIR}" && zip -r9 "${AK3_NAME}.zip" ./* -x ".*" "*/.*")

  echo "Build complete: ${AK3_FILE}"
  echo "Kernel version: ${KVERSION}"
  echo "Build time: ${BUILDTIME}"
}

publish_release() {
  [ "${PUBLISH_RELEASE}" = "true" ] || return 0
  [ -n "${GH_REPO}" ] || { echo "GH_REPO not set, skipping release publish"; return 0; }
  [ -f "${AK3_FILE}" ] || { echo "✘ Release: Zip file not found at ${AK3_FILE}"; exit 1; }

  if gh release view "${RELEASE_TAG}" --repo "${GH_REPO}" >/dev/null 2>&1; then
    gh release upload "${RELEASE_TAG}" "${AK3_FILE}" --repo "${GH_REPO}" --clobber
  else
    gh release create "${RELEASE_TAG}" "${AK3_FILE}" --repo "${GH_REPO}" --title "${RELEASE_TAG}" --generate-notes
  fi
}

send_telegram() {
  [ -n "${BOT_TOKEN}" ] && [ -n "${CHAT_ID}" ] || return 0
  local branch=$(git branch --show-current 2>/dev/null || echo "unknown")
  local desc
  desc=$(printf '%s\n' \
    "🛠️ New Kernel Build" \
    "      ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾" \
    ". 📱 Device: Galaxy A04e" \
    ". 📦 Version: ${KVERSION}" \
    ". 🌿 Branch: ${branch}" \
    ". 👤 Author: ${KBUILD_BUILD_USER}" \
    ". 🕒 Build time: ${BUILDTIME}" \
    ". 📅 Date: $(date +"%Y-%m-%d %I:%M:%S %p")")

  if curl -s -f -F document=@"${AK3_FILE}" -F caption="${desc}" \
    "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument?chat_id=${CHAT_ID}" > /dev/null; then
    echo "✔ Telegram: Sent successfully."
  else
    echo "✘ Telegram: Failed to send."
  fi
}

main() {
  install_deps
  derive_toolchain_names
  download_toolchains
  build_kernel
  package_anykernel3
  publish_release
  send_telegram
}

main "$@"
