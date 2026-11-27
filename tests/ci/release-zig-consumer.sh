#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
source=${1:?usage: release-zig-consumer.sh source-archive-or-https-url}
zig_bin=${ZIG:-zig}
work_root=${ZIG_GLOBAL_CACHE_DIR:-${TMPDIR:-/tmp}}
mkdir -p "$work_root"
work=$(mktemp -d "$work_root/jsbay-zig-release-consumer.XXXXXX")
server_pid=
cleanup() {
    result=$?
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if [[ $result -ne 0 && -f "$work/http.log" ]]; then
        cat "$work/http.log" >&2
    fi
    if [[ $result -ne 0 && -f "$work/packages/requests.log" ]]; then
        cat "$work/packages/requests.log" >&2
    fi
    rm -rf "$work"
}
trap cleanup EXIT

if [[ $source == https://* ]]; then
    url=$source
    export ZIG_GLOBAL_CACHE_DIR="$work/global-cache"
else
    command -v node >/dev/null || { echo "Node.js is required to serve the source archive" >&2; exit 2; }
    archive=$(cd "$(dirname "$source")" && pwd)/$(basename "$source")
    mkdir -p "$work/packages"
    cp "$archive" "$work/packages/source.tar.gz"
    mkfifo "$work/server-port"
    # shellcheck disable=SC2016
    node -e 'const fs = require("node:fs"); const path = require("node:path"); const http = require("node:http"); const base = process.argv[1]; const filename = path.join(base, "source.tar.gz"); const server = http.createServer((request, response) => { fs.appendFileSync(path.join(base, "requests.log"), `${request.method} ${request.url}\n`); if (request.url !== "/source.tar.gz" || (request.method !== "GET" && request.method !== "HEAD")) { response.writeHead(404).end(); return; } const size = fs.statSync(filename).size; response.writeHead(200, { "Content-Length": size, "Content-Type": "application/gzip" }); if (request.method === "HEAD") response.end(); else fs.createReadStream(filename).pipe(response); }); server.listen(0, () => process.stdout.write(`${server.address().port}\n`));' "$work/packages" >"$work/server-port" 2>"$work/http.log" &
    server_pid=$!
    if ! read -r -t 15 port <"$work/server-port"; then
        echo "Timed out waiting for the local source archive server" >&2
        exit 1
    fi
    url="http://localhost:$port/source.tar.gz"
    curl --fail --silent --show-error --retry 20 --retry-connrefused --retry-delay 0 "$url" -o "$work/probe.tar.gz"
fi
printf 'Installing Zig package from %s\n' "$url"
for backend in quickjs quickjs_ng; do
    consumer="$work/$backend"
    mkdir -p "$consumer"
    cp "$root/tests/zig-consumer/build.zig" "$consumer/build.zig"
    cp -R "$root/tests/zig-consumer/src" "$consumer/src"
    cat >"$consumer/build.zig.zon" <<EOF
.{
    .name = .jsbay_release_consumer,
    .version = "0.0.0",
    .minimum_zig_version = "0.17.0",
    .fingerprint = 0xd826f5df4e59f88,
    .dependencies = .{},
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
EOF
    (cd "$consumer" && "$zig_bin" fetch --save=jsbay "$url" && "$zig_bin" build run "-Dbackend=$backend" --summary all)
    printf 'RELEASE_ZIG_CONSUMER_PASS=%s\n' "$backend"
done
