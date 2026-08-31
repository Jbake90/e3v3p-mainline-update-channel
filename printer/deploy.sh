#!/bin/sh
set -eu

CONTROLLER_ROOT=${CONTROLLER_ROOT:-/usr/data/e3v3p-update-controller}
RELEASE_ROOT=$CONTROLLER_ROOT/release
ACTIVE=/usr/data/klipper-mainline
STATE_ROOT=/usr/data/e3v3p-update-state
BACKUP_ROOT=$STATE_ROOT/backups
SERVICE=/etc/init.d/S55klipper_service
PYTHON=/usr/share/klippy-env/bin/python
CONFIG=/usr/data/printer_data/config/printer.cfg
LOCK=$STATE_ROOT/update.lock
LOG=$STATE_ROOT/update.log

log() {
    mkdir -p "$STATE_ROOT"
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"
}

die() {
    log "BLOCKED $*"
    printf 'BLOCKED: %s\n' "$*" >&2
    exit 2
}

value() {
    awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$2"
}

wait_ready() {
    count=0
    while [ "$count" -lt 60 ]; do
        if "$PYTHON" "$CONTROLLER_ROOT/printer/ready.py" >/dev/null 2>&1; then
            return 0
        fi
        count=$((count + 1))
        sleep 1
    done
    return 1
}

mkdir -p "$STATE_ROOT" "$BACKUP_ROOT"
if ! mkdir "$LOCK" 2>/dev/null; then
    die "another update transaction is already running"
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

[ -x "$SERVICE" ] || die "standard mainline service is missing"
[ -x "$PYTHON" ] || die "Klippy Python is missing"
[ -f "$CONFIG" ] || die "active printer.cfg is missing"
[ -f "$RELEASE_ROOT/SHA256SUMS" ] || die "release checksums are missing"
[ -f "$RELEASE_ROOT/release.manifest" ] || die "release manifest is missing"
[ -f "$RELEASE_ROOT/klipper-runtime.tar.gz" ] || die "release payload is missing"

release_id=$(value release_id "$RELEASE_ROOT/release.manifest")
release_channel=$(value release_channel "$RELEASE_ROOT/release.manifest")
commit=$(value klipper_commit "$RELEASE_ROOT/release.manifest")
expected_helper=$(value c_helper_sha256 "$RELEASE_ROOT/release.manifest")
case "$release_id:$commit:$expected_helper" in
    *[!A-Za-z0-9._:-]*|::*|*::*|*:|:*) die "malformed release manifest" ;;
esac
[ "$release_channel" = production ] || die "candidate releases cannot be installed"
[ "$(value config_validation "$RELEASE_ROOT/release.manifest")" = pass ] || \
    die "release did not pass the exact live-config and MCU-dictionary gate"
[ "$(value mcu_firmware_action "$RELEASE_ROOT/release.manifest")" = none ] || \
    die "this host updater refuses any release containing an MCU firmware action"

if [ -f "$ACTIVE/.e3v3p-release" ] && \
   [ "$(value release_id "$ACTIVE/.e3v3p-release")" = "$release_id" ]; then
    log "NOOP already active release=$release_id"
    exit 0
fi

"$PYTHON" "$CONTROLLER_ROOT/printer/preflight.py" || \
    die "printer is not in the required safe idle state"
(cd "$RELEASE_ROOT" && sha256sum -c SHA256SUMS) || \
    die "release checksum validation failed"

free_kb=$(df -k /usr/data | awk 'NR == 2 {print $4}')
[ "${free_kb:-0}" -ge 65536 ] || die "less than 64 MiB is free on /usr/data"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
stage=$STATE_ROOT/staging-$release_id-$$
backup=$BACKUP_ROOT/$stamp
mkdir -p "$stage" "$backup"
tar -xzf "$RELEASE_ROOT/klipper-runtime.tar.gz" -C "$stage"
[ -f "$stage/klipper/klippy/klippy.py" ] || die "payload has no klippy.py"
[ -f "$stage/klipper/.e3v3p-release" ] || die "payload has no embedded manifest"
[ "$(value release_id "$stage/klipper/.e3v3p-release")" = "$release_id" ] || \
    die "payload and controller release IDs differ"
[ "$(value klipper_commit "$stage/klipper/.e3v3p-release")" = "$commit" ] || \
    die "payload and controller Klipper commits differ"
actual_helper=$(sha256sum "$stage/klipper/klippy/chelper/c_helper.so" | awk '{print $1}')
[ "$actual_helper" = "$expected_helper" ] || die "payload c_helper hash mismatch"
grep -q 'class HX711Quad' "$stage/klipper/klippy/extras/hx71x.py" || \
    die "four-channel HX711 compatibility overlay is absent"
if grep -Eq '^[[:space:]]*sensor_type:[[:space:]]*hx711_quad' "$CONFIG"; then
    grep -q '"hx711_quad"' "$stage/klipper/klippy/extras/hx71x.py" || \
        die "active F001 config is unsupported by this payload"
fi
PYTHONDONTWRITEBYTECODE=1 "$PYTHON" -m py_compile \
    "$stage/klipper/klippy/klippy.py" \
    "$stage/klipper/klippy/extras/hx71x.py" \
    "$stage/klipper/klippy/extras/load_cell.py" \
    "$stage/klipper/klippy/extras/load_cell_probe.py" || \
    die "payload Python validation failed"
"$PYTHON" -c 'import cffi, greenlet, jinja2, numpy' || \
    die "the existing Klippy Python environment lacks required modules"
touch "$stage/klipper/klippy/chelper/c_helper.so"

log "BEGIN release=$release_id commit=$commit backup=$backup"
"$SERVICE" stop || die "could not stop current Klippy"
if [ -e "$ACTIVE" ]; then
    mv "$ACTIVE" "$backup/klipper-mainline.before"
fi
mv "$stage/klipper" "$ACTIVE"

if "$SERVICE" start && wait_ready; then
    cp "$RELEASE_ROOT/release.manifest" "$STATE_ROOT/active-release.manifest"
    printf '%s\n' "$backup" > "$STATE_ROOT/last-backup"
    log "COMMIT release=$release_id commit=$commit mcu_firmware=unchanged"
    exit 0
fi

log "ROLLBACK_START failed_release=$release_id"
"$SERVICE" stop >/dev/null 2>&1 || true
if [ -e "$ACTIVE" ]; then
    mv "$ACTIVE" "$backup/klipper-mainline.failed"
fi
[ -d "$backup/klipper-mainline.before" ] || \
    die "new Klippy failed and the prior tree is unavailable"
mv "$backup/klipper-mainline.before" "$ACTIVE"
"$SERVICE" start || die "rollback Klippy could not be started"
wait_ready || die "rollback Klippy did not return Ready"
log "ROLLBACK_OK failed_release=$release_id restored=$backup"
exit 1
