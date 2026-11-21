# shellcheck shell=sh
# Keystore backend: built-in Tricky Store OSS (files live in /data/adb/tricky_store).

# Helper libraries (MODDIR is the module root or features/)
for _ks_lib in inplace; do
    for _ks_dir in "$MODDIR/lib" "$MODDIR/../lib" "$MODPATH/lib"; do
        [ -f "$_ks_dir/$_ks_lib.sh" ] && { . "$_ks_dir/$_ks_lib.sh"; break; }
    done
done
unset _ks_dir _ks_lib

resolve_keystore_backend() {
    KEYSTORE_BACKEND="trickystore"
    KEYSTORE_NAME="Tricky Store OSS"
    KEYSTORE_DIR="$TRICKY_DIR"
    KEYSTORE_KEYBOX="$TARGET_FILE"
    KEYSTORE_BACKUP="$BACKUP_FILE"
    KEYSTORE_TARGETS="$TARGET_TXT"
    KEYSTORE_SECURITY="$SECURITY_PATCH_FILE"
    KEYSTORE_FORMAT="flat"
    export KEYSTORE_BACKEND KEYSTORE_NAME KEYSTORE_DIR KEYSTORE_KEYBOX \
           KEYSTORE_TARGETS KEYSTORE_SECURITY KEYSTORE_FORMAT
}


keystore_ready() {
    [ "$KEYSTORE_BACKEND" != "none" ] && [ -n "$KEYSTORE_DIR" ] && [ -d "$KEYSTORE_DIR" ]
}

# --- Security patch date, written in whatever format the backend expects ---
_keystore_write_security_patch_nolock() {
    _kwsp_os="$1" _kwsp_boot="${2:-$1}" _kwsp_vendor="${3:-$1}"
    [ -n "$_kwsp_os" ] || { unset _kwsp_os _kwsp_boot _kwsp_vendor; return 1; }

    case "$KEYSTORE_FORMAT" in
        flat)
            ensure_dir "$(dirname "$KEYSTORE_SECURITY")"
            # Per-app [package] sections (keystore_set_per_app_patch) live in the same file; keep them
            _kwsp_sections=""
            [ -f "$KEYSTORE_SECURITY" ] && _kwsp_sections=$(awk '/^[[:space:]]*\[/ { emit = 1 } emit { print }' "$KEYSTORE_SECURITY" 2>/dev/null)
            {
                printf 'system=%s\nboot=%s\nvendor=%s\n' "$_kwsp_os" "$_kwsp_boot" "$_kwsp_vendor"
                # if, not &&: an empty section list must not turn the whole write into a failure
                if [ -n "$_kwsp_sections" ]; then printf '\n%s\n' "$_kwsp_sections"; fi
            } > "$KEYSTORE_SECURITY"
            _kwsp_status=$?
            unset _kwsp_sections
            ;;
        *)
            unset _kwsp_os _kwsp_boot _kwsp_vendor
            return 1
            ;;
    esac

    unset _kwsp_os _kwsp_boot _kwsp_vendor
    return "$_kwsp_status"
}

# --- Target/injector list: add a package to the always-spoof list ---
_keystore_add_target_nolock() {
    _kat_pkg="$1" _kat_suffix="${2:-}"
    [ -n "$_kat_pkg" ] || { unset _kat_pkg _kat_suffix; return 1; }

    case "$KEYSTORE_FORMAT" in
        flat)
            ensure_dir "$KEYSTORE_DIR"
            touch "$KEYSTORE_TARGETS"
            if ! grep -Fqx -e "${_kat_pkg}" -e "${_kat_pkg}!" -e "${_kat_pkg}?" "$KEYSTORE_TARGETS" 2>/dev/null; then
                if grep -qE '^[[:space:]]*\[' "$KEYSTORE_TARGETS" 2>/dev/null; then
                    # the list lives above the first [package] section; appending would put it inside that section
                    _kat_tmp="${KEYSTORE_TARGETS}.add.$$"
                    awk -v e="${_kat_pkg}${_kat_suffix}" '!d && /^[ \t]*\[/ { print e; d = 1 } { print }' "$KEYSTORE_TARGETS" > "$_kat_tmp" 2>/dev/null
                    _ks_commit "$KEYSTORE_TARGETS" "$_kat_tmp" || { rm -f "$_kat_tmp"; unset _kat_pkg _kat_suffix _kat_tmp; return 1; }
                    rm -f "$_kat_tmp"; unset _kat_tmp
                else
                    if [ -s "$KEYSTORE_TARGETS" ] && [ -n "$(tail -c1 "$KEYSTORE_TARGETS" 2>/dev/null)" ]; then
                        echo >> "$KEYSTORE_TARGETS"
                    fi
                    echo "${_kat_pkg}${_kat_suffix}" >> "$KEYSTORE_TARGETS"
                fi
            fi
            ;;
        *)
            unset _kat_pkg _kat_suffix
            return 1
            ;;
    esac

    unset _kat_pkg _kat_suffix
    return 0
}

