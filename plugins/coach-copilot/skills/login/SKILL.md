---
name: login
description: Log in to Evolve Coach on this machine.
allowed-tools: shell
---

Run this command exactly once:

```sh
EVOLVE_COACH_SURFACE=copilot "${EVOLVE_COACH_BIN:-$HOME/.copilot/evolve-coach/bin/evolve-coach-cli}" login
```

Reply with its stdout verbatim — every line, nothing else. Do not summarize, reformat, or add commentary.
