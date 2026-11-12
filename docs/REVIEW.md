# Performance and security review (v0.2, after adding MCP)

Scope: the whole codebase, focusing on what's new with MCP: the local socket, the
`draw4me-mcp` relay, the tool surface, and everything an agent can reach through them
(command layer, document loading, rendering, file paths).

How to reproduce the numbers: `swift build -c release && .build/release/draw4me-cli --bench 100`
(100 houses + dining sets = 2,400 objects, Apple Silicon, release build).

## Performance

| # | Finding | Severity | Fix | Status |
|---|---|---|---|---|
| P1 | Every lookup by id (`object`, `index`, `contains`, `hosted`, `children`) scanned the whole object list. Wall geometry looks up its doors/windows, so warnings, 3D, 2D and summaries were O(walls × objects). | High | `SceneDocument` keeps lazily built id/host/parent indexes, invalidated whenever `objects` changes (`LookupBox` in `Model.swift`). Not part of equality or JSON. | Fixed |
| P2 | Undo history stored two full document snapshots per step: about 1.3 MB per step at 2,400 objects, up to about 400 MB at the 300-step cap. | High | `HistoryEntry` stores per-object deltas (`ObjectDelta`) plus name and id counters. Revert no longer patches later snapshots. | Fixed |
| P3 | The app rebuilt every SceneKit node on every change (63 ms at 2,400 objects, worse on big edits). | High | `SceneBuilder.update` rebuilds only changed objects and their dependents: a wall when its openings change, openings when their wall changes, and highlight changes. The viewport uses it after the first build. | Fixed |
| P4 | Each change recomputed warnings from scratch, including geometry for every object. | Medium | `Validator.BoundsCache` keyed by object value, owned by the editor. A grid broad phase was already in place. | Fixed |
| P5 | `ChangeSet` and group expansion used array `contains`, which is O(n²). A 100-copy `array` of a house took about 8 s (debug). | High (DoS-able) | Set-backed membership. `array` makes all copies in one pass and checks the object limit **before** doing the work. | Fixed |
| P6 | Wall junctions in the scene summary compared every pair of walls. | Medium | 2 m grid buckets; only nearby walls are compared. | Fixed |
| P7 | Result messages listed every created id (1,600 ids for one `array`), flooding the model's context. | Medium | Lists are capped ("… (+N more)"). Full lists stay in the structured result. | Fixed |
| P8 | `get_scene` of a large design is long (370k characters at 2,400 objects). | Medium | The MCP output is capped at 60k characters with a note, and `get_scene` takes `ids` to describe part of a design. | Mitigated |
| P9 | The 2D plan redraws the whole drawing on each change (about 120 ms at 2,400 objects, PNG at 2×). | Low | Fine for normal house-sized designs. Incremental drafting is future work. | Open |

### Before / after (2,400 objects, release)

| Measurement | Before | After |
|---|---|---|
| Apply one small edit (incl. warnings) | 16.4 ms | 6.6 ms |
| 50 small edits | 774 ms (15.5 ms each) | 357 ms (7.1 ms each) |
| Undo / redo | 0.0 ms (snapshot swap) | 0.3 / 0.2 ms (replay deltas) |
| Undo history for 154 steps | ~195 MB resident | ≈ 860 KB of deltas; +0 MB over 50 edits |
| 3D update after moving one object (app) | 104 ms (full rebuild) | 1.4 ms (1 node) |
| Full 3D rebuild | 104 ms | 63 ms |
| Warnings, whole document (uncached) | 15.8 ms | 13.0 ms |
| Scene summary text | 137 ms | 62 ms |
| Geometry for every object | 17 ms | 10 ms |
| 2D plan PNG 1600×1100 | 148 ms | 120 ms |
| 3D render PNG 1024×768 | 417 ms | 329 ms |
| `array` of 100 houses (1,600 objects) | ~8 s (debug) | 0.05 s (release, CLI end to end) |

## Security

Threat model: the app and relay run as the user. The things to defend against are other local
users or processes, malformed or hostile input (files, socket frames, agent tool calls), prompt
injection through design content, and an agent writing files where it shouldn't. There is no
network listener.

