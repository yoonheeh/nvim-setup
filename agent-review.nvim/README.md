# agent-review.nvim

GitHub-style inline code review for Neovim, answered by the agent session
that made the changes — Claude by default, OpenCode via `:ReviewBackend`.

- Workflow and reference: `:help agent-review`
- Implementation: `lua/agent-review/init.lua` (single file, no dependencies)
- Regression tests: `./tests/run.sh` (headless plenary busted, no live model)
