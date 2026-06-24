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

The app lives in the menu bar and shows the focused task name there. Use the popover to add tasks, drag current-iteration tasks to reorder them, focus a task from the right-click menu, choose whether tasks repeat every 1, 2, 3, or 4 iterations, mark tasks done for the current iteration, automatically advance when every current task is done, optionally open a linked app whenever a task becomes focused, link a task with quick app buttons or a custom macOS app, review statistics, and customize the global shortcut.
