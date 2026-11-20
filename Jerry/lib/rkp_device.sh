# shellcheck shell=sh
# Device RKP Issuer backend: wraps dex/duckd, built from upstream source with ONLY the
# rkp-device cargo feature enabled (no Play Integrity / Tricky Store / kernel-modules etc).
# arm64-v8a only — the upstream binary is not built for v7a/x86_64.

RKP_DEVICE_DATA_ROOT="/data/adb/JerryManager/rkp_device"
RKP_DEVICE_OUTPUT="$RKP_DEVICE_DATA_ROOT/keybox.xml"

# True if this device's ABI can run the vendored binary.
rkp_device_supported() {
    [ "$(uname -m 2>/dev/null)" = "aarch64" ]
}

# BBIN ("<root>/bin") is set by lib/paths.sh, sourced before this file — reuse its root
# rather than re-deriving MODDIR, since duckd lives in dex/, not bin/.
_rkp_device_bin() {
    printf '%s' "${BBIN%/bin}/dex/duckd"
}

# Run one duckd rkp-device subcommand with isolated root/data paths (never touches
# /data/adb/duck-toolbox). Prints duckd's JSON envelope on stdout; mirrors its exit code.
_rkp_device_run() {
    [ -x "$(_rkp_device_bin)" ] || { echo '{"ok":false,"error":{"code":"binary_missing"}}'; return 1; }
    ensure_dir "$RKP_DEVICE_DATA_ROOT"
    DUCK_TOOLBOX_ROOT="$RKP_DEVICE_DATA_ROOT" \
    DUCK_TOOLBOX_DATA_ROOT="$RKP_DEVICE_DATA_ROOT" \
        "$(_rkp_device_bin)" rkp-device "$@"
}

# JSON envelope: prerequisites_met, android_arm64, root, qualcomm_soc, mediatek_soc,
# v1_available, v1_native_available, v2_available, blockers[], etc.
rkp_device_status() {
    rkp_device_supported || { echo '{"ok":false,"error":{"code":"arch_unsupported"}}'; return 1; }
    _rkp_device_run status
}

# protocol: auto | v1 | v2 | v1-native. Writes keybox.xml to $RKP_DEVICE_OUTPUT on success.
# --acknowledge-limitations is always passed here, not left to the caller: the WebUI shows
# the "only some devices work, only RKP certs are issued" dialog BEFORE calling this at all.
rkp_device_provision() {
    _rdp_protocol="${1:-auto}"
    rkp_device_supported || { unset _rdp_protocol; return 2; }
    ensure_dir "$RKP_DEVICE_DATA_ROOT"
    _rkp_device_run provision \
        --protocol "$_rdp_protocol" \
        --acknowledge-limitations \
        --output "$RKP_DEVICE_OUTPUT"
    _rdp_rc=$?
    unset _rdp_protocol
    return "$_rdp_rc"
}
