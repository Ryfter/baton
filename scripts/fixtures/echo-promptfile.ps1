#!/usr/bin/env pwsh
# Test fixture for the {{prompt_file}} transport: prints the raw content of the
# path handed to it, so a dispatch round-trip can prove quote-safety. Not $args
# (reserved) — an explicit param so the temp path arrives verbatim.
param($PathArg)
Get-Content -Raw -LiteralPath $PathArg
