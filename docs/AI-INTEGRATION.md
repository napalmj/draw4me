# AI integration: what's in place, and what to decide

**Status:** v0.1 contains **no AI integration on purpose**: no API keys, no Claude API calls, no MCP
server, no sockets or local listeners, and no `claude` CLI spawning. What it does have is the
scaffolding, built so that whichever option you pick plugs in with little rework. Agent edits
will travel **exactly the same path** as your own edits.

## 1. Seams built in this version

| Seam | Where | Why it matters for AI |
|---|---|---|
| **Typed commands** | `Draw4MeCore/Commands.swift` | Every edit (UI, console, CLI) is a Codable `Command` in JSON form, `{"command":"add",…}`. An agent's tool call *is* a command, so it gets no special powers and no separate code path. |
| **Single editor with validation** | `Draw4MeCore/Editor.swift`, `Engine.swift` | `DocumentEditor.apply` validates everything: ranges, units, door/window fit, ids, unknown fields. It returns a structured `CommandResult` with created, changed and deleted ids, or a typed error with a readable message the model can act on ("offset must be between 0.45 and 7.75"). Batches are atomic. |
| **Origin-tagged history** | `HistoryEntry.origin` (`user`, `script`, `agent`) | One agent turn becomes one undoable transaction. "Undo what the agent did" is `undoLast(from: .agent)`, and the UI could highlight `changes` from the last agent step. |
| **Batch refs** | `"ref": "s"` … `"host": "@s"` | A model can build a wall and put a door in it within one call, without knowing ids in advance. |
| **Command catalog** | `Draw4MeCore/Catalog.swift` | A JSON-Schema-like description of every command and object kind, with units, ranges, defaults and examples. It's generated from the same table the decoder enforces, and tests check that every command is covered. MCP tool definitions or an API `tools` array can be generated from `CommandCatalog.json()`. |
| **Scene summary** | `Draw4MeCore/Summary.swift` | A compact, deterministic text (or JSON) description of the scene: objects, key dimensions and relationships ("D1 (door) is in wall W1 at 4.1 m…", "wall W1 meets wall W2…"). It's cheap context for every turn. |
| **Headless render** | `Draw4MeRender/Renderer.swift` | `Renderer.png(document, request)` produces perspective, top, plan, front or side views as PNG, with no window. This is how a model would *see* the design and check its own work. |
| **AutomationService + endpoint** | `Draw4MeAutomation/Automation.swift` | A protocol with `apply`, `sceneSummary`, `catalogJSON`, `render`, `undo`/`redo`/`history` and `document`. `AutomationEndpoint.handle(json:)` takes request bytes and returns response bytes. The Command Console and `draw4me-cli --request` already use it. **Any transport plugs in here** (see the marked comment block). |

You can try the whole loop today without any AI. Open the Command Console, set Origin to
`agent`, paste a batch and apply it. Then click Render, and use "Undo Last Agent Change".

## 2. Options

### A. MCP server + local bridge, using your existing Claude chat (leading idea)
You keep chatting in Claude Code or the Claude desktop app. A small `draw4me-mcp` executable
(stdio MCP server) is registered with Claude. Its tools (`apply_commands`, `get_summary`,
`get_catalog`, `render_view`, `undo_agent_change`) forward each call to the **running app** over
a local bridge, most likely a Unix domain socket in `~/Library/Application Support/draw4me/`
that the app listens on. The app runs `AutomationEndpoint.handle` on the main thread and
replies. `render_view` returns the PNG as an MCP image, so Claude actually sees the result.

- **Effort:** medium.
  - The MCP stdio server is about 300–500 lines: tool schemas generated from the catalog, plus
    JSON-RPC.
  - The socket listener in the app is about 150 lines.
  - There's also a reconnect story: what happens if the app isn't running? Possibly fall back
    to editing a file.
- **User experience:** best. You're talking where you already talk, and you watch the app
  update live. Hand tweaks and agent edits interleave, with undo per agent step.
- **Sees renders:** yes, via MCP image content.
- **Cost and auth:** no API key, because it uses your Claude subscription through Claude Code or
  the desktop app.
- **Risks:**
  - A local socket is an attack surface, so restrict it to the user, use a file-mode 0600
    socket, and maybe a token in the socket dir.
  - MCP client differences between Claude Code and the desktop app.
  - Two processes to keep in sync.
  - Chat history lives outside the app.

