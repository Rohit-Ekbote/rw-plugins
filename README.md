# rw-plugins

A [Claude Code](https://claude.ai/code) plugin marketplace for the RunWhen
platform. Currently ships one plugin:

## `rwl-install-wizard`

Guided installer for the RunWhen platform Helm chart. Answer an interview about
your cluster's constraints; the wizard generates layered `values` overlays and a
tailored user guide + debug guide for your exact install shape.

- **Generate-only** — never touches a cluster, never runs `helm`/`kubectl`.
- **Self-contained** — needs no chart source repo at runtime.
- **Secret-free** — never asks for or stores any credential.

## Install

In Claude Code:

```
/plugin marketplace add Rohit-Ekbote/rw-plugins
/plugin install rwl-install-wizard@rw-plugins
```

Then restart Claude Code so the plugin's skills load.

## Use

- `/rwl-install` — run or resume the interview, then generate the kit.
- `/rwl-install-show` — show the saved profile and what's been generated.
- `/rwl-install-explain <topic>` — explain one install decision in depth.

Output lands in your working directory (gitignored):

- `.claude/rwl-install-profile.yaml` — your saved answers (re-runnable).
- `rwl-install-out/values-*.yaml` — layered overlays.
- `rwl-install-out/USER-GUIDE.md`, `rwl-install-out/DEBUG-GUIDE.md`,
  `rwl-install-out/PREREQUISITES.md`.

See [`rwl-install-wizard/README.md`](rwl-install-wizard/README.md) for full
details and [`docs/2026-06-17-rwl-install-wizard-design.md`](docs/2026-06-17-rwl-install-wizard-design.md)
for the design.

## License

MIT — see [LICENSE](LICENSE).
