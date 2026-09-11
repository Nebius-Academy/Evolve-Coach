---
name: prompt-feedback
description: Get Evolve Coach feedback on your last prompt.
allowed-tools: shell
---

Execute this command with the shell tool, exactly once:

```sh
EVOLVE_COACH_SURFACE=copilot "${EVOLVE_COACH_BIN:-$HOME/.copilot/evolve-coach/bin/evolve-coach-cli}" on-demand-feedback
```

Do not print the command itself. Reply with the command's stdout verbatim — every line, nothing else. Do not summarize, reformat, or add commentary.
