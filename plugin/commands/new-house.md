---
description: Design a new house in draw4me from a short brief
argument-hint: [brief, e.g. "2 bed, 9x7 m, open kitchen"]
---

Design a house in draw4me from this brief: $ARGUMENTS

Use the designing-with-draw4me skill. Start with get_status and get_scene. If the design isn't empty,
ask whether to start fresh (loadTemplate/newDocument replace the current design) or build next to it.
Lay out rooms with add_room (shared walls can be avoided by placing rooms side by side and deleting a
duplicate wall, or by adding interior walls with apply_commands), then doors, windows and a roof.
Check the warnings, render the plan and a perspective view, and summarise the layout with room sizes.
