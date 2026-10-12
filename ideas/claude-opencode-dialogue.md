# Claude ↔ OpenCode dialogue

Investigation (Oct 2026) into whether Claude Code and OpenCode can talk to
each other, and what it would take to wire that into this Neovim setup.
Explore-only: no implementation yet.

## How Claude talks to Claude today

All native mechanisms are same-vendor (workers are always Claude sessions):

- **Subagents** via the Agent/Task tool: parent delegates a side task, the
  child works in its own context and returns a summary.
- **Agent teams** (experimental): a lead plans and supervises teammates with
  a shared task list and a `SendMessage` tool.
- **Cross-session messaging**: sessions you run yourself can pass findings
  and status between each other, on this machine or remote.
- Under the hood: a **mailbox system** (async message passing, filesystem
  backed for tmux teammates) plus agent view / dynamic workflows for
  dispatching and monitoring.

The docs state the boundary explicitly: *"In every approach the workers are
Claude sessions. To involve a different tool, expose it to Claude as an MCP
server."*

## Bridges that already exist (one-directional per call)

| Direction       | Tool                  | Mechanism                                                        |
|-----------------|-----------------------|------------------------------------------------------------------|
| Claude → OpenCode | `opencode-plugin-cc`  | Claude Code plugin: `/opencode:review`, `/opencode:rescue` (write access), `/opencode:transfer` (one-way handoff). Premise: a model reviewing its own code agrees with itself. |
| Claude → OpenCode | `opencode-bridge`     | MCP server on a local `opencode serve`: `delegate_task`, `continue_task`, `task_progress`, `abort_task`. Claude spends tokens on planning, OpenCode's model on implementation. |
| Any → Any       | `crossagent`          | CLI second-opinion protocol: package a decision, a peer agent critiques it (Position / Evidence / Risks / Recommendation), named resumable sessions, durable background jobs, web dashboard. |
| OpenCode → Claude | `opencode-claude-acp` | Fills a real gap: opencode is an ACP *server* but not an ACP *client*, so this CLI + skill spawns `claude-agent-acp` with named resumable sessions. |

The closest thing to a shared language is **ACP** (Agent Client Protocol,
JSON-RPC over stdio): `opencode acp` serves it and `claude-agent-acp`
serves it — but nothing speaks both sides out of the box except the tools
above.

## True dialogue (A ↔ B ↔ A loops)?

Nothing off-the-shelf. The workable pattern is "dumb orchestrator + smart
workers": a script (or hook) relays transcripts between CLIs, since both
`opencode run` and `claude -p` do one-shot prompt → answer, which is all a
relay needs. Variants:

- **Claude Code hooks** (e.g. `Stop`): shell out to `opencode run` for a
  second opinion after every task.
- **Loop script**: alternate the two agents with the full transcript plus a
  max-rounds stop condition.

Known costs of this pattern:

- 2× token spend (every round runs two models).
- Context divergence: neither agent sees the other's full history unless
  the relay includes it.
- Prompt-injection surface: one agent's output becomes another's input.
  (Claude's own subagent pipeline runs a safety classifier on handoffs for
  exactly this reason.)
- Runaway loops without a round cap and stop condition.

## Why our setup is a head start

- Both agents already run in **addressable tmux sessions** (`nvim-claude` /
  `nvim-opencode` sockets, per-directory session names): a relay could
  `capture-pane` one and `send-keys` to the other.
- `agent-review`'s `backends` table already abstracts `ask()` per agent, so
  a "discuss" loop (Claude proposes → OpenCode critiques → Claude revises,
  N rounds) is a natural extension, reusing the same session discovery and
  JSON parsing, with the review panel as the transcript viewer.

## Open question

Which shape first?

- (a) **Second-opinion-on-demand** (like `/opencode:review`: one call,
  human reconciles) — closest to what exists.
- (b) **Automated debate loop** with a round cap.
- (c) **Handoff** (Claude gets stuck → OpenCode takes over with write
  access).
