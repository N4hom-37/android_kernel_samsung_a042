#!/bin/bash
set -e

ARCH="${ARCH:-arm64}"
KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-N4hom}"
KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-$(hostname)}"
RDIR="${RDIR:-$(pwd)}"
TC_DIR="${TC_DIR:-${RDIR}/../toolchains}"

# --- Neutron Clang Toolchain config ---
NEUTRON_CLANG_URL="${NEUTRON_CLANG_URL:-https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/download/30072026/neutron-clang-30072026.tar.zst}"

RELEASE_TAG="${RELEASE_TAG:-v1.0.0}"
PUBLISH_RELEASE="${PUBLISH_RELEASE:-false}"
GH_REPO="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"

install_deps() {
  sudo apt update
  sudo apt install -y git lld device-tree-compiler lz4 xz-utils zlib1g-dev \
    openjdk-17-jdk gcc g++ python3 python-is-python3 p7zip-full \
    android-sdk-libsparse-utils erofs-utils default-jdk gnupg flex bison \
    gperf build-essential zip curl libc6-dev libncurses-dev libx11-dev \
    libreadline-dev libgl1 libgl1-mesa-dev make sudo bc grep tofrodos \
    python3-markdown libxml2-utils xsltproc libtinfo5 libtinfo6 repo cpio kmod \
    openssl libelf-dev pahole libssl-dev libarchive-tools zstd rsync
}

derive_toolchain_names() {
  NEUTRON_CLANG_NAME=$(basename "${NEUTRON_CLANG_URL}")
  NEUTRON_CLANG_NAME="${NEUTRON_CLANG_NAME%.tar.zst}"
  NEUTRON_CLANG_VERSION=$(echo "${NEUTRON_CLANG_URL}" | grep -oP '(?<=/download/)[^/]+')
}

download_toolchain() {
  local dest="${TC_DIR}/${NEUTRON_CLANG_NAME}"
  local archive="/tmp/neutron-clang.tar.zst"

  mkdir -p "${TC_DIR}"

  if [ -d "${dest}" ]; then
    echo "✔ Toolchain already present: ${dest}"
    return 0
  fi

  curl -L -o "${archive}" "${NEUTRON_CLANG_URL}"
  tar -xf "${archive}" -C "${TC_DIR}"
  rm -f "${archive}"
}

update_submodules() {
  git submodule sync --recursive
  git submodule update --init --recursive --remote
}

build_kernel() {
  mkdir -p "${RDIR}/out" "${RDIR}/build"

  export PATH="${TC_DIR}/${NEUTRON_CLANG_NAME}/bin:${PATH}"
  export ARGS="-C ${RDIR} O=${RDIR}/out -j$(nproc) ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- LLVM=1 KCFLAGS=-w CONFIG_SECTION_MISMATCH_WARN_ONLY=y"

  local start_time
  start_time=$(date +%s)

  make ${ARGS} a04e_defconfig custom.config droidspaces.config
  make ${ARGS}

  local elapsed_time
  elapsed_time=$(( $(date +%s) - start_time ))
  BUILDTIME=$(printf "%02d:%02d:%02d" \
    $((elapsed_time/3600)) \
    $((elapsed_time%3600/60)) \
    $((elapsed_time%60)))
}

package_anykernel3() {
  VERSION=$(grep -E "^VERSION =" Makefile | awk '{print $3}')
  PATCHLEVEL=$(grep -E "^PATCHLEVEL =" Makefile | awk '{print $3}')
  SUBLEVEL=$(grep -E "^SUBLEVEL =" Makefile | awk '{print $3}')
  LOCALVERSION=$(grep "CONFIG_LOCALVERSION=" "out/.config" | cut -d'"' -f2)
  KVERSION="${VERSION}.${PATCHLEVEL}.${SUBLEVEL}${LOCALVERSION}"

  KSUVAR=$(basename "$(git -C "$(dirname "$(realpath "${RDIR}/drivers/kernelsu")")" config --get remote.origin.url)" | sed 's/\.git$//')
  KSUVER="($(sed -n 's/.*-DKSU_VERSION=//p' "${RDIR}/drivers/kernelsu/Makefile" | tr -d '\r ' | xargs))"

  IMGDIR="${RDIR}/out/arch/arm64/boot"
  IMGFILE="${IMGDIR}/Image"
  AK3_DIR="${IMGDIR}/AnyKernel3"
  AK3_NAME="AnyKernel3-${KVERSION}-${KSUVAR}${KSUVER}"
  AK3_FILE="${AK3_DIR}/${AK3_NAME}.zip"

  rm -rf "${AK3_DIR}"
  git clone --depth=1 https://github.com/N4hom-37/AnyKernel3.git "${AK3_DIR}"
  cp "${IMGFILE}" "${AK3_DIR}/Image"
  (cd "${AK3_DIR}" && zip -r9 "${AK3_NAME}.zip" ./* -x ".*" "*/.*")

  echo "Build complete: ${AK3_FILE}"
  echo "Kernel version: ${KVERSION}"
  echo "KernelSU: ${KSUVAR} ${KSUVER}"
  echo "Build time: ${BUILDTIME}"
  echo "Toolchain: ${NEUTRON_CLANG_NAME}"
}

publish_release() {
  [ "${PUBLISH_RELEASE}" = "true" ] || return 0
  [ -n "${GH_REPO}" ] || {
    echo "GH_REPO/GITHUB_REPOSITORY not set, skipping release publish"
    return 0
  }
  [ -f "${AK3_FILE}" ] || {
    echo "✘ Release: Zip file not found at ${AK3_FILE}"
    exit 1
  }
  command -v gh >/dev/null 2>&1 || {
    echo "✘ GitHub CLI (gh) is required for release publishing"
    exit 1
  }

  if gh release view "${RELEASE_TAG}" --repo "${GH_REPO}" >/dev/null 2>&1; then
    gh release upload "${RELEASE_TAG}" "${AK3_FILE}" \
      --repo "${GH_REPO}" \
      --clobber
  else
    gh release create "${RELEASE_TAG}" "${AK3_FILE}" \
      --repo "${GH_REPO}" \
      --title "${RELEASE_TAG}" \
      --generate-notes
  fi
}

send_telegram() {
  [ -n "${BOT_TOKEN}" ] && [ -n "${CHAT_ID}" ] || return 0

  local branch
  branch="${GITHUB_REF_NAME:-$(git branch --show-current 2>/dev/null || echo "unknown")}" 

  local desc
  desc=$(printf '%s\n' \
    "🛠️ New Kernel Build" \
    "      ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾" \
    ". 📱 Device: Galaxy A04e" \
    ". 📦 Version: ${KVERSION}" \
    ". 🌿 Branch: ${branch}" \
    ". ☯️ Ksu: ${KSUVAR} ${KSUVER}" \
    ". 👤 Author: ${KBUILD_BUILD_USER}" \
    ". 🕒 Build time: ${BUILDTIME}" \
    ". 🔧 Toolchain: ${NEUTRON_CLANG_NAME}" \
    ". 📅 Date: $(date +"%Y-%m-%d %I:%M:%S %p")")

  if curl -s -f \
    -F document=@"${AK3_FILE}" \
    -F caption="${desc}" \
    "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument?chat_id=${CHAT_ID}" > /dev/null; then
    echo "✔ Telegram: Sent successfully."
  else
    echo "✘ Telegram: Failed to send."
  fi
}

main() {
  install_deps
  derive_toolchain_names
  download_toolchain
  update_submodules
  build_kernel
  package_anykernel3
  publish_release
  send_telegram
}

main "$@"
