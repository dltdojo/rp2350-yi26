# SPDX-License-Identifier: Apache-2.0
#
# The checks every appliance page here gets, sourced by an experiment's
# check.sh after ../lib.sh (for pass and fail):
#
#   page_parses PAGE WORK        the page's <script> parses (node --check)
#   page_findcdc PAGE            its findCdc is tools/pages/log.html's, byte for byte
#   page_mutant WHAT SED PAGE CMD...
#                                a copy of PAGE with SED applied must make CMD
#                                fail; CMD names the copy as @
#   page_playwright              true when Playwright can be loaded
#
# From exp227's check.sh, the second page to need them being exp228's.

PAGES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

page_parses() { # page work
    sed -n '/^<script>$/,/^<\/script>$/p' "$1" | sed '1d;$d' > "$2/page.js"
    if node --check "$2/page.js" 2> "$2/syntax"; then
        pass "the page's script parses (node --check)"
    else
        fail "the page's script parses" "$(head -3 "$2/syntax")"
    fi
}

page_findcdc() { # page
    local mine theirs
    mine="$(awk '/^function findCdc\(/,/^}$/' "$1")"
    theirs="$(awk '/^function findCdc\(/,/^}$/' "$PAGES_DIR/log.html")"
    if [[ -n "$mine" && "$mine" == "$theirs" ]]; then
        pass "findCdc is tools/pages/log.html's, byte for byte"
    else
        fail "findCdc is tools/pages/log.html's, byte for byte" "it has drifted"
    fi
}

page_mutant() { # what sed page cmd...
    local what="$1" change="$2" page="$3" work arg
    shift 3
    work="$(mktemp -d)"
    sed "$change" "$page" > "$work/$(basename "$page")"
    local cmd=()
    for arg in "$@"; do [[ "$arg" == @ ]] && cmd+=("$work/$(basename "$page")") || cmd+=("$arg"); done
    if cmp -s "$page" "$work/$(basename "$page")"; then
        fail "the tests catch a page where $what" "the change did not apply"
    elif "${cmd[@]}" > "$work/out" 2>&1; then
        fail "the tests catch a page where $what" "every test still passes"
    else
        pass "the tests catch a page where $what: $(grep -m1 '^FAIL' "$work/out" | sed 's/^FAIL  //' | cut -c1-110)"
    fi
    rm -rf -- "$work"
}

page_playwright() {
    node -e "try { require('playwright') } catch { require(require('child_process').execSync('npm root -g').toString().trim() + '/playwright') }" 2> /dev/null
}
