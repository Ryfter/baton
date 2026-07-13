# Baton diagrams

Vector (SVG) infographics for using Baton, embedded in the [README](../../../README.md)
and [command reference](../../COMMANDS.md). Plain SVG — they render natively on GitHub in
both light and dark themes, and are hand-editable (no build step).

| File | What it shows |
|---|---|
| `baton-mental-model.svg` | The 3-tier Conductor model (Conductor → Orchestrators → Instruments) + the CLI-first / GUI-as-control-board framing. |
| `baton-workflow.svg` | Using `/baton` — the happy path (idea → start → gate → dispatch → accept → ship) and the `/baton:go` shortcut. |
| `baton-command-map.svg` | All 50 commands, grouped into nine clusters. |
| `baton-fleet-loop.svg` | The dispatch + telemetry loop — route, dispatch, journal, learn, failover. |

Designed in Excalidraw, authored as SVG for durable inline rendering. To revise, edit the
SVG directly or redraw in Excalidraw and re-export.
