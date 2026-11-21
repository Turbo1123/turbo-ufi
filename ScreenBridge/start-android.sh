#!/system/bin/sh
# Run from the UFI-TOOLS boot hook. The trusted binary drops to Android shell UID.
install_dir=/data/turbo-ufi-screen
state_dir=/data/local/tmp/turbo-ufi-screen/state
umask 077
exec >>"$install_dir/bridge.log" 2>&1

attempt=0
while [ "$attempt" -lt 45 ]; do
    if /system/bin/toybox netstat -ltn | /system/bin/toybox grep -q '192\.168\.0\.1:9443 '; then
        exit 0
    fi
    "$install_dir/screenbridge" -dir "$state_dir"
    attempt=$((attempt + 1))
    /system/bin/sleep 2
done
