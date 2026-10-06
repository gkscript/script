---
name: gk-script (Netixx Grundkonfiguration)
description: One-window-system for a walk-away Windows 11 setup tool - every window is a signal you read from across the workshop.
colors:
  netixx-signal-blue: "#366EE8"
  netixx-signal-blue-hover: "#2F62D3"
  netixx-deep-blue: "#2955BC"
  netixx-band-subline: "#DCE6FF"
  done-green: "#107C10"
  done-green-subline: "#DFF6DD"
  caution-amber: "#FFC83D"
  caution-ink: "#241B00"
  caution-subline: "#4A3A00"
  caution-icon: "#9D5D00"
  fault-red: "#C42B1C"
  fault-red-subline: "#FDE7E9"
  mica-grey: "#F3F3F3"
  ink: "#1A1A1A"
  graphite: "#5C5C5C"
  white: "#FFFFFF"
  control-fill: "rgba(255, 255, 255, 0.70)"
  control-fill-hover: "rgba(255, 255, 255, 0.90)"
  control-fill-pressed: "rgba(255, 255, 255, 0.50)"
  control-stroke: "rgba(0, 0, 0, 0.14)"
typography:
  display:
    fontFamily: "Segoe UI Variable Display, Segoe UI"
    fontSize: "32px"
    fontWeight: 600
  subline:
    fontFamily: "Segoe UI Variable Text, Segoe UI"
    fontSize: "14px"
    fontWeight: 400
  title:
    fontFamily: "Segoe UI Variable Text, Segoe UI"
    fontSize: "15px"
    fontWeight: 600
  heading:
    fontFamily: "Segoe UI Variable Text, Segoe UI"
    fontSize: "14px"
    fontWeight: 600
  body:
    fontFamily: "Segoe UI Variable Text, Segoe UI"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: "19px"
  label:
    fontFamily: "Segoe UI Variable Text, Segoe UI"
    fontSize: "12px"
    fontWeight: 400
  mark:
    fontFamily: "Segoe Fluent Icons, Segoe MDL2 Assets"
    fontSize: "60px"
rounded:
  control: "6px"
  focus-ring: "9px"
spacing:
  gutter: "32px"
  band-block: "30px"
  section: "24px"
  mark-gap: "22px"
  row-gap: "8px"
  button-gap: "8px"
  list-gap: "9px"
components:
  band-menu:
    backgroundColor: "{colors.netixx-deep-blue}"
    textColor: "{colors.white}"
    typography: "{typography.display}"
    padding: "30px 32px"
  band-success:
    backgroundColor: "{colors.done-green}"
    textColor: "{colors.white}"
    typography: "{typography.display}"
    padding: "30px 32px"
  band-warning:
    backgroundColor: "{colors.caution-amber}"
    textColor: "{colors.caution-ink}"
    typography: "{typography.display}"
    padding: "30px 32px"
  band-failed:
    backgroundColor: "{colors.fault-red}"
    textColor: "{colors.white}"
    typography: "{typography.display}"
    padding: "30px 32px"
  button-standard:
    backgroundColor: "{colors.control-fill}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "7px 16px"
  button-standard-hover:
    backgroundColor: "{colors.control-fill-hover}"
  button-standard-pressed:
    backgroundColor: "{colors.control-fill-pressed}"
  button-accent:
    backgroundColor: "{colors.netixx-signal-blue}"
    textColor: "{colors.white}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "7px 16px"
  button-accent-hover:
    backgroundColor: "{colors.netixx-signal-blue-hover}"
  button-accent-pressed:
    backgroundColor: "{colors.netixx-deep-blue}"
  profile-row:
    backgroundColor: "{colors.control-fill}"
    textColor: "{colors.ink}"
    typography: "{typography.title}"
    rounded: "{rounded.control}"
    padding: "14px 16px 14px 18px"
  profile-row-hover:
    backgroundColor: "{colors.control-fill-hover}"
---

# Design System: gk-script (Netixx Grundkonfiguration)

## Overview

**Creative North Star: "The Workshop Signal Lamp"**

Every gk-script window is a signal lamp on the workbench. The technician starts a run and walks away, so the interface has one job when they look up from across the room: say *what state this machine is in* through color alone, before a single word is readable. A solid band of color carries that message: Netixx blue while choosing, green when done, amber when something needs a look, red when it stopped. Below the band, everything is calm. Windows 11 Mica, dark text, translucent controls that wait to be touched.

