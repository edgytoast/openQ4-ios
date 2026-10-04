# Demos on iOS

openQ4 already had the whole demo system — recording, a library that scans and
classifies what it finds, a browser, and a transport with pause, step, seek and
speed. The port adds three small things: a touch-scale layout for the one GUI
that carries all of it, a rule that hides the controls while a demo plays, and a
way to start a recording without a keyboard.

## Where demos live

`Documents/baseoq4/demos/` inside the app's container — the same folder the app
exposes in **Files > On My iPhone > openQ4**, so demos can be copied off the
device, backed up, or dropped in from a desktop openQ4 to watch on the phone.

## Recording

**Settings (the gear) > Demos > Record Demo.** The sheet closes, and the row
reads **Stop Recording** while a recording is in progress. Stopping writes the
file out; it appears in the browser immediately.

The recording is named `demo000.demo`, `demo001.demo`, … automatically. To
choose a name, use the console (`recordDemo mydemo`) — there is no on-screen
keyboard path for it, and one name per session has not been worth a text field.

## Watching

**Main menu > Demos.** Tap a demo to select it — the panel underneath shows its
type, status and what it supports — then **Play**. Filters across the top narrow
the list to Multi-view, Render, Legacy or Incomplete demos.

While a demo plays the touch controls are gone: there is nobody to steer, and a
fire button on top of the thing you are watching helps no one. The gear and the
hamburger stay. **Tap the hamburger to open the transport**, which also pauses;
tap **Close** to go back to watching, or **Stop** to leave.

The transport has −30 / −10 / Pause-Resume / Step / +10 / +30 on the first row
and speed (0.5x, 1x, 2x) plus the view-mode buttons and Stop on the second.
*Free roam* and *Follow next* are greyed out unless the demo is a multi-view
demo that supports them.

## What is different from the desktop

* The buttons and list rows are larger — transport controls are 50 units tall
  against upstream's 30, list rows 32 against 20, filter chips 34 against 25.
* The 0.25x and 4x speeds are not offered. Five speed chips plus the two
  view-mode buttons and Stop do not fit on one thumb-sized row.
* Everything is inside the display's safe area, so nothing hides under the
  Dynamic Island or a rounded corner.

The layout is generated from upstream's own `demo_menu.gui` every build
(`scripts/gen-ios-demo-menu-gui.py`) and shipped as a loose override beside the
paks, the same way `openq4_profile_ios.cfg` is. It is not a fork: if upstream
moves a control, the build fails loudly rather than shipping a stale copy.
