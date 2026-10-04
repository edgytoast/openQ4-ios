# In-world GUI touch — how it works today, and what it needs

Charter Phase 2: "in-world interactive GUIs usable by **direct touch**" — the
consoles, ammo stations and airlock panels that are the idTech 4 showpiece.
This is a study, written before any code. Nothing here is implemented.

## 1. What this build does today

**The in-world GUI cursor is view-centred. There is no mapping from a touch
point onto the GUI surface anywhere in this port.**

The chain, engine first:

- **Shell** — `ios/shell/openq4_ios_touch.m`. The overlay owns the sticks and
  the button cluster. A drag in the free area is *look*; it is published as
  absolute view degrees, not as mouse deltas. A tap in the free area that is not
  on a control does nothing at all in gameplay (it only serves the "press any
  key" and cinematic-skip cases, `openq4_ios_touch.m:952-959`).
- **Look** — overlay patch `0008` (`src/framework/UsercmdGen.cpp`,
  `TouchLook`/`TouchMove`/`TouchButton`). Touch look is applied straight to the
  view angles in degrees, deliberately bypassing the mouse chain. Buttons come
  in by *name* and set `buttonState[]`, which is what produces
  `usercmd.buttons & BUTTON_ATTACK`.
- **Mouse plane** — overlay patch `0005` (`src/sys/sdl3/sdl3_backend.cpp`). Two
  separate input planes exist and are not interchangeable: the sys event queue
  (`SE_MOUSE`, feeds full-screen GUIs, console, binds) and `s_mouseQueue`
  (feeds `usercmd.mx/my`, which is what the weapon wheel and `RouteGuiMouse`
  read). The shell writes the second only for the weapon wheel; SDL's own
  touch→mouse translation feeds the first, which is why the *menus* answer a
  finger directly today.
- **Game** — `vendor/openQ4-game/src/game/Player.cpp`:
  - `idPlayer::UpdateFocus` (7674) casts `start = GetEyePosition()`,
    `end = start + viewAngles.ToForward() * 768` — the **crosshair ray** — and
    for each candidate entity with an interactive GUI calls
    `gameRenderWorld->GuiTrace()` (8198). The normalised hit point is fed to the
    GUI absolutely: clamp to the corner with `GenerateMouseMoveEvent(-2000,-2000)`
    then `GenerateMouseMoveEvent( pt.x * SCREEN_WIDTH, pt.y * SCREEN_HEIGHT )`
    (8283-8290), then `SetFocus( FOCUS_GUI, ... )`.
  - Distance rules: hit > 300 units clears focus, > 80 units gives brackets only
    (visible, not operable), ≤ 80 units is an operable panel.
  - `idPlayer::Weapon_GUI` (7287) turns a **`BUTTON_ATTACK` edge** into
    `GenerateMouseButtonEvent( 1, down )` on `ActiveGui()`.
  - Q4 differs from Doom 3 here: `allowFocus` was removed by Raven
    (`Player.cpp:8103`), so focusing is *not* blocked while attack is held.

So the interaction today is the desktop idiom: **aim the crosshair at the panel
with the look drag, then press the fire button.** It works — the cursor lands
where the crosshair points because the engine's own path is already absolute —
but nothing anywhere maps "the pixel the player touched" onto the panel.

Two adjacent gaps worth recording: the full-screen objective/PDA GUI is driven
by `idPlayer::RouteGuiMouse` (10782) from `usercmd.mx/my` **deltas**, which is
the exact bug dhewm3 hit (below) — **this is wrong, see D-081: that call site is
unreachable and the objectives GUI has nothing to click**; and the touch overlay
does not hide itself for
an in-world GUI (correct — gameplay continues), so a panel tap must coexist with
the sticks.

## 2. What dhewm3-ios did (`~/dev/dhewm3-ios`, D-013/D-014, `docs/pda-touch.md`)

- **D-013, full-screen PDA:** a *relative* cursor cannot be aimed by a finger —
  no proprioception on glass — so the shell maps the touch point into the GUI's
  own 640×480 space and the game applies it with `idUserInterface::SetCursor`
  plus a zero-delta move so hover re-evaluates. Two traps banked: "touch owns
  the cursor" must be a **separate flag** from "a new position is pending", or
  look deltas nudge the cursor between touches; and the **click must be held two
  frames**, because a down+up inside one 60 Hz tic can net the button state back
  to zero before `CmdButtons()` runs and the click vanishes silently.
- **D-014, in-world panels:** the cursor was never the problem — the **ray**
  was. It now goes from the eye through the *touched screen point*, built from
  the view basis and the half-angle tangents of `gameLocal.CalcFov`. Verified by
  sign on all three axes, with the centre touch reproducing the crosshair
  bit-for-bit (an identity at the old operating point). Two interaction rules: a
  drag past `TAP_SLOP` stops steering the ray (otherwise focus follows the
  player's thumb while walking), and the ray must lead the click. Shipped
  default-on behind a "Touch Panels Directly" setting, because the maths was
  verified but no real panel had ever been clicked.
- Two process lessons that apply here verbatim: **a harness that re-implements
  the behaviour it tests will pass while the product is broken** (their
  synthetic tap did not share the real tap path), and **never gate a diagnostic
  on the subsystem you are debugging** (`com_developer` reads false inside the
  game module).

## 3. Recommended design for openQ4-ios

**Adopt D-014's shape, transported over cvars, and treat the game-side overlay
as the real cost.**

1. **The blocker is mechanical, not conceptual: there is no overlay mechanism
   for `openQ4-game`.** `scripts/sync-overlay.sh` stages the game sources
   straight from `vendor/openQ4-game` through upstream's `stage_gamelibs.py`
   with no patch step. `UpdateFocus` lives there, so this feature cannot happen
   until the overlay grows a second patch set (a `overlay/patches-game/` applied
   to the staged tree, mirrored in `regen-patches.sh`). Do that first, as its
   own change, with one trivial patch to prove it — a pin bump must fail loudly
   on a game patch exactly as it does on an engine patch.
2. **Transport: cvars, not a new game API.** The game modules are separate
   signed dylibs reached through the fixed game API; the shell cannot call into
   them. Three engine cvars written by the shell (`in_touchAimActive`,
   `in_touchAimX`, `in_touchAimY`, NDC in [-1,1]) are read by `UpdateFocus`
   through `cvarSystem` with no ABI change, no usercmd field (which would touch
   the network protocol and demos) and nothing to keep in sync across a pin bump.
3. **Shell:** on touch-down in the free area publish the NDC point; clear it
   once the touch passes `TAP_SLOP` (it is a look drag, not a panel tap) and on
   touch-up after a settling delay. Hook: the same handlers that already own
   look, `openq4_ios_touch.m`.
4. **Game patch:** in `UpdateFocus`, when `in_touchAimActive` is set, replace the
   ray direction with the view basis × `CalcFov` half-angle tangents applied to
   the published NDC — the rest of the function (GuiTrace, the absolute
   `pt.x * SCREEN_WIDTH` move, the 80/300-unit rules) is untouched and already
   correct. The centre case must come out bit-for-bit equal to
   `viewAngles.ToForward()`; check the sign of all three axes, as dhewm3 did.
5. **Click:** keep `Weapon_GUI`'s `BUTTON_ATTACK` edge. The shell injects
   attack down/up on the tap, held **≥ 2 tics** (D-013's rule; the same hazard
   exists here). Q4's removed `allowFocus` means the ray does not have to lead
   the click by much, but publishing the ray on touch-*down* and clicking on
   touch-*up* gets the ordering free anyway.
6. **Setting:** "Touch Panels Directly", default on, in the existing iOS
   settings sheet; off publishes nothing and the build is byte-for-byte Q4's
   crosshair behaviour.
7. ~~**Do the full-screen objective GUI (D-013's half) as a separate, later
   round.** It is the same game file and the same transport, but a different
   bug (`RouteGuiMouse` deltas → `SetCursor` absolute), and mixing them makes
   both harder to verify.~~ **Wrong — see DECISIONS D-081 (2026-09-10).**
   `RouteGuiMouse` is unreachable in both game modules (`ActiveGui()` returns
   `focusUI`, so its `gui != focusUI` guard is never true), Quake 4's
   objectives GUI is `nocursor 1` with zero `onAction` handlers in retail AND
   in openQ4's replacement, and every full-screen GUI that IS interactive runs
   on the session's sys-event plane, which upstream's SDL3 backend already
   feeds an absolute finger. There is no bug here and no work to do.

**Expected size:** game-overlay mechanism ~80 lines of script plus a doc; the
game patch ~60 lines in one function; the shell ~80 lines; the settings entry
and cvar bridge ~40. Call it a two-round change, where round one is the overlay
mechanism alone.

## 4. How it gets verified

The simulator can load a map and render the 3D world (proven this round:
`game/mcc_1` on lane 1), so the *engine* half is exercisable there. What the
simulator cannot do is **tap at a coordinate**: GUI automation is unavailable to
agent sessions (no Accessibility grant — STATUS "Open questions"), so a finger
on glass is device-gated.

Therefore verification is bridge-and-log first, device last:

- Add `!touchtap <x> <y>` to the console bridge that calls **the real
  touch handlers** — never a re-implementation (dhewm3's harness lesson).
- An **unconditional** `[touchaim]` print (not gated on `com_developer`, which
  reads false inside the game module) giving: the published NDC, the resulting
  direction, `dot(dir, fwd/right/up)`, and the centre-touch identity check.
- On focus, a line naming the focused entity, the `guiId`, the GUI hit point and
  the distance bucket (usable / brackets / cleared), plus the command string
  `HandleEvent` returns on the click. A panel that answers prints a command; a
  panel that is merely focused does not.
- A content screenshot showing the USE brackets on the panel, and a second after
  the click showing the panel's own state change.
- **The known blocker from dhewm3 applies:** they never found an interactive
  panel within the 80-unit focus trace anywhere reachable. Q4's early maps are
  full of them (mcc_1's consoles, the med-lab station), so the first task in the
  implementing round is to record a route to one and note it here — that route
  is worth more than the code.
- Device verdict from the maintainer over OTA: tap a panel, does it operate.

---

## 5. What was actually built (2026-09-06) — D-070, D-071

The design above shipped nearly unchanged. Deltas worth recording:

- **The blocker is closed.** `overlay/patches-game/` exists, with the engine's
  discipline (rsync-from-pristine, `--fuzz=0`, hard fail on a reject) and its
  own table and rot checks in `regen-patches.sh`. **D-070.**
- **Four cvars, not three.** `in_touchAimActive` / `in_touchAimX` /
  `in_touchAimY` as designed, plus `in_touchAimSeq` (bumped once per tap, so
  the game's `[touchaim]` line is throttled per TAP rather than per tic or per
  second) and `in_touchAimClick`.
- **The click is not `BUTTON_ATTACK`.** Section 3.5 above proposed injecting
  attack. That was wrong for this engine: fire and use are the same button, so
  an injected attack on a tap that missed a panel would shoot the wall. The
  click is its own cvar, consumed in `Weapon_GUI` — a function only reached
  when a gui already has focus — so a tap can click a panel and can never fire
  the weapon. **D-071.**
- **The published point is the touch-DOWN point and it does not follow the
  finger.** Publishing on down gives the ray the whole duration of the touch to
  lead the click for free; a move past `TAP_SLOP` (16 pt) retires the tap and
  clears the aim, and so does a `touchesCancelled`.
- **`!touchtap <nx> <ny>`** is on the bridge, ahead of `!touch` in the dispatch
  (that one is a six-character `strncmp` and swallowed every tap silently until
  it was moved).
- **A route to a real interactive panel is still not recorded.** See D-071's
  verification section: the maths is proven by sign on all three axes on the
  simulator, and a panel has never been clicked anywhere in this port. The
  device is where that is settled.