# --- Target/injector list: remove a package (counterpart of keystore_add_target) ---
# Optional 2nd arg SCOPE is accepted for compatibility and ignored.
_keystore_remove_target_nolock() {
    _krt_pkg="$1" _krt_scope="${2:-default}"
    [ -n "$_krt_pkg" ] || { unset _krt_pkg; return 1; }
    [ -f "$KEYSTORE_TARGETS" ] || { unset _krt_pkg; return 0; }

    case "$KEYSTORE_FORMAT" in
        flat)
            grep -Fqx -e "$_krt_pkg" -e "${_krt_pkg}!" -e "${_krt_pkg}?" "$KEYSTORE_TARGETS" 2>/dev/null || { unset _krt_pkg; return 0; }
            _krt_tmp="${KEYSTORE_TARGETS}.tmp.$$"
            grep -Fvx -e "$_krt_pkg" -e "${_krt_pkg}!" -e "${_krt_pkg}?" "$KEYSTORE_TARGETS" > "$_krt_tmp" 2>/dev/null
            # grep exits 1 when every line was removed; an empty result is still valid
            cat "$_krt_tmp" > "$KEYSTORE_TARGETS" 2>/dev/null
            rm -f "$_krt_tmp"
            unset _krt_tmp
            ;;
        *)
            unset _krt_pkg _krt_scope
            return 1
            ;;
    esac

    unset _krt_pkg _krt_scope
    return 0
}

# --- Keybox install: copy a decoded keybox.xml to wherever the backend wants it ---
# Keybox sanity check, same for every backend. Hard failures: empty file, no <Keybox>, no private key,
# no certificate chain, BOM / zero-width characters (watermarks), neither an EC nor an RSA key.
# A missing EC or RSA key alone is only a warning (RKP keyboxes are EC only).
keystore_validate_keybox() {
    _kvk_f="$1"
    [ -s "$_kvk_f" ] || { log "KEYBOX" "Invalid keybox: file is empty"; return 1; }
    grep -qi '<Keybox' "$_kvk_f" 2>/dev/null || { log "KEYBOX" "Invalid keybox: no <Keybox> element"; return 1; }
    grep -q 'BEGIN .*PRIVATE KEY' "$_kvk_f" 2>/dev/null || { log "KEYBOX" "Invalid keybox: private key missing"; return 1; }
    grep -q 'BEGIN CERTIFICATE' "$_kvk_f" 2>/dev/null || { log "KEYBOX" "Invalid keybox: certificate chain missing"; return 1; }
    _kvk_bom=$(printf '\357\273\277'); _kvk_zws=$(printf '\342\200\213'); _kvk_zwj=$(printf '\342\200\215')
    if grep -qF -e "$_kvk_bom" -e "$_kvk_zws" -e "$_kvk_zwj" "$_kvk_f" 2>/dev/null; then
        log "KEYBOX" "Invalid keybox: invisible characters found (BOM / zero-width)"
        unset _kvk_f _kvk_bom _kvk_zws _kvk_zwj
        return 1
    fi
    unset _kvk_bom _kvk_zws _kvk_zwj
    # RKP keyboxes ship EC only, so one missing key is just a warning on every backend
    _kvk_n=0
    for _kvk_alg in ecdsa rsa; do
        if grep -qi "algorithm=[\"']$_kvk_alg[\"']" "$_kvk_f" 2>/dev/null; then
            _kvk_n=$((_kvk_n + 1))
        elif [ "$_kvk_alg" != "rsa" ] || [ "$_kvk_n" -eq 0 ]; then
            log "KEYBOX" "Warning: keybox has no $_kvk_alg key"
        fi
    done
    if [ "$_kvk_n" -eq 0 ]; then
        log "KEYBOX" "Invalid keybox: no ecdsa or rsa key"
        unset _kvk_f _kvk_alg _kvk_n
        return 1
    fi
    unset _kvk_n
    unset _kvk_f _kvk_alg
    return 0
}

# Install a decoded keybox.xml for the active backend (all backends share this path)
keystore_install_keybox() {
    _kik_src="$1"
    [ -f "$_kik_src" ] || { unset _kik_src; return 1; }
    [ -n "$KEYSTORE_KEYBOX" ] || { unset _kik_src; return 1; }
    keystore_validate_keybox "$_kik_src" || { unset _kik_src; return 1; }

    ensure_dir "$(dirname "$KEYSTORE_KEYBOX")"
    # Overwriting an existing file keeps its inode, owner, mode and SELinux label (same as a manual copy)
    _kik_new=0
    [ -f "$KEYSTORE_KEYBOX" ] || _kik_new=1
    cp "$_kik_src" "$KEYSTORE_KEYBOX" 2>/dev/null
    _kik_status=$?


    unset _kik_src _kik_new
    return "$_kik_status"
}

