#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""calls/vk26/alice/pages — one page, one file: what a phone opens.

  build.py PAGE OUT      OUT is PAGE with each `<script src="…"></script>`
                         and `<link rel="stylesheet" href="…">` line that
                         names a file under alice's pages/ replaced by that
                         file, inline, and a script block that follows another
                         at once joined to it; nothing else in PAGE changes

An experiment's page is thin and loads the shared parts from ../pages/, so
that it runs from the repository as it is and the judge's bundle sees the
same files (judge-bundle.sh). A phone that opens one file from its Files app
cannot follow a relative path; the built page needs none.
"""
import os
import re
import sys

PAGES = os.path.dirname(os.path.abspath(__file__))


def build(page):
    here = os.path.dirname(os.path.abspath(page))
    out = []
    for line in open(page, encoding="utf-8").read().split("\n"):
        m = re.fullmatch(r'<script src="([^"]+)"></script>|<link rel="stylesheet" href="([^"]+)">', line)
        path = m and os.path.normpath(os.path.join(here, m.group(1) or m.group(2)))
        if not m or os.path.dirname(path) != PAGES:
            out.append(line)
            continue
        body = open(path, encoding="utf-8").read().rstrip("\n")
        tag = "script" if m.group(1) else "style"
        out += [f"<{tag}>", f"/* {os.path.basename(path)}, from calls/vk26/alice/pages/ by build.py */", body, f"</{tag}>"]
    # A shared script and the page's own, one after the other, become one
    # block: what tools/pages/pagecheck.sh's page_parses reads.
    return "\n".join(out).replace("\n</script>\n<script>\n", "\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    open(sys.argv[2], "w", encoding="utf-8").write(build(sys.argv[1]))
