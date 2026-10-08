---
name: prompt-feedback
description: Get Evolve Coach feedback on your last prompt.
allowed-tools: shell
---

Execute the command for this machine with the shell tool, exactly once:

On macOS and Linux:

```sh
EVOLVE_COACH_SURFACE=copilot "$HOME/.evolve-coach/bin/evolve-coach-cli" on-demand-feedback
```

On Windows:

```powershell
$env:EVOLVE_COACH_SURFACE = 'copilot'; & (Join-Path $HOME .evolve-coach/bin/evolve-coach-cli.exe) on-demand-feedback
```

Do not print the command itself. Reply with the command's stdout verbatim — every line, nothing else. Do not summarize, reformat, or add commentary.
