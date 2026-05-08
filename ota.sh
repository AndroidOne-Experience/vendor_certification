#!/usr/bin/env bash
#
# Generate latest Google Pixel Beta fingerprints for Play Integrity Fix (PIF)
#
# Behavior:
# 1. Always generates all available beta fingerprints inside:
#       latest_pif/
#
# 2. If a codename is passed:
#       ./ota.sh komodo
#
#    then it also creates:
#       ./gms_certified_props.json
#
#    using that selected codename fingerprint.
#
# Examples:
#   ./ota.sh
#   ./ota.sh komodo
#   ./ota.sh caiman
#   ./ota.sh husky
#

set -euo pipefail

GOOGLE_URL="https://developer.android.com"
SELECTED_CODENAME="${1:-}"
OUTPUT_DIR="latest_pif"

log()  { echo "[INFO]  $*" >&2; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"

# Preferred priority (newest devices first)
DEVICE_PRIORITY=(
    frankel
    blazer
    mustang
    rango
    stallion
    tokay
    caiman
    komodo
    comet
    tegu
    shiba
    husky
    akita
    panther
    cheetah
    lynx
    oriole
    raven
    bluejay
)

declare -A CODENAME_MAP=(
    [oriole]="Pixel 6"
    [raven]="Pixel 6 Pro"
    [bluejay]="Pixel 6a"
    [panther]="Pixel 7"
    [cheetah]="Pixel 7 Pro"
    [lynx]="Pixel 7a"
    [shiba]="Pixel 8"
    [husky]="Pixel 8 Pro"
    [akita]="Pixel 8a"
    [tokay]="Pixel 9"
    [caiman]="Pixel 9 Pro"
    [komodo]="Pixel 9 Pro XL"
    [comet]="Pixel 9 Pro Fold"
    [tegu]="Pixel 9a"
    [frankel]="Pixel 10"
    [blazer]="Pixel 10 Pro"
    [mustang]="Pixel 10 Pro XL"
    [rango]="Pixel 10 Pro Fold"
    [stallion]="Pixel 10a"
)

extract_versions() {
    curl -sfL "$GOOGLE_URL/about/versions" \
        | grep -oP 'https://developer\.android\.com/about/versions/\K\d+' \
        | sort -rnu
}

extract_qpr_pages() {
    local version="$1"

    curl -sfL "$GOOGLE_URL/about/versions/$version" 2>/dev/null \
        | grep -oP 'href="(/about/versions/'"$version"'/qpr(\d+)/download-ota)"' \
        | sed -E 's/href="([^"]+)"/\1/' \
        | while read -r path; do
            qpr=$(echo "$path" | grep -oP 'qpr\K\d+')
            echo "$qpr|$path"
        done \
        | sort -t'|' -rn -k1,1
}

extract_ota_urls() {
    local page="$1"

    curl -sfL "$page" 2>/dev/null \
        | grep -oP 'href="(https://dl\.google\.com/[^"]*ota/([^/"]+_beta)[^"]*?)"' \
        | sed -E 's/href="([^"]+)"/\1/' || true
}

parse_metadata() {
    local ota_url="$1"

    local raw
    raw=$(curl -sfL --range 0-4095 "$ota_url" | strings 2>/dev/null) || return 1

    local fp
    local patch

    fp=$(echo "$raw" | grep -oP 'post-build=\K.*' | head -1 | tr -d '\r')
    patch=$(echo "$raw" | grep -oP 'security-patch-level=\K.*' | head -1 | tr -d '\r')

    [[ -z "$fp" || -z "$patch" ]] && return 1

    echo "$fp|$patch"
}

write_json() {
    local codename="$1"
    local model="$2"
    local product="$3"
    local fingerprint="$4"
    local patch="$5"

    local brand
    local release
    local build_id
    local safe_name
    local file

    brand=$(echo "$fingerprint" | cut -d'/' -f1)
    release=$(echo "$fingerprint" | cut -d':' -f2 | cut -d'/' -f1)
    build_id=$(echo "$fingerprint" | cut -d':' -f2 | cut -d'/' -f2)

    safe_name=$(echo "$model" | tr '[:upper:]' '[:lower:]' | sed 's/ /_/g')
    file="$OUTPUT_DIR/pif_beta_${safe_name}.json"

    cat > "$file" <<EOF
{
  "MANUFACTURER": "Google",
  "MODEL": "$model",
  "FINGERPRINT": "$fingerprint",
  "BRAND": "$brand",
  "PRODUCT": "$product",
  "DEVICE": "$codename",
  "VERSION.RELEASE": "$release",
  "ID": "$build_id",
  "VERSION.SECURITY_PATCH": "$patch",
  "VERSION.DEVICE_INITIAL_SDK_INT": "32"
}
EOF

    log "Generated: $file"

    # If user passed a codename like:
    # ./ota.sh komodo
    # then generate ./gms_certified_props.json
    if [[ -n "$SELECTED_CODENAME" && "$codename" == "$SELECTED_CODENAME" ]]; then
        cp "$file" "./gms_certified_props.json"
        log "Generated: ./gms_certified_props.json for $codename"
    fi
}

main() {
    log "Fetching latest Android versions..."

    local versions
    versions=$(extract_versions)
    [[ -z "$versions" ]] && die "No Android versions found"

    for version in $versions; do
        log "Checking Android $version"

        local qprs
        qprs=$(extract_qpr_pages "$version") || continue
        [[ -z "$qprs" ]] && continue

        while IFS='|' read -r qpr_num qpr_path; do
            local page="${GOOGLE_URL}${qpr_path}"
            log "Checking QPR$qpr_num → $page"

            local ota_urls
            ota_urls=$(extract_ota_urls "$page")
            [[ -z "$ota_urls" ]] && continue

            declare -A URL_MAP=()

            while read -r url; do
                [[ -z "$url" ]] && continue

                local product
                local codename

                product=$(echo "$url" | grep -oP '[^/]+_beta' | head -1)
                codename="${product%_beta}"
                URL_MAP[$codename]="$url"
            done <<< "$ota_urls"

            local generated=0

            for codename in "${DEVICE_PRIORITY[@]}"; do
                local model
                local url
                local meta
                local fingerprint
                local patch

                model="${CODENAME_MAP[$codename]:-}"
                url="${URL_MAP[$codename]:-}"

                [[ -z "$model" || -z "$url" ]] && continue

                log "Processing $model"

                meta=$(parse_metadata "$url") || {
                    warn "Skipping $model (metadata parse failed)"
                    continue
                }

                IFS='|' read -r fingerprint patch <<< "$meta"

                write_json \
                    "$codename" \
                    "$model" \
                    "${codename}_beta" \
                    "$fingerprint" \
                    "$patch"

                generated=1
            done

            [[ "$generated" -eq 1 ]] && exit 0
        done <<< "$qprs"
    done

    die "No valid beta fingerprints found"
}

main "$@"