| # | Finding | Severity | Fix | Status |
|---|---|---|---|---|
| S1 | **Socket access.** | High (by design) | Unix socket only, no TCP. The folder `~/Library/Application Support/Draw4Me` is 0700 and checked to be ours and not a symlink; the socket is created with umask 0177 then chmod 0600; every connection is checked with `getpeereid` (same uid); at most 8 connections; idle timeout. A second instance can't take over a live socket. The client refuses to connect to anything that isn't a socket owned by the user. | In place, tested |
| S2 | **Unbounded input** on the socket and stdio. | Medium | Frames capped at 4 MB (socket) and 8 MB (MCP), with oversize answered by an error rather than a crash; batches capped at 500 commands, counting nested `transaction`s, which can nest at most 8 deep. | Fixed, tested |
| S3 | **Unbounded documents.** One `array`/`duplicate` could create hundreds of thousands of objects, and positions could be pushed to ±1e300. | High (DoS) | After every command: object count ≤ 20,000 and coordinates within ±100 km, or the whole change is rejected. `array` pre-checks. | Fixed, tested |
| S4 | **Documents from disk weren't validated.** `SceneDocument.load` only decoded, so a crafted file could have dangling host/parent ids, bad ids, invalid parameters or group cycles, which force-unwraps in the engine assume can't happen. | High (crash) | `load` enforces a 50 MB cap and `DocumentLimits.check`: valid unique ids, names ≤ 200, finite in-range positions, parameters valid for the kind, hosts are walls, parents are groups, no cycles. This applies to the app's Open, the headless relay and `--doc`. | Fixed, tested |
| S5 | **Render memory.** 4096×4096 requests, and 2D drawings render at 2×, could allocate about 270 MB per request. | Medium | Area capped at ~11.9 MP with the aspect ratio kept; 2D drops to 1× for large requests. MCP `render_view` caps at 2048 px. | Fixed, tested |
| S6 | **Prompt injection via names.** Names could contain newlines and quotes, letting a name forge extra "object lines" in the scene text the agent reads. | Medium | Control characters are stripped from names on input, names are capped at 200 characters, and summary text quotes names with `"` → `'`. Scene output tells the model names are user data, and the skill says the same. | Fixed, tested |
| S7 | **Agent file access.** | High (by design) | `PathPolicy`: the path must resolve (after `~`, `..` and folder symlinks) inside the home folder; no hidden components; no `~/Library` except draw4me's folder; extension must match; no overwrite without `overwrite: true`; never writes through a symlink. Atomic writes replace rather than follow links. Open/save are only available headless; with the app running, the person uses the app's own Open/Save. | In place, tested |
| S8 | **Headless file handling.** The auto-saved file was world-readable (0644), and an unreadable file would have been silently replaced by an empty design. | Medium | Auto-saved files are 0600; an unreadable file is moved aside (`*.unreadable-<time>.draw4me`) before starting fresh. | Fixed |
| S9 | **Unbounded `ref` aliases.** | Low | Refs are limited to 1–64 characters with no control characters. | Fixed, tested |
| S10 | **Destructive operations by an agent.** | Medium (by design) | `apply_commands`, `undo_agent_changes` and `open_document` are annotated `destructiveHint`, so the harness can ask first. Every agent change is one undo step, tinted in the app, and revertable (`revertLast` refuses on conflicts). Agent connections can be switched off in Developer ▸ Allow Agent Connections. | In place |
| S11 | **Dependencies.** | — | None. The MCP layer is hand-written (no Swift MCP SDK), so there's no third-party code to pin or audit. Only Apple frameworks are used. | — |
| S12 | **Crash safety.** | Medium | Remaining force-unwraps in the engine follow successful `resolve` lookups. With S4, documents can no longer violate those invariants. Malformed JSON, unknown commands and fields, wrong types and stale revisions all return typed errors. | Reviewed |
| S13 | **TOCTOU on paths.** A symlink could be swapped in between the path check and the write. | Low | Writes are atomic (temp file + rename, which replaces a link rather than following it), and the target folder must already exist inside the home folder. Accepted as low risk for a single-user desktop tool. | Accepted |
| S14 | **Project `.mcp.json` runs a local binary.** | Low | Standard for Claude Code project servers; Claude Code asks before enabling project servers. The binary is built from this repo; nothing is downloaded. | Accepted |

## Not covered

- No fuzzing beyond the malformed-input tests; a JSON fuzzer over `AutomationEndpoint.handle` and
  `MCPServer.handle` would be a good next step.
- The `.mcp.json` / plugin wiring couldn't be health-checked with `claude mcp list` on the
  machine where this was written (its CLI install was broken). The server itself was exercised
  end to end over stdio, against both the live app and headless mode.
- Performance was measured on one machine; the numbers are indicative.
