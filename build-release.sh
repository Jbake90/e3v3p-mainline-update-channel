#!/usr/bin/env bash
set -euo pipefail

UPDATER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${UPDATER_ROOT}/.." && pwd)"
KLIPPER_REPO="${KLIPPER_REPO:-${PROJECT_ROOT}/klipper-source}"
C_HELPER="${C_HELPER:-${PROJECT_ROOT}/tools/host-build/out/c_helper.so}"
OUT_DIR="${OUT_DIR:-${UPDATER_ROOT}/release}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-candidate}"
RELEASE_REVISION="${RELEASE_REVISION:-2}"
CONFIG_VALIDATION="${CONFIG_VALIDATION:-not-run}"
VALIDATED_CONFIG_SHA256="${VALIDATED_CONFIG_SHA256:-unknown}"
MAIN_MCU_DICT_SHA256="${MAIN_MCU_DICT_SHA256:-unknown}"
NOZZLE_MCU_DICT_SHA256="${NOZZLE_MCU_DICT_SHA256:-unknown}"
LEVELING_MCU_DICT_SHA256="${LEVELING_MCU_DICT_SHA256:-unknown}"
LOCK="$(tr -d '[:space:]' < "${UPDATER_ROOT}/upstream-klipper.lock")"
EXPECTED_HX="$(awk '{print $1}' "${UPDATER_ROOT}/compatibility/hx71x.upstream.sha256")"

die() {
  echo "BLOCKED: $*" >&2
  exit 2
}

for cmd in git tar sha256sum readelf python3 mktemp; do
  command -v "${cmd}" >/dev/null 2>&1 || die "missing ${cmd}"
done
[ -d "${KLIPPER_REPO}/.git" ] || die "not a Klipper git repository: ${KLIPPER_REPO}"
git -C "${KLIPPER_REPO}" cat-file -e "${LOCK}^{commit}" || \
  die "locked Klipper commit is not available: ${LOCK}"
[ -f "${C_HELPER}" ] || die "missing X2000E c_helper.so: ${C_HELPER}"

abi_version="$(readelf -h "${C_HELPER}" | awk -F: '/ABI Version/ {gsub(/ /, "", $2); print $2}')"
[ "${abi_version}" = 3 ] || die "c_helper has X2000E-incompatible ELF ABI version ${abi_version}"
readelf -h "${C_HELPER}" | grep -q 'Flags:.*nan2008.*o32.*mips32r2' || \
  die "c_helper does not match the proven X2000E MIPS ABI"
readelf -d "${C_HELPER}" | grep -q '(HASH)' || die "c_helper lacks a SysV hash table"
! readelf -d "${C_HELPER}" | grep -q 'MIPS_XHASH' || \
  die "c_helper uses MIPS_XHASH, which Creality glibc 2.29 cannot load"
case "${RELEASE_CHANNEL}" in
  candidate) ;;
  production)
    [ "${CONFIG_VALIDATION}" = pass ] || die "production release lacks config validation"
    for hash in "${VALIDATED_CONFIG_SHA256}" "${MAIN_MCU_DICT_SHA256}" \
      "${NOZZLE_MCU_DICT_SHA256}" "${LEVELING_MCU_DICT_SHA256}"; do
      case "${hash}" in ''|*[!0-9a-f]*)
        die "production release has an invalid validation hash" ;;
      esac
      [ "${#hash}" -eq 64 ] || die "production validation hash is not SHA256"
    done
    ;;
  *) die "unknown release channel: ${RELEASE_CHANNEL}" ;;
esac

work="$(mktemp -d "${TMPDIR:-/tmp}/e3v3p-release.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
tree="${work}/tree"
runtime="${work}/runtime"
mkdir -p "${tree}" "${runtime}/klipper/klippy" \
  "${runtime}/klipper/config" "${runtime}/klipper/docs" "${OUT_DIR}"
git -C "${KLIPPER_REPO}" archive "${LOCK}" | tar -xf - -C "${tree}"

