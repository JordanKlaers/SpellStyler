# Container System Overview

## What a Container Is

A container is a movable frame that groups one or more tracked spell icons together. When icons are assigned to a container, they lose their individual drag freedom and instead travel with the container as a unit. When the container is hidden (settings closed), it becomes fully transparent and non-interactive, so it has no in-game presence outside of edit mode.

---

## Data Storage

Containers are persisted inside `SpellStyler_CharDB`, scoped per character **and** per specialization:

```
SpellStyler_CharDB
  └── classSpecializations
        └── [specID]
              └── containers
                    └── [containerName]  →  { name, associatedIcons = { uid, uid, ... } }
```

`associatedIcons` is an ordered list of `uniqueID` strings — the same IDs used by `FrameTrackerManager` to identify individual spell tracker frames. Order matters because it controls left-to-right layout position.

`Containers:GetDB()` is the single access point for this table; it handles nil-safety and spec resolution automatically.

---

## Runtime State (module-local)

Two module-local variables track live state that does **not** need to be saved:

- **`activeName`** — the name string of the currently selected container in the settings UI. Only one container can be "active" at a time. Changed by `SetActiveName`, read by `GetActiveName`, `GetActiveConfig`, and `GetActiveFrame`.
- **`containerFrames`** — a table of `[name] = Frame`, holding the actual WoW frame objects for each container. Populated when containers are created or loaded. Frames are keyed by the same name string used in the DB.

---

## Lifecycle of a Container

### Adding
`Containers:Add()` generates a unique name ("Container 1", "Container 2", etc.), writes a fresh config into the DB, creates a live frame via `CreateContainer`, makes it the active container, and immediately calls `SetEditMode(true)` so it becomes visible.

### Deleting
`Containers:Delete(name)` reads the config **before** wiping it, hides and removes the live frame, removes the DB entry, calls `DetachIconsFromContainer` on all associated icons to release them back to free dragging, then advances `activeName` to whatever `next(containers)` returns (or `nil` if empty).

---

## Icon Association

### Attaching an icon
The settings UI adds the icon's `uniqueID` to `config.associatedIcons`, then calls `LayoutContainer` to physically reposition and lock the frame. `LayoutContainer` also sets `frame._inContainer = true` on the tracker frame and strips its drag scripts so it can't be moved independently.

### Detaching icons — `DetachIconsFromContainer(uniqueIDs)`
Accepts a list of `uniqueID` strings. For each one it finds the corresponding tracker frame across all tracker types (`buffs`, `essential`, `utility`), clears `_inContainer`, calls `UpdateFrame_ConfigurationChanges` to restore its visual state, then calls `EnableDraggingForAllFrames` once at the end so all now-free icons regain drag scripts. Called both on individual removal (the settings UI drag/click) and when an entire container is deleted.

---

## Layout — `LayoutContainer(name)`

Positions every icon assigned to the named container in a horizontal row left-to-right, anchored to the container frame's `TOPLEFT`. Each icon is offset by `(index - 1) * (iconWidth + 4)` pixels. If the container frame doesn't exist yet (e.g. after a reload), it is created here. It also strips each icon's drag capability (`EnableMouse(false)`, `RegisterForDrag()`, nil drag scripts) and flags `_inContainer = true`. Called whenever icons are added, removed, or the container frame is dragged to a new position.

---

## Edit Mode — `SetEditMode(enabled)`

Called by `NewSettings` when the settings menu opens (`true`) or closes (`false`). Iterates every live container frame and either reveals it (`SetAlpha(1)`, `EnableMouse(true)`) or hides it (`SetAlpha(0)`, `EnableMouse(false)`). Containers use `OnMouseDown`/`OnMouseUp` rather than `OnDragStart`/`OnDragStop` to avoid WoW's built-in drag deadzone.

---

## Settings UI — `ContainerSettings.lua`

Renders inside the "Containers" tab of the main settings menu. Key pieces:

- **Dropdown** — lists all container names for the current spec. Selecting one sets the active container and refreshes the icon lists.
- **Add / Delete buttons** — call `Containers:Add()` / `Containers:Delete()` and refresh the dropdown.
- **"All Tracked Icons" row** — horizontal scrolling list of every tracked icon. Icons already in the active container are dimmed. Clicking or dragging an icon onto the "Container Icons" row adds it.
- **"Container Icons" row** — horizontal scrolling list of icons currently in the active container. Clicking or dragging an icon onto the "All Tracked Icons" row removes it via `DetachIconsFromContainer`.
- **Ghost drag** — a cursor-following icon preview is shown during drags. Drop targets highlight when the cursor is over them. A small pixel threshold distinguishes a click from a drag, so both interactions trigger the same add/remove action.

---

## How Dragging and `_inContainer` Interact with FrameTrackerManager

`EnableDraggingForAllFrames` in `FrameTrackerManager` skips any frame where `frame._inContainer == true`, so container-locked icons are never given drag scripts. `DetachIconsFromContainer` clears that flag before calling `EnableDraggingForAllFrames`, ensuring the newly freed icons are included in the next pass.
