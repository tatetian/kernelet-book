# Claude Code instructions for this directory

@AGENTS.md

Notes specific to working here as Claude Code:

- Run every command from the repository root (this directory). The shell's working directory can drift into `src/`; use absolute paths or `cd` explicitly in each command.
- Verify before reporting: `make check` must print `check: OK` and `make build` must exit 0. Quote the actual output in the final message.
- When a change touches how a page looks (a figure, a diagram, a style rule), render it with `make render PAGE=… OUT=<scratchpad>/name.png` and look at the screenshot; do not infer from the HTML alone.
- The owner reviews wording closely. Do not rewrite existing sentences to "improve" them; add a link or a new paragraph, or ask.
- Use the scratchpad directory for screenshots and temporary scripts, never `/tmp` directly and never this directory.
