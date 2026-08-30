#!/usr/bin/env bash
#
# docsync-improved.sh - mirror Red Hat product documentation (PDF) from
#                       https://docs.redhat.com/
#
# Examples:
#   docsync-improved.sh -h
#   docsync-improved.sh -l                                 # list all products
#   docsync-improved.sh -d red_hat_enterprise_linux -l     # list a product's versions
#   docsync-improved.sh -d red_hat_enterprise_linux        # download every version
#   docsync-improved.sh -d red_hat_enterprise_linux -v 9.5 # one specific version
#   docsync-improved.sh -d red_hat_enterprise_linux -l latest   # newest version only
#   docsync-improved.sh -d ALL -l latest                   # newest version of every product
#   docsync-improved.sh -d ALL                             # every version of every product
#
# Flag notes:
#   -l            with no value  -> list mode
#   -l <value>    "latest" or an exact version -> version selector for download
#   -v <value>    exact version selector (same effect as -l <value>)
#   -d ALL        case-insensitive; means "every product"
#
set -u
set -o pipefail

website="https://docs.redhat.com"
docdir="."
SLEEP="${SLEEP:-0}"          # optional politeness delay (seconds) between PDF downloads
# NB: docs.redhat.com's WAF answers 403 to non-default User-Agents, so leave
#     curl's default UA in place - do not add -A here.

_PRODUCTS=""                 # cache of the product list (populated on first use)
_OK=0; _FAIL=0; _SKIP=0      # run counters

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

lc() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

tool_check() {
    local missing=0 t
    for t in curl grep sed sort uniq awk xmllint tr; do
        command -v "$t" >/dev/null 2>&1 || { echo "Required tool not found: $t" >&2; missing=1; }
    done
    [ "$missing" -eq 0 ] || exit 6
}

# GET a URL to stdout: follow redirects, fail on HTTP >= 400, retry a few times.
fetch() {
    curl -fsSL --retry 3 --retry-delay 2 --max-time 120 "$1"
}

# descending version sort, with a fallback for platforms whose sort lacks -V
sort_desc() {
    if sort -V </dev/null >/dev/null 2>&1; then sort -rV; else sort -r; fi
}

# echo product slugs, one per line (fetched once, then cached)
get_products() {
    if [ -z "$_PRODUCTS" ]; then
        _PRODUCTS=$(
            fetch "$website/en/products/" 2>/dev/null \
                | sed 's/href=/\n&/g' \
                | grep 'href="/en/documentation/' \
                | awk -F/ '{ print $4 }' \
                | grep -v '^$' \
                | sort -u
        )
    fi
    printf '%s\n' "$_PRODUCTS"
}

product_exists() { get_products | grep -qxF -- "$1"; }

# echo the available version strings for a product, one per line
get_versions() {
    local product=$1 html vers
    html=$(fetch "$website/en/documentation/$product/" 2>/dev/null) || return 1

    vers=$(printf '%s' "$html" \
        | xmllint --nonet --nowarning --html --recover --xpath \
              '//select[@id="product_version"]/option/text()' - 2>/dev/null \
        | tr -s ' \t\r\n' '\n' \
        | grep -E '^[A-Za-z0-9][A-Za-z0-9._+-]*$')

    # Products with no version <select> still carry a single version segment in
    # their doc URLs (e.g. "2.x", "1-latest") - infer it from the most common one.
    if [ -z "$vers" ]; then
        vers=$(printf '%s' "$html" \
            | grep -o 'href="[^"]*"' \
            | sed 's/^href="//; s/"$//; s/[#?].*$//' \
            | sed "s#^$website##" \
            | sed -nE "s#^/en/documentation/$product/([^/]+)/.+#\1#p" \
            | grep -E '^[A-Za-z0-9][A-Za-z0-9._+-]*$' \
            | sort | uniq -c | sort -rn | head -n1 | awk '{print $2}')
    fi

    [ -n "$vers" ] || return 1
    printf '%s\n' "$vers"
}

# ---------------------------------------------------------------------------
# download
# ---------------------------------------------------------------------------