actual_hx="$(sha256sum "${tree}/klippy/extras/hx71x.py" | awk '{print $1}')"
[ "${actual_hx}" = "${EXPECTED_HX}" ] || \
  die "upstream hx71x.py changed; rebase and recommission the four-channel overlay"
install -m 0644 "${UPDATER_ROOT}/compatibility/hx71x.py" \
  "${tree}/klippy/extras/hx71x.py"
install -m 0644 "${C_HELPER}" "${tree}/klippy/chelper/c_helper.so"

version="$(git -C "${KLIPPER_REPO}" describe --always --tags "${LOCK}")-e3v3p-f001"
printf '%s\n' "${version}" > "${tree}/klippy/.version"
python3 -m py_compile \
  "${tree}/klippy/klippy.py" \
  "${tree}/klippy/extras/hx71x.py" \
  "${tree}/klippy/extras/load_cell.py" \
  "${tree}/klippy/extras/load_cell_probe.py"
find "${tree}" -type d -name __pycache__ -prune -exec rm -rf {} +

cp -a "${tree}/klippy/." "${runtime}/klipper/klippy/"
install -m 0644 "${tree}/COPYING" "${runtime}/klipper/COPYING"
install -m 0644 "${tree}/scripts/klippy-requirements.txt" \
  "${runtime}/klipper/klippy-requirements.txt"
printf '%s\n' 'Runtime-only host release; examples remain in the source repository.' \
  > "${runtime}/klipper/config/README"
printf '%s\n' 'Runtime-only host release; documentation remains in the source repository.' \
  > "${runtime}/klipper/docs/README"

release_id="e3v3p-klipper-${LOCK:0:12}-r${RELEASE_REVISION}"
c_helper_sha="$(sha256sum "${C_HELPER}" | awk '{print $1}')"
overlay_sha="$(sha256sum "${UPDATER_ROOT}/compatibility/hx71x.py" | awk '{print $1}')"
requirements_sha="$(sha256sum "${tree}/scripts/klippy-requirements.txt" | awk '{print $1}')"
chelper_tree="$(git -C "${KLIPPER_REPO}" rev-parse "${LOCK}:klippy/chelper")"
cat > "${runtime}/klipper/.e3v3p-release" <<EOF
schema=1
release_id=${release_id}
release_channel=${RELEASE_CHANNEL}
klipper_commit=${LOCK}
klipper_version=${version}
chelper_tree=${chelper_tree}
c_helper_sha256=${c_helper_sha}
hx711_quad_overlay_sha256=${overlay_sha}
requirements_sha256=${requirements_sha}
config_validation=${CONFIG_VALIDATION}
validated_config_sha256=${VALIDATED_CONFIG_SHA256}
main_mcu_dict_sha256=${MAIN_MCU_DICT_SHA256}
nozzle_mcu_dict_sha256=${NOZZLE_MCU_DICT_SHA256}
leveling_mcu_dict_sha256=${LEVELING_MCU_DICT_SHA256}
mcu_firmware_action=none
EOF

manifest_tmp="${work}/release.manifest"
cp "${runtime}/klipper/.e3v3p-release" "${manifest_tmp}"
printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${manifest_tmp}"

archive_tmp="${work}/klipper-runtime.tar.gz"
tar --sort=name --mtime="@$(git -C "${KLIPPER_REPO}" show -s --format=%ct "${LOCK}")" \
  --owner=0 --group=0 --numeric-owner -czf "${archive_tmp}" -C "${runtime}" klipper
install -m 0644 "${archive_tmp}" "${OUT_DIR}/klipper-runtime.tar.gz"
install -m 0644 "${manifest_tmp}" "${OUT_DIR}/release.manifest"
(
  cd "${OUT_DIR}"
  sha256sum klipper-runtime.tar.gz release.manifest > SHA256SUMS
  sha256sum -c SHA256SUMS
)

echo "PASS: ${release_id}"
echo "Klipper: ${LOCK}"
echo "Payload: ${OUT_DIR}/klipper-runtime.tar.gz"
echo "MCU firmware: unchanged"
