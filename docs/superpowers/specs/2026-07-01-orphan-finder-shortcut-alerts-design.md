# Orphan Finder (2.1) — Shortcut Button & Clickable Alerts

**Date:** 2026-07-01
**Mod:** `orphan-finder-v21` (Factorio 2.1 port of GotLag's Orphan Finder)
**Status:** Implemented in v1.3.0

## Goal

Add two quality-of-life features to the mod, without changing its core orphan-detection behavior:

1. A **shortcut-bar (toolbar) button** that does the same thing as the existing `Shift+O` keybind.
2. **Clickable alerts** integrated with Factorio's alert list, so each detected orphan can be clicked to focus the camera on the problematic belt/pipe. The existing in-world orange arrows are kept as the visual highlight.

## Background

Current behavior (v1.2.3): pressing `Shift+O` (`find-orphans` custom-input) toggles orphan detection. If the player has no active markers, it searches within a configurable radius for orphaned underground belts/pipes and places an orange `arrow`-type marker on each, then prints a chat summary ("Found N orphans"). If markers already exist, pressing again clears them. Markers are also removed individually as orphans get resolved (built/rotated neighbour, mined, died) and cleared on player-left / surface-change.

`arrow`-type entities are **not selectable**, so they cannot be clicked in-world. Factorio's `LuaPlayer.add_custom_alert(entity, icon, message, show_on_map)` is the idiomatic mechanism for clickable, camera-focusing alert-list entries — this is what feature #2 uses.

## Approach

Minimal, focused integration in the existing single-file structure (no new Lua modules — the mod is ~250 lines and splitting would spread trivial logic):

- Refactor the body of the `find-orphans` keybind handler into a shared local function `toggle_orphans(player)`. The keybind handler and the new shortcut handler both call it, guaranteeing identical behavior.
- Add a toggle `shortcut` prototype in `data.lua`, linked to the `find-orphans` custom-input so its tooltip shows `Shift+O`.
- Extend `create_arrow` / `delete_arrow` / `clear_arrows` to also add/remove a custom alert per marker, so alerts share the arrows' exact lifecycle and cleanup paths.

## Core invariant

**The shortcut button is toggled ON for a player iff that player currently has ≥1 active orphan marker; OFF otherwise.**

This single rule delivers all requested toggle behavior:
- Search finds ≥1 orphan → ON.
- Search finds 0 orphans → stays OFF.
- Toggle-clear (button or keybind) → OFF.
- Orphans resolved one-by-one until the last marker is removed → flips OFF automatically.
- Keybind and button both run `toggle_orphans` → always in sync.

## Feature 1 — Shortcut button

**Prototype (`data.lua`):**
```
{
  type = "shortcut",
  name = "orphan-finder-toggle",
  action = "lua",
  toggleable = true,
  associated_control_input = "find-orphans",   -- shows Shift+O in tooltip
  icon = { filename = "__base__/graphics/icons/pipe-to-ground.png", size = 64, ... },
  -- small_icon / disabled variants reuse the same base icon
}
```
Base-game `pipe-to-ground` icon is used (on-theme: "find orphaned undergrounds"). If 2.1 requires distinct `small_icon`/`icon_size` fields, they reuse the same source.

**Control (`control.lua`):**
- `script.on_event(defines.events.on_lua_shortcut, ...)`: if `event.prototype_name == "orphan-finder-toggle"`, call `toggle_orphans(game.get_player(event.player_index))`.
- `toggle_orphans(player)` ends by syncing state: `player.set_shortcut_toggled("orphan-finder-toggle", has_markers(player))`, where `has_markers` checks whether `storage.arrows[player.index]` is non-empty.
- `delete_arrow` returns/knows the owning player index; after removing a marker, if that player's marker set is now empty, call `set_shortcut_toggled(..., false)` for them. (Individual removals happen for a specific entity; we resolve the owning player from the same loop that finds the marker.)

## Feature 2 — Clickable alerts

- `create_arrow(entity, player_index)`: after creating the arrow, also
  `game.get_player(player_index).add_custom_alert(entity, alert_icon(entity), {"orphans.alert-text"}, true)`.
  `show_on_map = true` so it also pings the map view.
- `alert_icon(entity)`: returns a `SignalID` matching the orphan type — `{type="item", name="pipe-to-ground"}` for `pipe-to-ground`, `{type="item", name="underground-belt"}` for `underground-belt`. If the entity's matching item does not exist (modded entity), fall back to a fixed base signal (e.g. `{type="virtual", name="signal-info"}`), guarded so a missing prototype never errors.
- Alert removal: wherever a marker is destroyed (`delete_arrow`, `clear_arrows`), also call `player.remove_alert{entity = ...}` (or `remove_alert` with matching parameters) for the owning player. Because all removal paths (toggle-clear, mined, robot-mined, rotated-resolved, built-resolved, died, player-left, surface-change) already funnel through `delete_arrow`/`clear_arrows`, alerts inherit complete cleanup automatically.
- The existing chat summary ("Found N orphans" / "no orphans" / "markers cleared") is retained.

**New locale strings** (`locale/en/locale.cfg`): `[orphans] alert-text=...`, and a `[shortcut-name] orphan-finder-toggle=...` (and/or tooltip) for the button.

## Known risk (verify in 2.1 beta)

Custom-alert persistence semantics are undocumented for the 2.1 closed beta. Design assumes an added custom alert persists until the entity is invalidated or `remove_alert` is called (matching arrow lifecycle). **If in-game testing shows alerts expire on their own,** the fallback is a lightweight `script.on_nth_tick` handler that re-adds alerts for all active markers while any exist, and unregisters itself when none remain. This is an additive fallback and does not change the design's structure.

## Out of scope / YAGNI

- No new module files.
- No change to detection logic, settings, or the arrow visuals.
- No per-orphan alert customization beyond belt-vs-pipe icon.
- No configuration toggle for enabling/disabling the button or alerts (can be added later if requested).

## Packaging

- Add `docs` to `.makeignore` so this spec (and the `docs/` tree) is never packaged into the distributed mod zip.

## Testing / verification

- `luac -p` syntax check on `data.lua` and `control.lua`.
- Local `.makeignore` build dry-run confirms `docs/` is excluded and the shipped file set is unchanged apart from mod content.
- In-game (user, 2.1 beta): place orphaned undergrounds; verify (a) the toolbar button toggles them on/off, (b) button syncs with `Shift+O`, (c) button turns off when a search finds none and when the last orphan is resolved, (d) alerts appear in the alert list and clicking one focuses the camera, (e) alerts clear alongside arrows.