# download every PDF for one product/version pair
download_product_version() {
    local product=$1 ver=$2
    local out="$docdir/$product/$ver"
    local index_html paths p base filename pdf_url

    index_html=$(fetch "$website/en/documentation/$product/$ver" 2>/dev/null) || {
        echo "  ! [$ver] cannot fetch document index"; return 1; }

    # Collect .../html/<name> and .../html-single/<name> guide links, map them to
    # the matching /pdf/<name> landing page, and de-duplicate. Links may be
    # site-absolute ("https://docs.redhat.com/en/...") or root-relative ("/en/...").
    paths=$(
        printf '%s' "$index_html" \
            | grep -o 'href="[^"]*"' \
            | sed 's/^href="//; s/"$//; s/[#?].*$//' \
            | sed "s#^$website##" \
            | grep -E "^/en/documentation/$product/$ver/html(-single)?/[^/]+$" \
            | sed -E 's@/html(-single)?/@/pdf/@' \
            | sort -u
    )
    if [ -z "$paths" ]; then
        echo "  ! [$ver] no document links found"; return 0
    fi

    mkdir -p "$out" || { echo "  ! cannot create $out"; return 1; }

    while IFS= read -r p; do
        [ -n "$p" ] || continue
        base="${p##*/}"
        filename="$out/${product}-${ver}-${base}.pdf"
        printf '  * [%s] %s: ' "$ver" "$base"

        if [ -s "$filename" ]; then
            echo "already downloaded"; _SKIP=$((_SKIP + 1)); continue
        fi

        # the /pdf/<name>/index page carries the real PDF URL
        pdf_url=$(fetch "$website$p/index" 2>/dev/null \
                    | grep -o '"[^"]*\.pdf"' | tr -d '"' | head -n1)
        if [ -z "$pdf_url" ]; then
            echo "FAILED (no PDF URL)"; _FAIL=$((_FAIL + 1)); continue
        fi
        case "$pdf_url" in
            //*) pdf_url="https:$pdf_url" ;;
            /*)  pdf_url="$website$pdf_url" ;;
        esac

        if curl -fL --retry 3 --retry-delay 2 --max-time 300 \
                -sS -o "$filename" "$pdf_url" && [ -s "$filename" ]; then
            echo "OK"; _OK=$((_OK + 1))
        else
            echo "FAILED"; rm -f "$filename"; _FAIL=$((_FAIL + 1))
        fi

        if [ "$SLEEP" -gt 0 ] 2>/dev/null; then sleep "$SLEEP"; fi
    done <<EOF
$paths
EOF
}

# download docs for one or more products, honouring a version filter
#   $1      = "" (all versions) | "latest" | "<exact version>"
#   $2..$N  = product slugs
download_docs() {
    local version_filter=$1; shift
    local product v target versions

    for product in "$@"; do
        echo "== $product"

        versions=$(get_versions "$product") || true
        if [ -z "$versions" ]; then
            echo "  ! no versions found (skipping)"; continue
        fi

        target=""
        if [ -n "$version_filter" ]; then
            if [ "$(lc "$version_filter")" = "latest" ]; then
                target=$(printf '%s\n' "$versions" | sort_desc | head -n1)
                echo "  latest version -> $target"
            else
                target=$version_filter
            fi
            if ! printf '%s\n' "$versions" | grep -qxF -- "$target"; then
                echo "  ! version '$target' not available; have: $(printf '%s' "$versions" | tr '\n' ' ')"
                continue
            fi
        fi

        while IFS= read -r v; do
            [ -n "$v" ] || continue
            [ -n "$target" ] && [ "$v" != "$target" ] && continue
            download_product_version "$product" "$v"
        done <<EOF
$versions
EOF
    done
}

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------

get_help() {
    cat <<EOL

  docsync-improved.sh - download Red Hat product documentation (PDF)
  Files are written under: <outdir>/<product>/<version>/

  $0 -h                            Show this help
  $0 -l                            List all products
  $0 -d <product> -l               List versions for a product
  $0 -d <product>                  Download every version of a product
  $0 -d <product> -v <version>     Download one specific version
  $0 -d <product> -l latest        Download only the newest version
  $0 -d ALL -l latest              Newest version of every product
  $0 -d ALL                        Every version of every product

  Options:
    -d <product|ALL>   product slug (see '-l'); ALL is case-insensitive
    -l [value]         no value   -> list mode
                       "latest"   -> newest version only
                       <version>  -> that exact version
    -v <version>       exact version (same as '-l <version>')
    -o <dir>           output directory (default: current directory)

  Environment:
    SLEEP=<seconds>    pause between PDF downloads (default: 0)

EOL
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

tool_check

if [ "$#" -eq 0 ]; then
    echo "No option specified. Try '$0 -h'." >&2
    exit 2
fi

action=""
product_arg=""
version_sel=""
do_list=0

while getopts ":d:o:v:lh" opt; do
    case "$opt" in
        d) product_arg="$OPTARG" ;;
        o) docdir="$OPTARG" ;;
        v) version_sel="$OPTARG" ;;
        l)
            # -l takes an OPTIONAL value: consume the next token only when it
            # exists and is not itself a flag.
            nextarg="${!OPTIND-}"
            if [ -n "$nextarg" ] && [ "${nextarg#-}" = "$nextarg" ]; then
                version_sel="$nextarg"
                OPTIND=$((OPTIND + 1))
            else
                do_list=1
            fi
            ;;
        h) action="help" ;;
        \?) echo "Unknown option: -$OPTARG" >&2; action="help" ;;
        :)  echo "Option -$OPTARG requires a value" >&2; exit 2 ;;
    esac
done

if [ -z "$action" ]; then
    if [ "$do_list" -eq 1 ] && [ -z "$product_arg" ]; then
        action="list_products"
    elif [ "$do_list" -eq 1 ] && [ -n "$product_arg" ] && [ -z "$version_sel" ]; then
        action="list_versions"
    elif [ -n "$product_arg" ]; then
        action="download"
    else
        action="help"
    fi
fi

is_all()    { [ "$(lc "$product_arg")" = "all" ]; }
is_latest() { [ "$(lc "$version_sel")" = "latest" ]; }

case "$action" in
    list_products)
        echo "Available products:"
        get_products | sed 's/^/  - /'
        ;;

    list_versions)
        if is_all; then
            while IFS= read -r p; do
                [ -n "$p" ] || continue
                echo "$p:"
                get_versions "$p" | sed 's/^/  - /' || echo "  (none)"
            done < <(get_products)
        else
            product_exists "$product_arg" || {
                echo "No such product: $product_arg (try '$0 -l')" >&2; exit 4; }
            echo "Available versions for <$product_arg>:"
            get_versions "$product_arg" | sed 's/^/  - /' || echo "  (none)"
        fi
        ;;

    download)
        mkdir -p "$docdir" || { echo "Cannot write to $docdir" >&2; exit 5; }

        if is_all; then
            if [ -n "$version_sel" ] && ! is_latest; then
                echo "A fixed version ('$version_sel') can't be combined with ALL." >&2
                echo "Use '-l latest', or name a single product." >&2
                exit 3
            fi
            products=$(get_products)
            if [ -z "$products" ]; then
                echo "Could not retrieve the product list from $website" >&2
                exit 7
            fi
            count=$(printf '%s\n' "$products" | grep -c .)
            echo "Downloading docs for ALL products ($count)${version_sel:+ - version: $version_sel}"
            set --
            while IFS= read -r p; do [ -n "$p" ] && set -- "$@" "$p"; done <<EOF
$products
EOF
            download_docs "$version_sel" "$@"
        else
            product_exists "$product_arg" || {
                echo "No such product: $product_arg (try '$0 -l')" >&2; exit 4; }
            echo "Downloading docs for <$product_arg>${version_sel:+ - version: $version_sel}"
            download_docs "$version_sel" "$product_arg"
        fi

        echo
        echo "Done. downloaded=$_OK  skipped=$_SKIP  failed=$_FAIL"
        [ "$_FAIL" -eq 0 ] || exit 1
        ;;

    help|*)
        get_help
        ;;
esac
