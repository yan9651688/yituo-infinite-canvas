#!/usr/bin/env bash
set -euo pipefail

action=${1:?candidate or cutover or rollback}
release=${2:?release id}
package=${3:-}
base=/opt/yituo-infinite-canvas
release_dir=$base/releases/$release
shared=$base/shared
preview_unit=i18n-canvas-preview-$release
preview_conf=/etc/nginx/conf.d/canvas-preview-$release.conf
domain=i18n.laoyantongxue.si
[[ "$release" =~ ^[a-z0-9][a-z0-9.-]+$ ]] || { printf 'Invalid release id\n' >&2; exit 1; }
mkdir -p "$base/releases" "$base/backups" "$base/uploads" "$shared/data" "$shared/logs"
exec 9>"$base/.deploy.lock"
flock -w 60 -x 9

read_ports() {
    local target=$1 key
    for key in WEB_PORT API_PORT; do
        local value
        value=$(sed -n "s/^$key=//p" "$base/releases/$target/ports.env")
        [[ "$value" =~ ^[0-9]+$ ]] || { printf 'Invalid ports for %s\n' "$target" >&2; return 1; }
        printf -v "$key" '%s' "$value"
    done
}

stop_preview_tls() {
    systemctl stop "$preview_unit" >/dev/null 2>&1 || true
}

remove_preview() {
    stop_preview_tls
    if [[ -f "$preview_conf" ]]; then
        rm -f -- "$preview_conf"
        nginx -t
        systemctl reload nginx
    fi
}

check_canvas() {
    local port=$1 scheme=$2
    curl --fail --silent --show-error --max-time 15 "$scheme://$domain:$port/infinite-canvas/" --resolve "$domain:$port:127.0.0.1" | grep -F '易拓画布' >/dev/null || return 1
    curl --fail --silent --show-error --max-time 15 "$scheme://$domain:$port/infinite-canvas/yituo-logo.png" --resolve "$domain:$port:127.0.0.1" -o /dev/null || return 1
    curl --fail --silent --show-error --max-time 15 "$scheme://$domain:$port/api/settings" --resolve "$domain:$port:127.0.0.1" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["code"] == 0 and d["data"]["modelChannel"]["allowCustomChannel"] is True' || return 1
    local status
    status=$(curl --silent --show-error --max-time 15 -o /dev/null -w '%{http_code}' -X POST "$scheme://$domain:$port/api/anonymous/files/session" --resolve "$domain:$port:127.0.0.1") || return 1
    [[ "$status" == 204 ]] || return 1
    curl --fail --silent --show-error --max-time 15 -D - -o /dev/null "$scheme://$domain:$port/infinite-canvas/" --resolve "$domain:$port:127.0.0.1" | grep -F 'frame-ancestors' >/dev/null || return 1
    if [[ "$port" == 443 ]]; then
        curl --fail --silent --show-error --max-time 15 "$scheme://$domain:$port/comic/" --resolve "$domain:$port:127.0.0.1" -o /dev/null || return 1
    fi
    return 0
}

check_direct() {
    curl --fail --silent --show-error --max-time 10 "http://127.0.0.1:$API_PORT/api/health" | grep -Fx 'ok' >/dev/null || return 1
    curl --fail --silent --show-error --max-time 10 "http://127.0.0.1:$WEB_PORT/infinite-canvas/" | grep -F '易拓画布' >/dev/null || return 1
    curl --fail --silent --show-error --max-time 10 "http://127.0.0.1:$WEB_PORT/infinite-canvas/yituo-logo.png" -o /dev/null || return 1
    return 0
}

