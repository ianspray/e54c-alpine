#!/bin/sh
# -------------------------------------------------
ROOT="/src"
CACHE="/etc/apk/cache"

find_pkgs() {
    find "$ROOT" -type f \( -name "*.sh" -o -name "Dockerfile*" -o -name "Containerfile*" \) | while read -r f; do
        sed ':a;/\\$/N;s/\\\n/ /;ta' "$f" |
        grep -Eo 'apk[[:space:]]+add[[:space:]]+[^&|;#]*' | while read -r line; do
            echo "$line" | tr -s '[:space:]' '\n' |
                grep -v '^$' |
                grep -v '^apk$' |
                grep -v '^add$' |
                grep -v '^-' |
                grep -v '[$`/]' |
                sed 's/=.*//'
        done
    done | sort -u > /tmp/apklist.tmp
    cat /tmp/apklist.tmp
}

fetch_pkg() {
    pkg=$1

    apk info --quiet --recursive --depends "$pkg" 2>/dev/null \
	| grep -v '^so:'  \
	| grep -v '^cmd:' \
	| grep -v '^/'    \
	| sed 's/[><=!].*//' \
	| grep -v '^$' \
	| sort -u \
	| while read -r dep; do
        [ -z "$dep" ] && continue
        if ls "${CACHE}/${dep}-"*.apk 2>/dev/null | grep -q .; then
            echo "Skipping $dep (already cached)"
        else
            echo "Fetching $dep ..."
            apk fetch --output "${CACHE}" "$dep"
        fi
    done
}

##########
# M A I N
#

mkdir -p "${CACHE}"

apk update -q

find_pkgs
pkgs=$(cat /tmp/apklist.tmp)

[ -z "$pkgs" ] && echo "No apk packages found." && exit 0

echo "$pkgs" | while read -r p; do
    [ -n "$p" ] && fetch_pkg "$p"
done

echo ""
echo "Cached APKs in $CACHE"
