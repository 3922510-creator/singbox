# shellcheck shell=bash
# Sourced only after the parent isolated service test has checked all namespaces.
# No real credentials: fixed fixture Token + private loopback-only DNS target.
[ "${SB_ISOLATED_OPENRC:-${SB_ISOLATED_SYSTEMD:-}}" = yes ] || return 1
[ -x /work/cloudflared ] || { echo 'Missing verified cloudflared fixture' >&2; return 1; }
printf '\n127.0.0.1 argo.invalid\n' >> /etc/hosts
argo_id=11111111-1111-4111-8111-111111111111
argo_token=$(printf '{"a":"00000000000000000000000000000000","t":"%s","s":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}' "$argo_id" | base64 | tr -d '\n')
argo_before=$(sha256sum "$CONFIG_FILE" "$STATE_FILE")
original_probe=$(declare -f probe_node)
eval "$(declare -f probe_node | sed '1s/probe_node/isolated_real_probe/')"
probe_node() {
    local proc attempt alive=0
    # Type=simple is marked active before the service child finishes exec/mount setup.
    for ((attempt=0; attempt<20; attempt++)); do
        if argo_active "$argo_id"; then
            for proc in /proc/[0-9]*; do
                [ "$proc/exe" -ef "$CF_BIN" ] && alive=1
            done
        fi
        [ "$alive" = 0 ] || break
        sleep 0.1
    done
    [ "$alive" = 1 ] || return 1
    touch /work/argo-service-running
    isolated_real_probe "$@"
}
if add_argo_node <<< $'31871\n/test/ws\nargo.invalid\n'"$argo_token"$'\nArgo isolated\ny\ny\n'; then
    echo 'Offline fixture tunnel must not be reported as usable' >&2; exit 1
fi
eval "$original_probe"
unset argo_token original_probe
[ -f /work/argo-service-running ]
[ "$argo_before" = "$(sha256sum "$CONFIG_FILE" "$STATE_FILE")" ]
[ ! -e "$ARGO_DIR/$argo_id" ] && [ ! -e "$(argo_unit_path "$argo_id")" ]
svc_active
printf '\nISOLATED ARGO real cloudflared launch + failed-probe rollback: PASS\n'
