# Evolve Coach

Coaching on how you work with AI. It gives feedback in the flow.

## Commands

- `/coach:status` — your AI profile and the microskills you're climbing toward.
- `/coach:feedback` — feedback on the last prompt you wrote.
- `/coach:dashboard` — opens the management dashboard in your browser and prints a one-time link (valid about two minutes).

## Requirements

- macOS or Linux, on `darwin-arm64`, `darwin-x64`, `linux-x64` or `linux-arm64`. Linux binaries are glibc; musl is not supported.
- Claude Code in the terminal, in the VS Code extension, or in the desktop app — the desktop app needs Claude Code installed separately.
- A Claude Team or Enterprise plan, and a per-organization access token.

## Setup

An organization admin sets this up once; org-wide setup needs Owner. Marketplace `evolve-coach`, plugin `coach`. Your organization is issued a per-organization JWT at onboarding — the plugin sends it on every request, and without it the backend refuses the data.

Organization settings → Claude Code → Managed settings:

```json
{
  "extraKnownMarketplaces": {
    "evolve-coach": {
      "source": {
        "source": "url",
        "url": "https://raw.githubusercontent.com/Nebius-Academy/Evolve-Coach/main/.claude-plugin/marketplace.json"
      },
      "autoUpdate": true
    }
  },
  "enabledPlugins": { "coach@evolve-coach": true },
  "env": { "EVOLVE_COACH_AUTH_TOKEN": "<your-org-jwt>" }
}
```

`enabledPlugins` installs the plugin for everyone in the organization by default.
