#!/usr/bin/env python3
"""gen-ios-demo-menu-gui.py — the touch-scale demo library GUI.

    vendor/openQ4/content/baseoq4/pak0/guis/demo_menu.gui
        -> build/ios-gen/guis/demo_menu.gui   (staged loose into the bundle)

openQ4 already ships the entire demo library — browser, filters, transport,
seek, speed — in ONE gui, and the engine side (Session_demo.cpp) is complete.
Nothing about it needs porting. What it needs is FINGERS: the transport buttons
are 30 units tall in a 640x480 space, which on a 440 pt-tall landscape phone is
about 27 pt, well under the 44 pt Apple asks for and under what anyone can hit
while a demo is playing.

So this is a LAYOUT derivation, not a fork. A table of windowDef -> rect, each
entry asserted to match exactly once, applied to pristine upstream every build.
When upstream moves a control the assertion fails loudly and this file is
re-aimed, instead of a stale 1800-line copy silently shipping last month's
screen (charter ground rules 1 and 3).

The one behavioural change: the 0.25x and 4x speed chips are given a zero rect,
because five chips plus Free roam plus Follow plus Stop do not fit on one row at
a thumb's size. 0.5x / 1x / 2x are the speeds a phone viewer wants.

Horizontal placement assumes D-085's safe viewport: the gui's 0..640 now lands
inside the display's safe area, so the columns keep upstream's x where they can.
"""

import sys
import os
import re

# windowDef name -> the rect line's replacement value.
#
# Row A (transport) y=95 h=50, row B (modes and speed) y=153 h=50, both inside
# the existing 204-unit deck (rect 0,276,640,204), 8 units of gap everywhere.
# Browser: filter chips 25 -> 34 tall, list rows 20 -> 32.
RECTS = {
    # --- browser: filter chips and their "active" underlays -----------------
    "demo_filter_all":              "20,80,66,34",
    "demo_filter_all_active":       "1,1,64,32",
    "demo_filter_mvd":              "90,80,92,34",
    "demo_filter_mvd_active":       "1,1,90,32",
    "demo_filter_render":           "186,80,78,34",
    "demo_filter_render_active":    "1,1,76,32",
    "demo_filter_legacy":           "268,80,70,34",
    "demo_filter_legacy_active":    "1,1,68,32",
    "demo_filter_incomplete":       "342,80,90,34",
    "demo_filter_incomplete_active": "1,1,88,32",

    # --- playback deck, row A: transport ------------------------------------
    "demo_skip_back_30":            "20,95,66,50",
    "demo_skip_back_30_disabled":   "20,95,66,50",
    "demo_skip_back_10":            "94,95,66,50",
    "demo_skip_back_10_disabled":   "94,95,66,50",
    "demo_pause":                   "168,95,86,50",
    "demo_resume":                  "168,95,86,50",
    "demo_step":                    "262,95,66,50",
    "demo_step_disabled":           "262,95,66,50",
    "demo_skip_forward_10":         "336,95,66,50",
    "demo_skip_forward_10_disabled": "336,95,66,50",
    "demo_skip_forward_30":         "410,95,66,50",
    "demo_skip_forward_30_disabled": "410,95,66,50",
    "demo_playback_close":          "492,95,96,50",

    # --- playback deck, row B: speed, view mode, stop ------------------------
    "demo_speed_label":             "20,170,50,18",
    # Dropped on a phone: three speeds is what fits at a thumb's size.
    "demo_speed_quarter":           "0,0,0,0",
    "demo_speed_four":              "0,0,0,0",
    "demo_speed_half":              "74,153,56,50",
    "demo_speed_one":               "138,153,56,50",
    "demo_speed_two":               "202,153,56,50",
    "demo_free":                    "266,153,94,50",
    "demo_free_disabled":           "266,153,94,50",
    "demo_follow":                  "368,153,120,50",
    "demo_follow_disabled":         "368,153,120,50",
    "demo_stop":                    "496,153,76,50",
}

# Non-rect single-line substitutions: exact old line -> new line, each asserted
# to appear exactly once.
LINES = {
    "\t\t\titemheight\t20": "\t\t\titemheight\t32",
}

WINDOWDEF = re.compile(r"^\s*windowDef\s+(\S+)\s*$")
RECT = re.compile(r"^(\s*)rect(\s+)(.*)$")


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: gen-ios-demo-menu-gui.py <src.gui> <dst.gui>\n")
        return 2
    src, dst = sys.argv[1], sys.argv[2]

    with open(src, "r", encoding="utf-8", errors="surrogateescape") as f:
        lines = f.read().split("\n")

    hits = {name: 0 for name in RECTS}
    line_hits = {k: 0 for k in LINES}

    pending = None          # the windowDef whose first rect we are waiting for
    out = []
    for line in lines:
        m = WINDOWDEF.match(line)
        if m:
            pending = m.group(1)
            out.append(line)
            continue

        if line in LINES:
            line_hits[line] += 1
            out.append(LINES[line])
            continue

        rm = RECT.match(line)
        if rm and pending is not None:
            name = pending
            pending = None          # only the windowDef's OWN rect, never a child's
            if name in RECTS:
                hits[name] += 1
                out.append("%srect%s%s" % (rm.group(1), rm.group(2), RECTS[name]))
                continue
        out.append(line)

    missed = [n for n, c in hits.items() if c != 1]
    if missed:
        sys.stderr.write(
            "FATAL: demo_menu.gui layout table is stale — these windowDefs did not "
            "match exactly once: %s\n" % ", ".join(sorted(missed)))
        sys.stderr.write("       upstream moved them; re-aim scripts/gen-ios-demo-menu-gui.py\n")
        return 1
    missed_lines = [k for k, c in line_hits.items() if c != 1]
    if missed_lines:
        sys.stderr.write(
            "FATAL: demo_menu.gui line table is stale: %r\n" % missed_lines)
        return 1

    header = (
        "// GENERATED by scripts/gen-ios-demo-menu-gui.py from pak0's demo_menu.gui.\n"
        "// Touch-scale layout only (openQ4-ios D-086). Do not edit by hand.\n")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(header)
        f.write("\n".join(out))

    print("    guis/demo_menu.gui  %d windowDefs re-laid, %d lines rewritten"
          % (len(RECTS), len(LINES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
