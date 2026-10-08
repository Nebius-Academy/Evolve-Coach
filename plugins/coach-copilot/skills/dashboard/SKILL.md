---
name: dashboard
description: Open your Evolve Coach management dashboard in the browser.
allowed-tools: shell
---

Run the command for this machine exactly once:

On macOS and Linux:

```sh
EVOLVE_COACH_SURFACE=copilot "${EVOLVE_COACH_BIN:-$HOME/.copilot/evolve-coach/bin/evolve-coach-cli}" dashboard
```

On Windows:

```powershell
$env:EVOLVE_COACH_SURFACE = 'copilot'; & ($env:EVOLVE_COACH_BIN ?? (Join-Path $HOME .copilot/evolve-coach/bin/evolve-coach-cli.exe)) dashboard
```

Reply with its stdout verbatim — every line, nothing else. Do not summarize, reformat, or add commentary.
