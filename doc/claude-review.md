# claude-review

A GitHub-style inline code review interface for Neovim, backed by the Claude terminal session that made the changes.

## How it works

When Claude (running in terminal A) makes code changes, you can open any changed file and
start a review thread on specific lines. Questions are sent to the **same Claude session**
that made the changes, so Claude can reference its own reasoning and prior task context.

Threads live for the duration of the Neovim session (not persisted to disk).

## Workflow

```
1. Claude (terminal A) makes changes to files.

2. In Neovim, open a changed file.

3. Enter visual mode (V), select lines you want to ask about.

4. Press <leader>rc — a prompt appears: "Review comment:"

5. Type your question. Claude responds in a right-side panel.

6. Press r in the panel to reply. Multi-turn conversation supported.

7. A 💬 annotation appears on the selected lines for each thread.
```

## Session discovery

The plugin finds the most recently active Claude session for the current project by scanning:

```
~/.claude/projects/<encoded-cwd>/*.jsonl
```

This reuses the same JSONL-scanning approach from `git-worktree.lua`. The session ID
(UUID filename without `.jsonl`) is passed to `claude --resume <id> -p "..."` for each
message, giving true continuity with terminal A's conversation history.

## Keymaps

| Mode         | Key           | Action                                    |
|--------------|---------------|-------------------------------------------|
| Visual       | `<leader>rc`  | Start a review thread on selected lines   |
| Normal       | `<leader>rt`  | Open thread panel for line under cursor   |
| Normal       | `<leader>rn`  | Jump to next thread                       |
| Normal       | `<leader>rp`  | Jump to previous thread                   |
| Normal       | `<leader>rx`  | Clear all threads for the current buffer  |
| Panel normal | `r`           | Reply to the current thread               |
| Panel normal | `n` / `p`     | Navigate between threads                  |
| Panel normal | `q`           | Close the panel                           |

## Panel layout

```
┌── Editor ──────────────────────────────────┬── Thread Panel (40%) ──────────────────┐
│  42 │ function process(arr) {  💬 2 cmts  │   src/algo.ts : 42–46                 │
│  43 │   for (let i ...) {                  │ ─────────────────────────────────────  │
│  44 │     for (let j ...) {                │ You:                                   │
│  45 │     }                                │   Why is this O(n²)?                  │
│  46 │   }                                  │                                        │
│                                            │ Claude:                                │
│                                            │   The nested loop iterates `arr`       │
│                                            │   each time. Consider a Map for O(n)…  │
│                                            │                                        │
│                                            │ ─── [r] reply  [n/p] threads  [q] ─── │
└────────────────────────────────────────────┴────────────────────────────────────────┘
```

## Prompt sent to Claude

For the **first message** in a thread:

```
I'm reviewing the changes you just made.

File: src/algo.ts, lines 42–46:
```typescript
<selected lines>
```

Git diff for this file:
```diff
<git diff HEAD -- src/algo.ts>
```

<your question>
```

For **replies**, only the new message is sent (Claude's session already contains the
full conversation history via `--resume`):

```
(Continuing review of src/algo.ts lines 42–46)

<your reply>
```

## Requirements

- `claude` CLI available in `$PATH` (Claude Code)
- An active Claude session in the current project (`~/.claude/projects/` must have a `.jsonl` file)
- Neovim 0.9+

## File

`lua/plugins/claude-review.lua` — single-file implementation, no external dependencies.