The system is unmistakably Netixx. The deep Netixx blue band, the Netixx app mark and the Netixx-blue accent action are recognizable at a glance. Windows 11 is the material it is built from: Mica backdrop, Segoe UI Variable, Segoe Fluent Icons, settings-card rows, rounded window corners. It sits on a fresh customer PC like part of the operating system, wearing Netixx colors. Windows 11 is the target. On Windows 10, the built-in fallbacks keep it clean (solid grey instead of Mica, Segoe UI instead of Segoe UI Variable, a default title bar).

There is exactly one window system. The profile menu and the result window share one theme file and one anatomy, so any future window is a third instance of the same lamp, not a new design.

**Key Characteristics:**
- One solid color band per window that also colors the title bar (and, for results, the taskbar button): the band is the message.
- A 60 px mark beside a 32 px display headline and a one-line subline, always in the band.
- Calm Mica field below with 32 px gutters, dark text and translucent-white controls.
- Flat throughout. No gradients, no drop shadows; depth comes from Mica versus solid band versus translucent control.
- One accent: Netixx signal blue marks the single most important action.
- Icons are drawn (Segoe Fluent Icons), never emoji.

## Colors

A disciplined palette: one brand blue in two strengths, three status signals, and a neutral Windows 11 ground.

### Primary
- **Netixx Deep Blue** (`netixx-deep-blue`): the menu's band and title bar, the profile-row icons, the restart icon, and the accent button's pressed state. It is the Netixx identity color at window scale. White on it is 6.7:1.
- **Netixx Signal Blue** (`netixx-signal-blue`): the one accent action (for example **Restart now**) and the text selection highlight. White on it is 4.6:1. It darkens to `netixx-signal-blue-hover` on hover.

### Secondary (status signals)
- **Done Green** (`done-green`): the band, title bar and taskbar progress of a successful run. Headline is white; the subline is tinted `done-green-subline`.
- **Caution Amber** (`caution-amber`): the band for "Finished with N warnings". It is the only light band, so its text is dark: headline `caution-ink`, subline `caution-subline`. Warning list icons use `caution-icon`.
- **Fault Red** (`fault-red`): the band for "Setup failed" and "Setup didn't start". Headline is white; the subline is tinted `fault-red-subline`.

### Neutral
- **Mica Grey** (`mica-grey`): the solid window background where Mica isn't available. On Windows 11 22H2+ the real Mica backdrop replaces it.
- **Ink** (`ink`): all primary text on Mica, and the keyboard-focus stroke and ring.
- **Graphite** (`graphite`): secondary text such as package lists, the log path, the footer and the chevrons. It reads 6:1 on Mica Grey.
- **Control fills** (`control-fill`, `-hover`, `-pressed`, with `control-stroke`): translucent white over Mica for buttons and profile rows.

### Named Rules
**The Signal Rule.** Status colors (green, amber, red) appear only in a result band, its title bar and taskbar button, and as small list icons. They never color a button or a background field below the band.

**The Tinted Subline Rule.** Secondary text on a colored band is tinted from that band's own hue (`*-subline`), never grey and never translucent white, and holds at least 4.5:1.

## Typography

**Display Font:** Segoe UI Variable Display (with Segoe UI)
**Body Font:** Segoe UI Variable Text (with Segoe UI)
**Icon Font:** Segoe Fluent Icons (with Segoe MDL2 Assets)

**Character:** the Windows 11 system faces, used with conviction. A large semibold display headline does the talking in the band; the text face stays small and even below.

### Hierarchy
- **Display** (600, 32px): the band headline, one per window ("Netixx Grundkonfiguration", "Setup complete", "Finished with 3 warnings").
- **Subline** (400, 14px): the single line under the headline (profile, machine, duration; or "Choose a setup profile · v2.2.2").
- **Title** (600, 15px): the profile name in a profile row.
- **Heading** (600, 14px): the one section heading below the band ("Needs attention", "What went wrong").
- **Body** (400, 13px, 19px line height): list items, button labels, the restart line.
- **Label** (400, 12px): package lists, the log path, the footer.
- **Mark** (60px icon glyph): the status symbol in the band (solid check, solid triangle, solid error badge).

### Named Rules
**The One Headline Rule.** Each window has exactly one display headline, and it lives in the band. Nothing below the band is larger than 15px.

## Layout

