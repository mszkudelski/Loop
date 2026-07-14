# Loop

Loop is a lightweight macOS menu-bar app for working through recurring focus loops.

## Build

```sh
swift build
```

To build a local app bundle:

```sh
scripts/build-app.sh
open dist/Loop.app
```

The app lives in the menu bar and shows the focused task name there. Its compact tray popover keeps the current status and quick actions close at hand, while the separate Loop window handles task planning and management. Use that window to add and reorder tasks, focus work, configure recurrence and linked apps, review statistics, and customize shortcuts.
