# Evolve Coach — Claude Code marketplace

Public marketplace for the **Coach** Claude Code plugin — it turns your real Claude
Code sessions into grounded, in-the-flow feedback on how you work with AI.

This repo is only the **marketplace manifest**. The plugin payload ships as the public
npm package [`@nebius-academy/coach`](https://www.npmjs.com/package/@nebius-academy/coach),
which `.claude-plugin/marketplace.json` points at. The plugin's source of truth lives in
a separate private repo; releases are published to npm from there, and the pinned version
here is bumped to match.

## Install (users)

```sh
/plugin marketplace add Nebius-Academy/Evolve-Coach
/plugin install coach@evolve-coach
```

Enable auto-update, then `/reload-plugins`. No activation command — the hooks fire on
their own once installed.

## Org-wide install (admins)

In **Claude Desktop → your org → Organization settings → Claude Code → Managed settings**:

```json
{
  "extraKnownMarketplaces": {
    "evolve-coach": {
      "source": { "source": "github", "repo": "Nebius-Academy/Evolve-Coach" }
    }
  }
}
```

Optionally force-enable org-wide (auto-installed, non-removable):

```json
{ "enabledPlugins": { "coach@evolve-coach": true } }
```

Everything is public over HTTPS — no SSH key or private access required.
