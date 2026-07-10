#!/usr/bin/env bash
set -euo pipefail

# convert-apk-v2-to-v3 — Convert APK v2 (gzip-concatenated) to v3 (ADB container).
# The OpenWRT SDK's apk mkndx segfaults on v2; this conversion fixes that.
#
# Usage: convert-apk-v2-to-v3 [options] <v2-apk-file>...
#   -o, --output FILE   Output file (only with one input; default: in-place)
#   -s, --stdin         Read v2 APK from stdin (use -o FILE to name output)
#   -v, --verbose       Print progress info
#       --check-deps    Verify required tools and exit
#       --help          Show this help and exit
#       --version       Print version and exit
#
# Examples:
#   convert-apk-v2-to-v3 foo.apk          # in-place
#   convert-apk-v2-to-v3 foo.apk -o v3.apk
#   cat foo.apk | convert-apk-v2-to-v3 -s -o v3.apk
#   fakeroot convert-apk-v2-to-v3 foo.apk  # preserve root:root ownership
#
# Exit codes: 0=ok, 1=usage, 2=missing deps, 3=I/O error, 4=conversion error

VERSION="1.0.0"
PROGRAM="$(basename "$0")"

# ── helpers ──────────────────────────────────────────────────────────────────

err()  { echo "$PROGRAM: $*" >&2; }
vmsg() { [[ "$VERBOSE" != true ]] || echo "$@" >&2; }

usage() {
    echo "Usage: $PROGRAM [options] <v2-apk-file>..."
    echo "  -o, --output FILE   Output file (only with one input; default: in-place)"
    echo "  -s, --stdin         Read v2 APK from stdin (use -o FILE to name output)"
    echo "  -v, --verbose       Print progress info"
    echo "      --check-deps    Verify required tools and exit"
    echo "      --help          Show this help and exit"
    echo "      --version       Print version and exit"
    exit 0
}
version() {
    echo "convert-apk-v2-to-v3 $VERSION"; echo "License MIT"; exit 0
}

# ── dependency check ─────────────────────────────────────────────────────────

check_deps() {
    local t missing=()
    for t in apk getopt gzip tar head od wc mkdir rm mktemp; do
        command -v "$t" &>/dev/null || missing+=("$t")
    done
    if [[ "${#missing[@]}" -gt 0 ]]; then
        err "missing tools: ${missing[*]}"
        return 1
    fi
    # apk mkpkg --help exits 1 even on success, so avoid pipefail.
    { apk mkpkg --help 2>&1 || true; } | grep -q mkpkg ||
        { err "apk mkpkg not available (apk-tools >= 3.0 required)"; return 1; }
}

# ── v2 detection ─────────────────────────────────────────────────────────────

is_v2() {
    local magic
    magic="$(head -c 2 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [[ "$magic" == "1f8b" ]]
}

# ── single-file conversion ───────────────────────────────────────────────────

