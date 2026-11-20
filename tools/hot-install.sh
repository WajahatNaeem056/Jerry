#!/system/bin/sh
# Jerry Manager hot-install: updates the installed module in place, no reboot.
# Usage (as root):  sh hot-install.sh [/path/to/JerryManager-*.zip]
# No argument = newest JerryManager*.zip in /sdcard/Download.
# Applies ONLY: webroot/, features/, lib/, pipelines/, dex/duckd.
# Never touched (need a reboot, or are user data): zygisk/, ts/, service.sh, post-fs-data.sh,
# sepolicy.rule, dex/*.dex, pif.prop, module.prop, customize.sh. If the zip changes any of the
# reboot-needing ones, the script says so instead of applying them.

MOD="${JM_MODDIR:-/data/adb/modules/JerryManager}"
BKROOT="${JM_BACKUP_DIR:-/data/adb/JerryManager/hot-backup}"
TMP="${JM_TMPDIR:-/data/local/tmp}/jm-hot.$$"

say() { echo "$*"; }
die() { echo "ERROR: $*" >&2; rm -rf "$TMP"; exit 1; }

[ "$(id -u 2>/dev/null)" = "0" ] || [ -n "$JM_MODDIR" ] || die "run as root (su)"
[ -f "$MOD/module.prop" ] && grep -q '^id=JerryManager' "$MOD/module.prop" || die "Jerry Manager is not installed at $MOD (flash the zip once normally first)"

ZIP="$1"
if [ -z "$ZIP" ]; then
  ZIP=$(ls -t /sdcard/Download/JerryManager*.zip 2>/dev/null | head -1)
  [ -n "$ZIP" ] || die "no zip given and none found in /sdcard/Download"
fi
[ -f "$ZIP" ] || die "zip not found: $ZIP"

# unzip: system one, else the busybox that ships with the root manager
UNZIP=""
for c in unzip /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
  case "$c" in
    unzip) command -v unzip >/dev/null 2>&1 && UNZIP="unzip" && break ;;
    *) [ -x "$c" ] && "$c" unzip 2>&1 | grep -qi usage && UNZIP="$c unzip" && break ;;
  esac
done
[ -n "$UNZIP" ] || die "no unzip available (install busybox, or unzip the zip yourself and pass the folder)"

NEW="$TMP/new"
mkdir -p "$NEW" || die "cannot create $TMP"
if [ -d "$ZIP" ]; then NEW="$ZIP"; else
  $UNZIP -oq "$ZIP" -d "$NEW" >/dev/null 2>&1 || die "unzip failed: $ZIP"
fi
grep -q '^id=JerryManager' "$NEW/module.prop" 2>/dev/null || die "not a Jerry Manager zip: $ZIP"
OLDV=$(sed -n 's/^version=//p' "$MOD/module.prop" | head -1)
NEWV=$(sed -n 's/^version=//p' "$NEW/module.prop" | head -1)
say "Installed: ${OLDV:-?}   Zip: ${NEWV:-?}"

# 1) things that need a reboot: report only
NEEDREBOOT=""
for f in service.sh post-fs-data.sh sepolicy.rule dex/classes.dex dex/attest.dex ts/classes.dex ts/supervisor.sh zygisk/arm64-v8a.so zygisk/armeabi-v7a.so zygisk/x86_64.so; do
  [ -f "$NEW/$f" ] || continue
  cmp -s "$NEW/$f" "$MOD/$f" 2>/dev/null || NEEDREBOOT="$NEEDREBOOT $f"
done

# 2) backup what we are about to replace (keeps the latest one only)
TS=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
BK="$BKROOT/$TS"
rm -rf "$BKROOT"; mkdir -p "$BK" || die "cannot create backup dir $BK"
for d in webroot features lib pipelines; do [ -d "$MOD/$d" ] && cp -R "$MOD/$d" "$BK/" 2>/dev/null; done
[ -f "$MOD/dex/duckd" ] && { mkdir -p "$BK/dex"; cp "$MOD/dex/duckd" "$BK/dex/" 2>/dev/null; }
say "Backup: $BK"

# 3) apply. webroot: drop old hashed assets only, keep runtime files (json/state.json etc.)
if [ -d "$NEW/webroot" ]; then
  rm -rf "$MOD/webroot/assets"
  mkdir -p "$MOD/webroot"
  cp -R "$NEW/webroot/." "$MOD/webroot/" || die "copying webroot failed (backup is in $BK)"
fi
for d in features lib pipelines; do
  [ -d "$NEW/$d" ] || continue
  mkdir -p "$MOD/$d"
  cp -R "$NEW/$d/." "$MOD/$d/" || die "copying $d failed (backup is in $BK)"
done
if [ -f "$NEW/dex/duckd" ]; then
  mkdir -p "$MOD/dex"
  cp "$NEW/dex/duckd" "$MOD/dex/duckd.new" && mv -f "$MOD/dex/duckd.new" "$MOD/dex/duckd" || die "copying duckd failed"
fi

# 4) permissions + SELinux label (best effort)
find "$MOD/webroot" "$MOD/features" "$MOD/lib" "$MOD/pipelines" -type d -exec chmod 755 {} \; 2>/dev/null
find "$MOD/webroot" "$MOD/features" "$MOD/lib" "$MOD/pipelines" -type f -exec chmod 644 {} \; 2>/dev/null
find "$MOD/features" "$MOD/lib" "$MOD/pipelines" -type f -name '*.sh' -exec chmod 755 {} \; 2>/dev/null
[ -f "$MOD/dex/duckd" ] && chmod 755 "$MOD/dex/duckd"
if command -v chcon >/dev/null 2>&1 && [ -f "$MOD/module.prop" ]; then
  for p in webroot features lib pipelines dex/duckd; do
    [ -e "$MOD/$p" ] && chcon -R --reference="$MOD/module.prop" "$MOD/$p" 2>/dev/null
  done
fi

# 5) sanity checks
BAD=0
for f in "$MOD"/features/*.sh "$MOD"/lib/*.sh; do sh -n "$f" 2>/dev/null || { say "syntax error: $f"; BAD=1; }; done
[ -x "$MOD/dex/duckd" ] && say "duckd: executable" || say "duckd: MISSING or not executable"
[ -f "$MOD/webroot/index.html" ] || { say "webroot/index.html missing"; BAD=1; }
[ "$BAD" = 0 ] || say "WARNING: checks failed. Restore with: cp -R $BK/* $MOD/"

[ "$NEW" = "$ZIP" ] || rm -rf "$TMP"

say ""
say "Done. No reboot needed for what was applied."
if [ -n "$NEEDREBOOT" ]; then
  say "NOT applied (these changed and need a normal flash + reboot):"
  for f in $NEEDREBOOT; do say "  - $f"; done
fi
say "Close the WebUI fully and reopen it (if the old page shows, clear the manager app's cache)."

# 6) show the Device RKP status so problems are visible right away
if [ -f "$MOD/features/rkp_device.sh" ]; then
  say ""; say "--- Device RKP status check ---"
  OUT=$(sh "$MOD/features/rkp_device.sh" status 2>&1); RC=$?
  say "exit $RC"; echo "$OUT" | head -c 600; say ""
fi
exit 0