### B. File-based live reload
Claude (in Claude Code) edits the `.draw4me` JSON, or a `commands.jsonl` inbox file, and the app
watches the file and reloads or applies it. The CLI can already render PNGs for Claude to read.

- **Effort:** low. Add a file watcher, then reload, or apply the new lines as commands with
  origin `agent`.
- **User experience:** OK. You have to name the file in chat. Editing the whole document risks
  clobbering in-app changes unless Claude writes *commands* (the inbox) rather than the document.
- **Sees renders:** indirectly. Claude runs `draw4me-cli --render` and reads the PNG, but that's
  a render of the file, not of the live app state.
- **Cost and auth:** no API key.
- **Risks:**
  - Race conditions between app saves and agent writes.
  - No structured result or error unless an outbox file is added.
  - It's easy for the model to write invalid JSON straight into the document.

### C. In-app chat that shells out to the `claude` CLI
A chat panel inside draw4me runs `claude -p` (headless Claude Code), with the MCP server from
option A configured, or with instructions to emit commands.

- **Effort:** medium-high.
  - A chat UI, plus process management and streaming.
  - Session continuity (`--resume`), and parsing output.
  - You still need A's tool surface for good results.
- **User experience:** very integrated, because everything is in one window.
- **Sees renders:** yes, if wired through MCP tools.
- **Cost and auth:** no API key, but it requires Claude Code to be installed and logged in.
  Usage counts against your subscription.
- **Risks:**
  - It depends on CLI flags and output formats that can change.
  - Process sandboxing and permissions.
  - You're effectively rebuilding a chat client.

### D. Direct Claude API with an API key
The app calls the Messages API with tool use. Tools are generated from the catalog, and render
results are sent back as images.

- **Effort:** medium. An HTTP client, a tool loop, a chat UI and key storage in the Keychain.
- **User experience:** fully integrated and works offline from Claude Code, but it's a separate
  chat from your normal one.
- **Sees renders:** yes, as image blocks.
- **Cost and auth:** pay-per-token API billing, and the user has to create and manage a key.
- **Risks:**
  - Key handling.
  - Cost surprises with images.
  - Shipping API logic inside the app.

### Comparison

| | A. MCP bridge | B. File reload | C. In-app `claude` CLI | D. API key |
|---|---|---|---|---|
| Effort | Medium | **Low** | Medium-high | Medium |
| UX | **Best** (live, your usual chat) | OK | Very integrated | Integrated |
| Claude sees renders | **Yes** | Indirectly | Yes (via A's tools) | Yes |
| Cost / auth | Subscription, no key | Subscription, no key | Subscription, CLI login | API key, metered |
| Main risks | Local socket, 2 processes | Races, no feedback | CLI churn, chat UI | Keys, cost |
| Reuses current seams | Fully | Mostly | Fully (plus A) | Fully |

## 3. Recommendation

**Go with A (MCP server + local bridge)**, and use **B's command inbox** as both a stepping stone
and a fallback.

1. **Step 1:** add the MCP server as a new executable target. It speaks `AutomationRequest`
   JSON, and its tool list is generated from `CommandCatalog.json()`.
2. **Step 2:** add the app-side listener, a Unix socket that calls `AutomationEndpoint.handle`
   on the main actor. If the app isn't running, the MCP server can fall back to applying
   commands to a file headlessly, using the same code as `draw4me-cli`.
3. **Step 3:** in the app, show the last agent transaction: highlight what changed, and offer a
   one-click undo.

C and D can come later. Both reuse the same tool surface, so A isn't wasted work.

## 4. Open questions for you

1. **Where do you want to chat?** In Claude Code or the desktop app (A/B), or inside draw4me
   (C/D)?
2. **Should the agent work on the live app only, or also on closed files?** This decides whether
   there's a headless fallback.
3. **Approve or auto-apply?** Should agent batches apply immediately (and be undoable), or be
   shown as a preview first (`editor.dryRun` already exists) and applied on your click?
4. **How much should the agent see by default?** Should the summary and a render be included
   after every change, which is better quality but costs more tokens, or only on request?
5. **Is a local socket acceptable?** A local socket in your user's Application Support folder,
   permissions 0600, with no network. Or would you prefer file-only (B)?
6. **Should higher-level "intent" commands come first?** For example "make a room 4×6 m with a
   door on the south wall" as a single command (`addRoom`), versus letting the model compose
   walls and doors. Adding a few such macro commands would make the AI noticeably better.
