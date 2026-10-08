---
name: status
description: Show your Evolve Coach status — the behaviors toward your next AI profile.
allowed-tools: shell
---

Run the command for this machine exactly once:

On macOS and Linux:

```sh
EVOLVE_COACH_SURFACE=copilot "$HOME/.evolve-coach/bin/evolve-coach-cli" status
```

On Windows:

```powershell
$env:EVOLVE_COACH_SURFACE = 'copilot'; & (Join-Path $HOME .evolve-coach/bin/evolve-coach-cli.exe) status
```

Reply with its stdout verbatim — every line, nothing else. Do not summarize, reformat, or add commentary.
