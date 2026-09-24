#!/usr/bin/env bash
#
# Generate latest Google Pixel Beta fingerprints for Play Integrity Fix (PIF)
#
# Features:
# - Supports Android 17 Beta + QPR pages
# - Checks:
#       normal beta
#       QPR1
#       QPR2
#       QPR3...
# - Automatically selects the newest/highest available QPR
# - Falls back to an older QPR if the newest one cannot be parsed
# - Falls back to Android 16/15/etc automatically
# - Generates all available fingerprints inside:
#       latest_pif/
#
# Optional:
#
#   ./ota.sh komodo
#
# Also generates:
#
#   ./gms_certified_props.json
#
# using that exact codename fingerprint.
#

set -euo pipefail

GOOGLE_URL="https://developer.android.com"
SELECTED_CODENAME="${1:-}"
OUTPUT_DIR="latest_pif"

log()  { echo "[INFO]  $*" >&2; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"


# ============================================================
# DEVICE LIST
# Newest devices first
# ============================================================

DEVICE_PRIORITY=(
    # Pixel 11 series
    yogi
    kodiak
    grizzly
    cubs

    # Pixel 10 series
    stallion
    rango
    mustang
    blazer
    frankel

    # Pixel 9 series
    tegu
    comet
    komodo
    caiman
    tokay

    # Pixel 8 series
    akita
    husky
    shiba

    # Fold / Tablet
    tangorpro
    felix

    # Pixel 7 series
    lynx
    cheetah
    panther

    # Pixel 6 series
    bluejay
    raven
    oriole
)


declare -A CODENAME_MAP=(

    # Pixel 6
    [oriole]="Pixel 6"
    [raven]="Pixel 6 Pro"
    [bluejay]="Pixel 6a"

    # Pixel 7
    [panther]="Pixel 7"
    [cheetah]="Pixel 7 Pro"
    [lynx]="Pixel 7a"

    # First Fold / Tablet
    [felix]="Pixel Fold"
    [tangorpro]="Pixel Tablet"

    # Pixel 8
    [shiba]="Pixel 8"
    [husky]="Pixel 8 Pro"
    [akita]="Pixel 8a"

    # Pixel 9
    [tokay]="Pixel 9"
    [caiman]="Pixel 9 Pro"
    [komodo]="Pixel 9 Pro XL"
    [comet]="Pixel 9 Pro Fold"
    [tegu]="Pixel 9a"

    # Pixel 10
    [frankel]="Pixel 10"
    [blazer]="Pixel 10 Pro"
    [mustang]="Pixel 10 Pro XL"
    [rango]="Pixel 10 Pro Fold"
    [stallion]="Pixel 10a"

    # Pixel 11
    [cubs]="Pixel 11"
    [grizzly]="Pixel 11 Pro"
    [kodiak]="Pixel 11 Pro XL"
    [yogi]="Pixel 11 Pro Fold"
)


# ============================================================
# FIND AVAILABLE ANDROID VERSIONS
# ============================================================

extract_versions() {

    curl -sfL "$GOOGLE_URL/about/versions" \
        | grep -oP '/about/versions/\K\d+' \
        | sort -rnu \
        | uniq
}


# ============================================================
# FIND BETA / QPR PAGES
#
# Output order:
#
#   0|normal-beta
#   1|qpr1
#   2|qpr2
#   3|qpr3
#
# This is intentional.
#
# First we CHECK:
#   normal -> QPR1 -> QPR2 -> ...
#
# Then main() processes them backwards:
#   newest QPR -> older QPR -> normal
#
# ============================================================

extract_beta_pages() {

    local version="$1"
    local html

    # Always check the normal beta page first
    echo "0|/about/versions/${version}/download-ota"


    # Search BOTH the Android version page and the normal OTA page
    # for QPR OTA pages.
    html=$(
        {
            curl -sfL \
                "$GOOGLE_URL/about/versions/$version" \
                2>/dev/null || true

            curl -sfL \
                "$GOOGLE_URL/about/versions/$version/download-ota" \
                2>/dev/null || true
        }
    )


    # Find:
    #
    # /about/versions/17/qpr1/download-ota
    # /about/versions/17/qpr2/download-ota
    # /about/versions/17/qpr3/download-ota
    #
    # and sort them:
    #
    # QPR1
    # QPR2
    # QPR3
    #

    {
        printf '%s\n' "$html" \
            | grep -oP \
                "/about/versions/${version}/qpr\d+/download-ota" \
            | sort -u \
            | while read -r path; do

                local qpr

                qpr=$(
                    grep -oP 'qpr\K\d+' <<< "$path"
                )

                echo "$qpr|$path"

            done \
            | sort -t'|' -n -k1,1

    } || true
}


# ============================================================
# GET OTA LINKS FROM PAGE
# ============================================================

extract_ota_urls() {

    local page="$1"

    curl -sfL "$page" 2>/dev/null \
        | grep -oP \
            'href="(https://dl\.google\.com/[^"]*ota/([^/"]+_beta)[^"]*?)"' \
        | sed -E \
            's/href="([^"]+)"/\1/' \
        | sort -u \
        || true
}


# ============================================================
# PARSE OTA METADATA
# ============================================================

parse_metadata() {

    local ota_url="$1"

    local raw
    local fp
    local patch


    raw=$(
        curl -sfL \
            --range 0-4095 \
            "$ota_url" \
            | strings 2>/dev/null
    ) || return 1


    fp=$(
        echo "$raw" \
            | grep -oP 'post-build=\K.*' \
            | head -1 \
            | tr -d '\r'
    )


    patch=$(
        echo "$raw" \
            | grep -oP 'security-patch-level=\K.*' \
            | head -1 \
            | tr -d '\r'
    )


    [[ -z "$fp" || -z "$patch" ]] && return 1


    echo "$fp|$patch"
}


# ============================================================
# WRITE PIF JSON
# ============================================================

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


    brand=$(
        echo "$fingerprint" \
            | cut -d'/' -f1
    )


    release=$(
        echo "$fingerprint" \
            | cut -d':' -f2 \
            | cut -d'/' -f1
    )


    build_id=$(
        echo "$fingerprint" \
            | cut -d':' -f2 \
            | cut -d'/' -f2
    )


    safe_name=$(
        echo "$model" \
            | tr '[:upper:]' '[:lower:]' \
            | sed 's/ /_/g'
    )


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


    # Example:
    #
    # ./ota.sh komodo
    #
    # Also produce:
    #
    # ./gms_certified_props.json

    if [[ -n "$SELECTED_CODENAME" &&
          "$codename" == "$SELECTED_CODENAME" ]]; then

        cp "$file" "./gms_certified_props.json"

        log \
            "Generated: ./gms_certified_props.json for $codename"
    fi
}