# --- Read back which keybox file is actually active, for status/UI display ---
keystore_keybox_status() {
    if [ -n "$KEYSTORE_KEYBOX" ] && [ -f "$KEYSTORE_KEYBOX" ]; then
        echo "present"
    else
        echo "missing"
    fi
}

# Per-app patch overrides ([package] sections in security_patch.txt)
keystore_per_app_patch_supported() {
    [ "$KEYSTORE_BACKEND" = "trickystore" ] && [ "$KEYSTORE_FORMAT" = "flat" ]
}

keystore_read_per_app_patches() {
    keystore_per_app_patch_supported || return 1
    [ -f "$KEYSTORE_SECURITY" ] || return 0
    awk '
        /^\[.*\]$/ {
            if (pkg != "") print pkg "|" vals
            pkg = substr($0, 2, length($0)-2)
            vals = ""
            next
        }
        pkg != "" && /^[a-zA-Z_]+[ \t]*=/ {
            line = $0
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            vals = (vals == "") ? line : vals ";" line
        }
        END { if (pkg != "") print pkg "|" vals }
    ' "$KEYSTORE_SECURITY" 2>/dev/null
}

keystore_set_per_app_patch() {
    _ksap_pkg="$1" _ksap_date="$2"
    keystore_per_app_patch_supported || { unset _ksap_pkg _ksap_date; return 1; }
    [ -n "$_ksap_pkg" ] && [ -n "$_ksap_date" ] || { unset _ksap_pkg _ksap_date; return 1; }

    ensure_dir "$(dirname "$KEYSTORE_SECURITY")"
    [ -f "$KEYSTORE_SECURITY" ] || : > "$KEYSTORE_SECURITY"
    _ksap_tmp="${KEYSTORE_SECURITY}.tmp.$$"

    awk -v pkg="$_ksap_pkg" -v date="$_ksap_date" '
        BEGIN { in_target=0; done=0; found=0 }
        /^\[.*\]$/ {
            cur = substr($0, 2, length($0)-2)
            if (in_target && !done) { print "boot=" date; done = 1 }
            if (cur == pkg) { in_target = 1; found = 1 } else { in_target = 0 }
            print
            next
        }
        in_target && /^boot[ \t]*=/ { print "boot=" date; done = 1; next }
        { print }
        END {
            if (in_target && !done) { print "boot=" date; done = 1 }
            if (!found) { print ""; print "[" pkg "]"; print "boot=" date }
        }
    ' "$KEYSTORE_SECURITY" > "$_ksap_tmp" 2>/dev/null && _ks_commit "$KEYSTORE_SECURITY" "$_ksap_tmp"
    _ksap_status=$?
    rm -f "$_ksap_tmp" 2>/dev/null

    unset _ksap_pkg _ksap_date _ksap_tmp
    return "$_ksap_status"
}

keystore_remove_per_app_patch() {
    _krap_pkg="$1"
    keystore_per_app_patch_supported || { unset _krap_pkg; return 1; }
    [ -n "$_krap_pkg" ] && [ -f "$KEYSTORE_SECURITY" ] || { unset _krap_pkg; return 1; }

    _krap_tmp="${KEYSTORE_SECURITY}.tmp.$$"
    awk -v pkg="$_krap_pkg" '
        /^\[.*\]$/ {
            cur = substr($0, 2, length($0)-2)
            skip = (cur == pkg)
            if (!skip) print
            next
        }
        !skip { print }
    ' "$KEYSTORE_SECURITY" > "$_krap_tmp" 2>/dev/null && _ks_commit "$KEYSTORE_SECURITY" "$_krap_tmp"
    _krap_status=$?
    rm -f "$_krap_tmp" 2>/dev/null

    unset _krap_pkg _krap_tmp
    return "$_krap_status"
}

# --- Locking: one writer at a time for target / patch files (mkdir is atomic) ---
KS_LOCK_DIR="/data/adb/JerryManager/.lock/keystore.d"

