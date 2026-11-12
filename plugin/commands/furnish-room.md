---
description: Furnish a room in draw4me (uses the selection if nothing is named)
argument-hint: [room or purpose, e.g. "the kitchen as a dining room for 6"]
---

Furnish a room in draw4me: $ARGUMENTS

Use the designing-with-draw4me skill. Find the room from get_scene (or get_selection if the person
didn't name one). Keep walkways of at least 0.9 m and don't block doors (check each door's swing
side). Add the furniture in one apply_commands call with expected_revision, fix any warnings, then
render the plan view and check it. Summarise what you placed and why.