# ============================================================
# PROCESS ONE BETA BRANCH
# ============================================================

process_branch() {

    local version="$1"
    local qpr_num="$2"
    local page_path="$3"

    local page="${GOOGLE_URL}${page_path}"

    local ota_urls


    ota_urls=$(
        extract_ota_urls "$page"
    )


    [[ -z "$ota_urls" ]] && return 1


    declare -A URL_MAP=()


    # --------------------------------------------------------
    # Create:
    #
    # codename -> OTA URL
    #
    # Example:
    #
    # komodo -> https://dl.google.com/...komodo_beta...
    #
    # --------------------------------------------------------

    while read -r url; do

        [[ -z "$url" ]] && continue


        local product
        local codename


        product=$(
            echo "$url" \
                | grep -oP '[^/]+_beta' \
                | head -1
        )


        codename="${product%_beta}"


        URL_MAP["$codename"]="$url"


    done <<< "$ota_urls"


    local generated=0


    # --------------------------------------------------------
    # Generate fingerprints
    # --------------------------------------------------------

    for codename in "${DEVICE_PRIORITY[@]}"; do

        local model
        local url
        local meta
        local fingerprint
        local patch


        model="${CODENAME_MAP[$codename]:-}"

        url="${URL_MAP[$codename]:-}"


        [[ -z "$model" || -z "$url" ]] && continue


        log "Processing $model ($codename)"


        meta=$(
            parse_metadata "$url"
        ) || {

            warn \
                "Skipping $model (metadata parse failed)"

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


    [[ "$generated" -eq 1 ]]
}


# ============================================================
# MAIN
# ============================================================

main() {

    log "Fetching latest Android versions..."


    local versions

    versions=$(
        extract_versions
    )


    [[ -z "$versions" ]] &&
        die "No Android versions found"


    # ========================================================
    # Android newest -> oldest
    #
    # Example:
    #
    # 17
    # 16
    # 15
    #
    # ========================================================

    for version in $versions; do

        log "Checking Android $version"


        local pages

        pages=$(
            extract_beta_pages "$version"
        ) || continue


        [[ -z "$pages" ]] && continue


        # ====================================================
        # FIRST PASS
        #
        # Check:
        #
        # normal beta
        # QPR1
        # QPR2
        # QPR3
        #
        # Keep every branch that actually has OTA URLs.
        # ====================================================

        local -a valid_pages=()


        while IFS='|' read -r qpr_num page_path; do

            [[ -z "$qpr_num" ||
               -z "$page_path" ]] &&
                continue


            local page="${GOOGLE_URL}${page_path}"

            local ota_urls


            if [[ "$qpr_num" == "0" ]]; then

                log \
                    "Checking base Android $version beta → $page"

            else

                log \
                    "Checking Android $version QPR$qpr_num → $page"

            fi


            ota_urls=$(
                extract_ota_urls "$page"
            )


            if [[ -n "$ota_urls" ]]; then

                valid_pages+=(
                    "$qpr_num|$page_path"
                )

                log \
                    "Found beta OTAs on this branch"

            else

                log \
                    "No beta OTAs found on this branch"

            fi


        done <<< "$pages"


        # No beta branches?
        # Try next Android version.

        [[ ${#valid_pages[@]} -eq 0 ]] &&
            continue


        # ====================================================
        # SECOND PASS
        #
        # Process VALID pages backwards.
        #
        # Example if these exist:
        #
        # base
        # QPR1
        # QPR2
        #
        # Processing becomes:
        #
        # QPR2   <- FIRST
        # QPR1
        # base
        #
        # ====================================================

        local i


        for ((
            i=${#valid_pages[@]} - 1;
            i>=0;
            i--
        )); do

            local qpr_num
            local page_path


            IFS='|' read -r \
                qpr_num \
                page_path \
                <<< "${valid_pages[$i]}"


            if [[ "$qpr_num" == "0" ]]; then

                log \
                    "Selected Android $version base beta"

            else

                log \
                    "Selected Android $version QPR$qpr_num as newest available beta branch"

            fi


            # Try generating fingerprints

            if process_branch \
                "$version" \
                "$qpr_num" \
                "$page_path"; then


                if [[ "$qpr_num" == "0" ]]; then

                    log \
                        "Finished using Android $version base beta"

                else

                    log \
                        "Finished using Android $version QPR$qpr_num"

                fi


                return 0
            fi


            # The page existed but metadata parsing failed.
            # Try previous QPR.

            warn \
                "Branch had OTA links but no usable metadata; trying older branch"

        done
    done


    die "No valid beta fingerprints found"
}


main "$@"