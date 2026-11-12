# AI integration: how Claude drives draw4me

**Status (v0.2):** implemented as an extension of the agent harness. You chat with Claude in
Claude Code or the Claude desktop app; Claude drives draw4me through an MCP server. There is **no
API key**, no network listener, and no AI code inside the app itself — the app is the tool and
the live view, and the harness provides the conversation, memory, permissions, skills and
subagents.

```
Claude Code / Claude desktop ──stdio (JSON-RPC)──▶ draw4me-mcp ──Unix socket (same user only)──▶ Draw4Me.app
                                                       │                                           │
                                                       └── headless fallback ──▶ Draw4MeCore/Render ┘ (same code)
```

## 1. Pieces

| Piece | Where | What it does |
|---|---|---|
| **Typed commands** | `Draw4MeCore/Commands.swift` | Every edit is a Codable `Command` (`{"command":"add",…}`), from clicks, the console, the CLI or Claude. Claude gets no special path or powers. |
| **Single editor** | `Draw4MeCore/Editor.swift`, `Engine.swift` | Validates everything, applies batches atomically (one undo step), returns created/changed/deleted ids, the new **revision**, and **warnings** about the touched objects. |
| **Revisions** | `SceneDocument.revision` | Bumped by every apply/undo/redo/revert, never backwards. `expectedRevision` makes a change fail with `staleRevision` if the person edited meanwhile — Claude re-reads instead of overwriting their work. |
| **Warnings** | `Draw4MeCore/Validation.swift` | Intersections, floating objects, objects sunk into floors, implausible sizes. Returned with each change so Claude can fix its own mistakes in the same turn. |
| **Origin-tagged history + revert** | `HistoryEntry.origin`, `DocumentEditor.revertLast(from:)` | Reverts Claude's latest change even if the person edited other things since; refuses with `conflict` if later edits touched or depend on the same objects. |
| **Relational helpers** | `addRoom`, hosted doors/windows, `ref`/`@ref` | "The app owns geometry, the model owns intent": rooms come out with clean corners, openings move with their walls, and one call can build a room and put a door in `@k.south`. |
| **Catalog** | `Draw4MeCore/Catalog.swift` | Machine-readable description of every command and kind, with units, ranges, examples and `destructive` flags. Claude reads it via `get_catalog`. |
| **Scene summary** | `Draw4MeCore/Summary.swift` | Compact deterministic text of the scene, with ids, dimensions and wall junctions. |
| **Headless render** | `Draw4MeRender/Renderer.swift` | PNG of perspective / top / plan / front / side views — how Claude *sees* the design. |
| **AutomationService + endpoint** | `Draw4MeAutomation/Automation.swift` | `apply`, `summary`, `catalog`, `render`, `undo`/`redo`/`revert`, `history`, `selection`, `warnings`, `status`. Every transport goes through `AutomationEndpoint.handle`. |
| **Local socket** | `Draw4MeAutomation/LocalSocket.swift` | App side `LocalSocketServer`, relay side `LocalSocketClient`. Newline-delimited JSON. |
| **App integration** | `Sources/Draw4Me/AppAutomation.swift`, `AppModel.swift` | Shares the person's selection, tints agent changes green, "Revert Agent Change", warnings popover, **Developer ▸ Allow Agent Connections**. |
| **MCP server** | `Sources/Draw4MeMCP`, `Sources/draw4me-mcp` | Hand-written MCP (JSON-RPC 2.0 over stdio; protocol 2025-06-18, 2025-03-26, 2024-11-05). No third-party dependencies. |
| **Plugin** | `plugin/` + `.claude-plugin/marketplace.json` | MCP server + `designing-with-draw4me` skill + `/draw4me:new-house`, `/draw4me:furnish-room` + `layout-critic` agent. |

## 2. Tools

| Tool | Read-only | Notes |
|---|---|---|
| `get_status` | ✓ | App (live) or headless, revision, counts |
| `get_scene` | ✓ | Text (default) or JSON; names are flagged as user data |
| `get_selection` | ✓ | What the person selected — "make this taller" |
| `get_catalog` | ✓ | Commands and kinds |
| `get_warnings` | ✓ | Whole-document warnings |
| `render_view` | ✓ | Returns an MCP image |
| `apply_commands` | | Atomic batch, `expected_revision`, `label`; annotated destructive (it can delete) |
| `add_room`, `add_opening`, `add_furniture` | | Common builders |
| `undo_agent_changes` | | Revert Claude's latest change |
| `export_image` | | PNG into the home folder |
| `open_document`, `save_document` | | Headless only; with the app open, the person opens/saves |

## 3. Safety

- **Same user only.** The socket is in `~/Library/Application Support/Draw4Me/` (mode 0700),
  the socket is 0600, and the app checks every peer with `getpeereid`. No TCP. A second instance
  can't hijack the path, and the relay refuses to connect to anything that isn't a socket owned
  by you.
- **Bounded input.** Size caps on JSON-RPC messages, socket frames, command batches, render sizes
  and documents; all input goes through the same validation as UI edits.
- **Files.** Agent-supplied paths must resolve inside your home folder, no hidden folders, nothing
  in `~/Library` except draw4me's folder, matching extension, no overwrite without the flag, no
  writing through symlinks.
- **Reversible.** Agent changes are one undo step each, visible in green, and revertable.
- **Prompt injection.** Object names are user data; scene text says so, and the skill tells Claude
  to treat them that way.


See [REVIEW.md](REVIEW.md) for the performance and security review.

## 4. Later

- **In-app chat** can reuse the same MCP server by running `claude -p --mcp-config …`.
- **Preview before apply**: `DocumentEditor.dryRun` already exists; a "propose" tool could show
  a ghosted preview the person accepts.
- **More relational commands**: stairs, L-shaped rooms, "place against wall W3", snapping.
