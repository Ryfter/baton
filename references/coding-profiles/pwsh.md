# PowerShell coding profile (lean)

- Verify: `pwsh -NoProfile -File scripts/test-<name>.ps1`
- `$ErrorActionPreference = 'Stop'`; match existing house patterns
- Keep shell args under 965 bytes — temp files for long prose
- Dot-source libs; do not duplicate fleet helpers inline
- Ox Alpha for planning/diff; agentic CLIs for repo-wide edits