convert_one() {
    local v2="$1" v3="$2"
    local workdir combined control data name ver arch desc \
          maintainer license url deps provs st

    [[ -f "$v2" ]] || { err "file not found: $v2"; return 3; }
    [[ -r "$v2" ]] || { err "file not readable: $v2"; return 3; }

    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' RETURN

    combined="$workdir/combined.tar"
    control="$workdir/control"
    data="$workdir/data"

    # 1 — decompress concatenated gzip streams into one tar.
    gzip -dc "$v2" > "$combined" || { err "gzip failed: $v2"; return 3; }
    [[ -s "$combined" ]] || { err "empty archive: $v2"; return 4; }

    mkdir -p "$control" "$data"

    # 2 — extract dot-files (.PKGINFO, .pre-install, …) to control/.
    tar xf "$combined" -C "$control" 2>/dev/null || true
    find "$control" -type d -empty -delete 2>/dev/null || true

    # 3 — extract non-dot-files (package payload) to data/.
    tar xf "$combined" -C "$data" --exclude='.*' 2>/dev/null || true

    # 4 — read .PKGINFO.
    [[ -f "$control/.PKGINFO" ]] || { err ".PKGINFO not found in $v2"; return 4; }

    # Use awk with ' = ' separator for field extraction.
    name="$(awk -F' = ' '/^pkgname = /{print $2}' "$control/.PKGINFO")" || true
    ver="$(awk -F' = ' '/^pkgver = /{print $2}' "$control/.PKGINFO")" || true
    arch="$(awk -F' = ' '/^arch = /{print $2}' "$control/.PKGINFO")" || true
    desc="$(awk -F' = ' '/^pkgdesc = /{print $2}' "$control/.PKGINFO")" || true
    maintainer="$(awk -F' = ' '/^maintainer = /{print $2}' "$control/.PKGINFO")" || true
    license="$(awk -F' = ' '/^license = /{print $2}' "$control/.PKGINFO")" || true
    url="$(awk -F' = ' '/^url = /{print $2}' "$control/.PKGINFO")" || true

    [[ -n "$name" && -n "$ver" ]] ||
        { err "incomplete .PKGINFO (pkgname/pkgver) in $v2"; return 4; }

    vmsg "  $name $ver ${arch:-<no-arch>}"

    # 5 — build apk mkpkg arguments.
    local -a args=()
    args+=(--info "name:$name" --info "version:$ver")
    [[ -n "$arch" ]]       && args+=(--info "arch:$arch")
    [[ -n "$desc" ]]       && args+=(--info "description:$desc")
    [[ -n "$maintainer" ]] && args+=(--info "maintainer:$maintainer")
    [[ -n "$license" ]]    && args+=(--info "license:$license")
    [[ -n "$url" ]]        && args+=(--info "url:$url")

    # Dependencies: space-separated list in a single --info field (SDK convention).
    deps="$(awk -F' = ' '/^depend = /{v=v sep $2; sep=" "} END{print v}' "$control/.PKGINFO")"
    [[ -n "$deps" ]] && args+=(--info "depends:$deps") && vmsg "    depends: $deps"

    # Provides: same approach.
    provs="$(awk -F' = ' '/^provides = /{v=v sep $2; sep=" "} END{print v}' "$control/.PKGINFO")"
    [[ -n "$provs" ]] && args+=(--info "provides:$provs") && vmsg "    provides: $provs"

    # Scripts (pre/post install/deinstall).
    for st in pre-install post-install pre-deinstall post-deinstall; do
        [[ -f "$control/.$st" ]] && args+=(--script "$st:$control/.$st")
    done

    # 6 — fix ownership under fakeroot/root.
    [[ "$(id -u)" == 0 ]] && chown -R 0:0 "$data" "$control" 2>/dev/null || true

    # 7 — run apk mkpkg.
    vmsg "  Running apk mkpkg …"
    apk mkpkg "${args[@]}" --files "$data" --output "$v3" ||
        { err "apk mkpkg failed: $v2"; return 4; }

    [[ -s "$v3" ]] || { err "empty output: $v3"; return 4; }
    vmsg "  -> $(basename "$v3") ($(wc -c < "$v3") bytes)"
    return 0
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
    local -a files=()
    local output="" stdin_mode=false
    VERBOSE=false

    local opts
    opts=$(getopt -o "o:sv" -l "output:,stdin,verbose,check-deps,help,version" \
        -n "$PROGRAM" -- "$@") || exit 1
    eval set -- "$opts"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)     output="$2"; shift 2 ;;
            -s|--stdin)      stdin_mode=true; shift ;;
            -v|--verbose)    VERBOSE=true; shift ;;
            --check-deps)    check_deps; exit $? ;;
            --help)          usage ;;
            --version)       version ;;
            --)              shift; files=("$@"); break ;;
        esac
    done

    check_deps || exit 2

    # Hint about fakeroot when not running as root.
    [[ "$(id -u)" == 0 ]] || vmsg "Tip: prefix with 'fakeroot' for root:root ownership"

    if [[ "$stdin_mode" == true ]]; then
        local stdin_tmp
        stdin_tmp="$(mktemp)"
        trap 'rm -f "$stdin_tmp"' EXIT INT TERM
        cat > "$stdin_tmp"
        convert_one "$stdin_tmp" "${output:-/dev/stdout}"
        exit $?
    fi

    [[ "${#files[@]}" -gt 0 ]] || { err "no input files (try --help)"; exit 1; }
    [[ -z "$output" || "${#files[@]}" -eq 1 ]] ||
        { err "--output with multiple files is ambiguous"; exit 1; }

    local ret=0 f v3
    for f in "${files[@]}"; do
        if ! is_v2 "$f"; then
            echo "  Skipping (not v2): $(basename "$f")" >&2
            continue
        fi
        if [[ -n "$output" ]]; then
            convert_one "$f" "$output" && echo "  $(basename "$f") -> $(basename "$output") ($(wc -c < "$output") bytes)" || ret=4
        else
            v3="$(mktemp "$f.tmp.XXXXXXXX")"
            if convert_one "$f" "$v3"; then
                mv "$v3" "$f"
                echo "  $(basename "$f")  ($(wc -c < "$f") bytes)"
            else
                rm -f "$v3"; ret=4
            fi
        fi
    done
    exit "$ret"
}

main "$@"
