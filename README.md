# Evolve Coach — plugin marketplace

Marketplace for the **Coach** plugin — it turns your AI coding sessions into grounded, in-the-flow feedback on how you work with AI. Same plugin, two surfaces: Claude Code and GitHub Copilot CLI.

## Install

Claude Code:

```sh
/plugin marketplace add Nebius-Academy/Evolve-Coach
/plugin install coach@evolve-coach
```

GitHub Copilot CLI:

```sh
copilot plugin marketplace add Nebius-Academy/Evolve-Coach
copilot plugin install coach@evolve-coach
```

Then run `/coach:login` once per machine; the login is shared between the two surfaces.

## Install without the CLI

Both clients accept the same declaration — only the file differs: `~/.claude/settings.json` for Claude Code, `~/.copilot/settings.json` for Copilot CLI.

```json
{
  "extraKnownMarketplaces": {
    "evolve-coach": {
      "autoUpdate": true,
      "source": {
        "source": "git",
        "url": "https://github.com/Nebius-Academy/Evolve-Coach.git"
      }
    }
  },
  "enabledPlugins": { "coach@evolve-coach": true }
}
```

Each client then reads its own catalog out of the clone. The declaration registers the marketplace but does not fetch the plugin, so `install coach@evolve-coach` still runs once per machine. The `url` source kind — a link straight to a `marketplace.json` — works only in Claude Code; Copilot CLI clones whatever the `url` holds, so it needs the repository, not the file.

## Layout

- `.claude-plugin/marketplace.json` — the Claude Code catalog; points at `plugins/coach-claude`.
- `.github/plugin/marketplace.json` — the Copilot CLI catalog; points at `plugins/coach-copilot`.
- `plugins/coach-claude/` — the Claude Code plugin (commands + hooks).
- `plugins/coach-copilot/` — the Copilot CLI plugin (skills + hooks).

Each client reads only its own catalog: Claude Code looks solely at `.claude-plugin/marketplace.json`, while Copilot CLI prefers `.github/plugin/marketplace.json` and falls back to `.claude-plugin/` only when the former is absent.

Both plugin payloads are published from GitLab CI — edit them there, not here.