Every window is 600 px wide and sizes its height to content (`SizeToContent`), centered on screen. The structure is fixed:
1. **Band** (30 px top and bottom, 32 px sides): the mark, a 22 px gap, then the headline and subline stacked.
2. **Body**: starts 24 px below the band with 32 px gutters.
3. **Close-out**: the result window ends in a right-aligned button row (8 px between buttons, 22 px above, 26 px below). The menu ends with a centered footer label.

Spacing within a group is tight (8 px between rows, 9 px between list items); between groups it is generous (18–24 px). Long content scrolls inside the body (the warning list stops at 232 px), and the band and buttons never scroll away.

### Named Rules
**The Same Anatomy Rule.** A new window copies this structure exactly: 600 px, band, mark and headline, Mica body, 32 px gutters. If a design needs a different skeleton, it is a design-system change, not a window change.

## Elevation & Depth

The system is flat. Depth comes from material, not shadow. Three layers stack: the solid band (the loudest, fully opaque color), the Mica backdrop (the quiet ground, slightly tinted by the desktop wallpaper), and translucent-white controls floating on Mica (70% white at rest, 90% on hover). There are no drop shadows and no gradients anywhere. The old gradient-and-shadow buttons were removed for being out of character.

### Named Rules
**The Flat Surface Rule.** No `DropShadowEffect`, no `LinearGradientBrush` on any control or band. State is shown through fill opacity and an ink stroke, never through lift.

## Shapes

The shapes are gently rounded, following Windows 11 control geometry. Buttons and profile rows use a 6 px radius (`control`) with a 1 px `control-stroke` border. The keyboard focus ring is a 2 px ink outline 4 px outside the control, with a 9 px radius so it stays concentric. Bands are full-bleed rectangles, and the window corners come from DWM (Windows 11 rounded windows). Icons are single-weight Segoe Fluent glyphs. The band marks use the solid variants (`CompletedSolid`, `IncidentTriangle`, `StatusErrorFull`) so all three states carry equal weight at distance.

## Components

Character: **calm and graspable**. Light, translucent surfaces on Mica with a clear outline on focus. Netixx blue is reserved for the one action that matters.

### Buttons
- **Shape:** gently rounded (6px), 1 px `control-stroke` border, at least 104 px wide.
- **Standard:** `control-fill` with ink text, padding 7 px × 16 px. Used for **Open log** and **Close**.
- **Accent:** `netixx-signal-blue` with white text. At most one per window, for the action the technician most likely wants (**Restart now**).
- **Hover / Pressed:** the fill goes to `control-fill-hover` / `control-fill-pressed`. The accent goes to `netixx-signal-blue-hover` / `netixx-deep-blue`. Changes are instant, with no animation.
- **Focus:** 1 px ink stroke whenever keyboard-focused, plus the 2 px ink focus ring during keyboard navigation.
- **Keys:** Close is `IsCancel` (Esc), and it is also `IsDefault` (Enter) when no restart is offered.

### Profile Row (signature component)
The profile button in the menu follows the Windows 11 settings-card idiom: a full-width translucent row (padding 14 px × 16 px, 18 px on the left, 6 px radius, 8 px between rows).
- **Layout:** a 22 px Segoe Fluent icon in `netixx-deep-blue` (from the `Icon` column in `gui.csv`), an 18 px gap, the profile name (Title) over its package list (Label, Graphite, wrapping), and a 12 px chevron in Graphite on the right.
- **States:** same surface and states as the standard button (hover, pressed, keyboard stroke and ring). Disabled rows (after a click) drop to 55% opacity.
- **Accessibility:** the screen-reader name is the profile name with any leading symbol removed, and the help text is the package list.

### Band (signature component)
The colored top field of every window, and the system's signal.
- **Menu:** `netixx-deep-blue`, with the Netixx app mark (60 px image), headline "Netixx Grundkonfiguration" and subline "Choose a setup profile · version".
- **Result:** the status color, with the solid status mark (60 px glyph), a status headline and a subline (profile · machine · duration, plus "Restart required" when pending).
- **Reach:** DWM paints the title bar and window border in the band color, so the band starts at the window's top edge. Result windows also set a full green, amber or red taskbar button (`TaskbarItemInfo`).