keystore_lock() {
    [ "${_KS_LOCK_HELD:-0}" = "1" ] && return 0
    mkdir -p "$(dirname "$KS_LOCK_DIR")" 2>/dev/null
    _kl_n=0
    while ! mkdir "$KS_LOCK_DIR" 2>/dev/null; do
        _kl_pid=$(cat "$KS_LOCK_DIR/pid" 2>/dev/null)
        if [ -n "$_kl_pid" ] && [ ! -d "/proc/$_kl_pid" ]; then
            rm -rf "$KS_LOCK_DIR" 2>/dev/null   # owner died
            continue
        fi
        _kl_n=$((_kl_n + 1))
        if [ "$_kl_n" -ge 30 ]; then
            log "KEYSTORE" "Lock held too long — taking it over"
            rm -rf "$KS_LOCK_DIR" 2>/dev/null
            _kl_n=0
            continue
        fi
        sleep 1
    done
    echo "$$" > "$KS_LOCK_DIR/pid" 2>/dev/null
    _KS_LOCK_HELD=1
    unset _kl_n _kl_pid
    return 0
}

keystore_unlock() {
    [ "${_KS_LOCK_HELD:-0}" = "1" ] || return 0
    rm -rf "$KS_LOCK_DIR" 2>/dev/null
    _KS_LOCK_HELD=0
    return 0
}

keystore_write_security_patch() {
    keystore_lock || return 1
    _keystore_write_security_patch_nolock "$@"; _kw_rc=$?
    keystore_unlock
    return "$_kw_rc"
}

keystore_add_target() {
    keystore_lock || return 1
    _keystore_add_target_nolock "$@"; _ka_rc=$?
    keystore_unlock
    return "$_ka_rc"
}

keystore_remove_target() {
    keystore_lock || return 1
    _keystore_remove_target_nolock "$@"; _kr_rc=$?
    keystore_unlock
    return "$_kr_rc"
}

# keystore_remove_targets_file LISTFILE — remove every package in LISTFILE (one per line) from the
# target list.
keystore_remove_targets_file() {
    _krf_list="$1"
    [ -f "$_krf_list" ] || { unset _krf_list; return 1; }
    keystore_lock || { unset _krf_list; return 1; }
    _krf_rc=0
    while IFS= read -r _krf_pkg || [ -n "$_krf_pkg" ]; do
        [ -n "$_krf_pkg" ] || continue
        _keystore_remove_target_nolock "$_krf_pkg" || _krf_rc=1
    done < "$_krf_list"
    keystore_unlock
    unset _krf_list _krf_pkg
    return "$_krf_rc"
}

# --- Read the active target list: one entry per line, !/? suffix kept ---
keystore_read_targets_all() {
    keystore_read_targets
}


keystore_read_targets() {
    [ -n "$KEYSTORE_TARGETS" ] && [ -f "$KEYSTORE_TARGETS" ] || return 0
    case "$KEYSTORE_FORMAT" in
        flat)
            # top-level list only; [package] sections below it are keybox/patch scopes
            awk '
            /^[ \t]*\[/ { exit }
            { sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 != "" && $0 !~ /^#/) print }' "$KEYSTORE_TARGETS" ;;
    esac
    return 0
}

# --- Replace the whole target list with LISTFILE (one package per line, optional !/? suffix) ---
_keystore_set_targets_nolock() {
    _kst_src="$1"
    [ -f "$_kst_src" ] || { echo "list file missing: $_kst_src" >&2; return 1; }
    [ -n "$KEYSTORE_TARGETS" ] || { echo "no target file resolved for backend '$KEYSTORE_BACKEND'" >&2; return 1; }
    _kst_list="${_kst_src}.clean.$$"
    # clean: strip CR/space, keep valid package names only, last entry per package wins
    tr -d '\r' < "$_kst_src" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | awk '
        /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*[!?]?$/ {
            b = $0; sub(/[!?]$/, "", b)
            if (!(b in w)) o[++n] = b
            w[b] = $0
        }
        END { for (i = 1; i <= n; i++) print w[o[i]] }' > "$_kst_list"

    case "$KEYSTORE_FORMAT" in
        flat)
            ensure_dir "$KEYSTORE_DIR"
            [ -f "$KEYSTORE_TARGETS" ] || : > "$KEYSTORE_TARGETS"
            cp -p "$KEYSTORE_TARGETS" "$KEYSTORE_TARGETS.bak" 2>/dev/null
            _kst_sections=$(awk '/^[ \t]*\[/ { e = 1 } e { print }' "$KEYSTORE_TARGETS" 2>/dev/null)
            {
                cat "$_kst_list"
                # if, not &&: an empty section list must not turn a good write into a failure
                if [ -n "$_kst_sections" ]; then printf '\n%s\n' "$_kst_sections"; fi
            } > "$KEYSTORE_TARGETS"
            _kst_rc=$?
            [ "$_kst_rc" -eq 0 ] || echo "cannot write $KEYSTORE_TARGETS" >&2
            ;;
        *) _kst_rc=1 ;;
    esac
    rm -f "$_kst_list"
    return "$_kst_rc"
}

keystore_set_targets() {
    keystore_lock || return 1
    _keystore_set_targets_nolock "$@"; _kss_rc=$?
    keystore_unlock
    return "$_kss_rc"
}

