# space-arrange

Move macOS Spaces between displays by dragging their Mission Control thumbnails, driven by
app → display rules. Built for commuting between desks with different monitor setups:
plug in, run one command, every Space lands on the right screen.

No SIP changes. Uses Accessibility + a few SkyLight calls (private, read-only except window resize).

## Install

    make install          # builds with swiftc, installs to ~/.local/bin/space-arrange
    cp config.example.json ~/.config/space-arrange/config.json

The terminal running it needs Accessibility permission (System Settings → Privacy & Security).

## Usage

    space-arrange --list               # every display, its Spaces and the apps in them
    space-arrange --dry-run            # print the plan only
    space-arrange                      # move Spaces
    space-arrange --fit                # ... then resize windows of moved Spaces to fill their new display
    space-arrange --fit-all            # ... resize windows of every Space
    space-arrange --reserve            # keep an empty first Space on each external display
    space-arrange --fit --reserve      # the commute command

## Config (`~/.config/space-arrange/config.json`)

```json
{
  "rules": [
    { "apps": ["Google Chrome"],    "displays": ["external:2", "external:1"] },
    { "apps": ["iTerm2", "Claude"], "displays": ["external:1"] }
  ],
  "fallback": "builtin"
}
```

- `apps`: window owner names as shown by `--list`.
- `displays`: ordered preferences. `builtin` is the internal display, `external:1` the external
  display with the most pixels, `external:2` the next, and so on. A literal display name also works.
  The first entry that exists right now wins, so one config covers every desk.
- `fallback`: where Spaces of unlisted apps go.

A Space belongs to the app with the largest window area in it. Apps named in a rule win near-ties.

## How it works

- Space → display is read from `SLSCopyManagedDisplaySpaces`; windows per Space from
  `SLSCopySpacesForWindows`; hidden windows are filtered with `SLSWindowIsOrderedIn`.
- Moving a Space opens Mission Control and drags the Space thumbnail onto another display's bar
  (the only way to move a Space without disabling SIP). A display's currently shown Space cannot
  be dragged, so the tool shows another Space first. The target bar re-lays out while the drag is
  over it, so the tool re-reads the thumbnails and drops past the rightmost one: moved Spaces land
  at the end, and a freshly connected display's empty Space stays first.
- A window belongs to the display its frame is on. macOS sometimes leaves a moved Space's windows
  behind on the source display's current Space; after every move the tool compares the Space's
  windows with what arrived, shows the Space on its new display, and drags the stragglers' frames
  onto that display through Accessibility, which makes them join the Space.
- `--fit` switches each display to the Space and resizes windows through Accessibility, since
  AX only exposes windows on visible Spaces.
- Mission Control is detected through the Dock's overlay windows rather than its Accessibility
  tree, which can lag several seconds; opening Mission Control.app toggles it, so the tool only
  opens it when it is not already up.
- `--reserve` exists because macOS collapses a display's *first* Space into another Space when the
  display is unplugged, while the other Spaces move intact. An empty first Space means nothing gets
  merged.
- Fullscreen Spaces are skipped; each display always keeps at least one Space.