case "$action" in
candidate)
    [[ -f "$package" ]] || { printf 'Missing release package\n' >&2; exit 1; }
    [[ ! -e "$release_dir" ]] || { printf 'Release already exists: %s\n' "$release" >&2; exit 1; }
    mkdir -m 755 "$release_dir"
    tar -xzf "$package" -C "$release_dir"
    for file in server docker-entrypoint.sh web/server.js canvas-locations.conf deploy/i18n_connect_proxy.py deploy/yituo-canvas@.service; do
        [[ -f "$release_dir/$file" ]] || { printf 'Incomplete release: %s\n' "$file" >&2; exit 1; }
    done
    chmod 755 "$release_dir/server" "$release_dir/docker-entrypoint.sh"
    WEB_PORT=13010
    API_PORT=18080
    while ss -ltnH "( sport = :$WEB_PORT or sport = :$API_PORT )" | grep -q .; do
        WEB_PORT=$((WEB_PORT + 2))
        API_PORT=$((API_PORT + 2))
        (( WEB_PORT <= 13050 )) || { printf 'No free canvas ports\n' >&2; exit 1; }
    done
    node_bin=$(command -v node)
    [[ -x "$node_bin" ]] || { printf 'Node runtime not found: %s\n' "$node_bin" >&2; exit 1; }
    umask 077
    printf 'WEB_PORT=%s\nAPI_PORT=%s\nNODE_BIN=%s\n' "$WEB_PORT" "$API_PORT" "$node_bin" > "$release_dir/ports.env"
    sed -i "s/__WEB_PORT__/$WEB_PORT/g; s/__API_PORT__/$API_PORT/g" "$release_dir/canvas-locations.conf"
    if [[ ! -f "$shared/app.env" ]]; then
        {
            printf 'ADMIN_USERNAME=admin\n'
            printf 'ADMIN_PASSWORD=%s\n' "$(openssl rand -hex 18)"
            printf 'JWT_SECRET=%s\n' "$(openssl rand -hex 32)"
            printf 'JWT_EXPIRE_HOURS=168\n'
            printf 'STORAGE_DRIVER=sqlite\n'
            printf 'DATABASE_DSN=%s\n' "$shared/data/infinite-canvas.db"
            printf 'AI_LOG_DIR=%s\n' "$shared/data/logs/ai-calls"
            printf 'PROMPT_DATA_DIR=%s\n' "$shared/data/prompts"
        } > "$shared/app.env.new"
        mv "$shared/app.env.new" "$shared/app.env"
    fi
    chown -R runner:runner "$release_dir" "$shared"
    chmod 600 "$shared/app.env"
    python3 -m py_compile "$release_dir/deploy/i18n_connect_proxy.py"
    install -m 644 "$release_dir/deploy/yituo-canvas@.service" /etc/systemd/system/yituo-canvas@.service
    systemctl daemon-reload
    systemctl enable --now "yituo-canvas@$release"
    ready=false
    for _ in {1..120}; do
        if check_direct; then ready=true; break; fi
        sleep 1
    done
    if [[ "$ready" != true ]]; then
        systemctl stop "yituo-canvas@$release" || true
        journalctl -u "yituo-canvas@$release" --no-pager | grep -E 'node|Error|error|not found|failed|FAILURE|Listening|Started|Stopped' | tail -100 || true
        exit 1
    fi
    sed "s/__RELEASE_ID__/$release/g" "$release_dir/deploy/canvas-preview.conf" > "$preview_conf"
    nginx -t
    systemctl reload nginx
    systemd-run --unit="$preview_unit" --property=Type=simple --property=Restart=no \
        /usr/bin/python3 "$release_dir/deploy/i18n_connect_proxy.py" \
        --cert /etc/letsencrypt/live/i18n.laoyantongxue.si/fullchain.pem \
        --key /etc/letsencrypt/live/i18n.laoyantongxue.si/privkey.pem \
        --port 9443 --mirror-port 8897 >/dev/null
    ready=false
    for _ in {1..30}; do
        if check_canvas 9443 https; then ready=true; break; fi
        sleep 1
    done
    if [[ "$ready" != true ]]; then
        remove_preview
        systemctl stop "yituo-canvas@$release" || true
        exit 1
    fi
    printf 'Candidate ready: %s (web=%s api=%s preview=9443)\n' "$release" "$WEB_PORT" "$API_PORT"
    ;;