### Toggle Switch
The run options sit in one card below the profile rows, one switch per row with a 1 px `control-stroke` hairline between them: "install only (remove nothing)" (`-InstallOnly` when on, off by default) and "install all updates" (`-SkipUpdates` when off, on by default). The settings they control are real.
- **Container:** the same surface as a profile row (`control-fill`, 1 px `control-stroke`, 6 px radius, 12 px × 16 px padding, 18 px on the left).
- **Content:** the label (14px semibold) and a hint (Label, Graphite) on the left; the Windows 11 toggle shape (40 × 20, 10 px radius) on the right.
- **States:** off is a grey outline with a grey thumb on the left; on is a `netixx-signal-blue` track with a white thumb on the right.
- **Hover and focus:** hover darkens the outline, and keyboard focus gives an ink outline plus the focus ring.
- Defaults: install only off, updates on.

### Language Chips
Quiet DE · EN · IT selector in the top-right corner of the menu band, sitting in the band's top padding. The chips are grouped radio buttons (`LanguageChip`), 12px, with 7 px × 2 px padding and a 4px radius.
- **Inactive:** the band's tinted subline color, with no fill.
- **Active:** white semibold on a faint white fill (18%).
- **Hover:** 10% white fill.
- **Focus:** white 1 px stroke plus the white `BandFocusRing`, because an ink ring would disappear on blue.
- **Labels and names:** the labels are language codes and never get translated. The screen-reader names use each language's own name (Deutsch, English, Italiano).

### Update hint (menu)
When GitHub has a newer release, one line appears under the band's subline: 13 px semibold, white, underlined - a plain hyperlink ("Neue Version 2.2.0 verfügbar - hier herunterladen") that opens the download. No badge, no color: the band already carries the brand; the link is quiet until it is needed.

### Handover report (HTML)
`C:\Install\Einrichtungsprotokoll.html` follows the window system on paper: a Netixx-blue band with the 28 px Display headline and a `#DCE6FF` subline, then label/value tables (labels Graphite, 1 px `#E5E5E5` rules), section headings in Netixx blue, items needing attention in the warning text color `#9D5D00`. Prints with the band (print-color-adjust).

### Question (result window)
The result window doubles as the one question the tool asks: before a full run on a PC that looks used. Warning band, the signs listed under a plain heading, and three buttons in place of Open log / Close: the safe choice ("Nur nachinstallieren") is the accent button and the default; "Abbrechen" is Esc. No log row.

### Choice rows (result window)
When a question offers longer choices (office.ps1's product choice), each choice is a row with the menu's profile-row anatomy: 15 px semibold title, Label caption, chevron, the full row clickable. The band is the menu's Netixx blue (`Question`), because a choice is not an outcome. "Abbrechen" stays an action button bottom right.

### Notes (result window)
These are steps left to the technician that are not problems, such as confirming default apps for the current account.
- **Placement:** below the attention list.
- **Style:** a 13 px info icon (`netixx-deep-blue`) with Graphite body text.
- **Effect:** they never change the band color, so they never turn a green run yellow.

### Attention List
The body of a warning or failure result: a Heading, then items made of a 13 px triangle icon (`caution-icon`, or `fault-red` for failures) and body text, 9 px apart, scrolling past 232 px. When nothing needs attention it collapses to one plain line. When a restart is the only open item, the restart becomes the heading.

## Do's and Don'ts

### Do:
- **Do** build every window from `src/lib/Theme.xaml`, injected at the window's `<!--THEME-->` placeholder, and use its styles (`Band`, `BandTitle`, `BandSubtitle`, `BandMark`, `ActionButton`, `AccentButton`, `ProfileRow`, `Caption`, `InlineIcon`).
- **Do** let the band color carry the state, and paint the title bar to match with `Set-WindowCaptionColor`.
- **Do** check every text color against its band at 4.5:1 or better. Use the band's own tinted subline color (`*-subline`).
- **Do** use Segoe Fluent Icons for every icon, with solid glyphs for band marks.
- **Do** keep at most one Netixx-signal-blue accent button per window.
- **Do** take every visible string from `src/lang/<code>.json` (German default, English, Italian). Check new copy in German, because it runs about 30% longer than English ("Einrichtung abgeschlossen").

### Don't:
- **Don't** create a window with its own layout or local styles that bypass the theme. A new window is another instance of the same anatomy, and a style change goes into `Theme.xaml`.
- **Don't** use gradients or drop shadows on bands or controls (`LinearGradientBrush`, `DropShadowEffect`). That was the old Windows 10 look.
- **Don't** use emoji as icons, in labels, or in `gui.csv` names. Screen readers announce them, and they clash with the Fluent icon set.
- **Don't** put status green, amber or red on buttons or below the band.
- **Don't** put a second display-size headline below the band.
