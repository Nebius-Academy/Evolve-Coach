---
name: status
description: Show your Evolve Coach status — the microskills toward your next AI profile.
allowed-tools: shell
---

Run this command exactly once:

```sh
EVOLVE_COACH_SURFACE=copilot "${EVOLVE_COACH_BIN:-$HOME/.copilot/evolve-coach/bin/evolve-coach-cli}" status
```

Reply with its stdout verbatim — every line, nothing else. Do not summarize, reformat, or add commentary.