cutover)
    [[ -d "$release_dir" && -f "$release_dir/ports.env" ]] || { printf 'Candidate missing\n' >&2; exit 1; }
    read_ports "$release"
    check_direct
    check_canvas 9443 https
    backup=$base/backups/$release
    mkdir -m 700 "$backup"
    cp -p /etc/nginx/conf.d/comic-mirror.conf "$backup/comic-mirror.conf"
    cp -p /opt/i18n-proxy/i18n_connect_proxy.py "$backup/i18n_connect_proxy.py"
    if [[ -f "$base/current-release" ]]; then
        cp -p "$base/current-release" "$backup/current-release"
    else
        : > "$backup/current-release"
    fi
    old_release=$(cat "$base/current-release" 2>/dev/null || true)
    sed "s/__RELEASE_ID__/$release/g" "$release_dir/deploy/comic-mirror.conf" > /etc/nginx/conf.d/comic-mirror.conf
    install -m 644 "$release_dir/deploy/i18n_connect_proxy.py" /opt/i18n-proxy/i18n_connect_proxy.py
    if ! nginx -t; then
        cp -p "$backup/comic-mirror.conf" /etc/nginx/conf.d/comic-mirror.conf
        cp -p "$backup/i18n_connect_proxy.py" /opt/i18n-proxy/i18n_connect_proxy.py
        nginx -t
        exit 1
    fi
    if ! systemctl reload nginx || ! systemctl restart i18n-proxy; then
        cp -p "$backup/comic-mirror.conf" /etc/nginx/conf.d/comic-mirror.conf
        cp -p "$backup/i18n_connect_proxy.py" /opt/i18n-proxy/i18n_connect_proxy.py
        nginx -t
        systemctl reload nginx || true
        systemctl restart i18n-proxy || true
        systemctl stop "yituo-canvas@$release" || true
        remove_preview
        printf 'Proxy switch failed; configuration restored\n' >&2
        exit 1
    fi
    ready=false
    for _ in {1..30}; do
        if check_canvas 443 https; then ready=true; break; fi
        sleep 1
    done
    if [[ "$ready" != true ]]; then
        cp -p "$backup/comic-mirror.conf" /etc/nginx/conf.d/comic-mirror.conf
        cp -p "$backup/i18n_connect_proxy.py" /opt/i18n-proxy/i18n_connect_proxy.py
        nginx -t
        systemctl reload nginx
        systemctl restart i18n-proxy
        systemctl stop "yituo-canvas@$release" || true
        remove_preview
        printf 'Production checks failed; configuration restored\n' >&2
        exit 1
    fi
    printf '%s\n' "$release" > "$base/current-release.new"
    mv "$base/current-release.new" "$base/current-release"
    remove_preview
    if [[ -n "$old_release" && "$old_release" != "$release" && -f "$base/releases/$old_release/ports.env" ]]; then
        old_web=$WEB_PORT
        old_api=$API_PORT
        read_ports "$old_release"
        old_web=$WEB_PORT
        old_api=$API_PORT
        for _ in {1..30}; do
            ss -Hnt state established "( sport = :$old_web or sport = :$old_api )" | grep -q . || break
            sleep 1
        done
        if ! ss -Hnt state established "( sport = :$old_web or sport = :$old_api )" | grep -q .; then
            systemctl stop "yituo-canvas@$old_release" || true
        else
            printf 'Previous instance retained until connections drain: %s\n' "$old_release"
        fi
    fi
    printf 'Canvas published: %s\n' "$release"
    ;;

rollback)
    backup=$base/backups/$release
    [[ -f "$backup/comic-mirror.conf" && -f "$backup/i18n_connect_proxy.py" ]] || { printf 'Rollback backup missing\n' >&2; exit 1; }
    cp -p "$backup/comic-mirror.conf" /etc/nginx/conf.d/comic-mirror.conf
    cp -p "$backup/i18n_connect_proxy.py" /opt/i18n-proxy/i18n_connect_proxy.py
    nginx -t
    systemctl reload nginx
    systemctl restart i18n-proxy
    if [[ -s "$backup/current-release" ]]; then
        cp -p "$backup/current-release" "$base/current-release"
    else
        rm -f -- "$base/current-release"
    fi
    systemctl stop "yituo-canvas@$release" || true
    remove_preview
    curl --fail --silent --show-error --max-time 15 https://$domain/comic/ --resolve "$domain:443:127.0.0.1" -o /dev/null
    printf 'Rollback completed: %s\n' "$release"
    ;;

cleanup)
    remove_preview
    systemctl stop "yituo-canvas@$release" || true
    printf 'Candidate cleaned up: %s\n' "$release"
    ;;

*)
    printf 'Unknown action: %s\n' "$action" >&2
    exit 1
    ;;
esac
