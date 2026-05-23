# Model Routing Catalog

> **Purpose:** Reference for routing decisions when Octopus's auto-router isn't enough,
> and the destination for promoted observations from `model-routing-log.md`.
> Last consolidated: never (seeded 2026-05-22).

## How to use this file

- **Claude (orchestrator):** consult this file when:
  - Octopus's `/octo:auto` would pick a generic model but a specialty model fits better (commit messages, OCR, structured extraction).
  - You need to know which Ollama/LM Studio model is currently warm.
  - You need to know whether a cloud provider's quota is tight.
- **Consolidation flow (`/consolidate-routing`):** appends/edits sections here based on journal patterns.

## Specialty models (invoke directly via Bash, bypass Octopus)

### tavernari/git-commit-message (Ollama, 4.4 GB)

- **Use for:** generating commit messages from a diff.
- **Invoke:** `git diff --staged | ollama run tavernari/git-commit-message`
- **Strengths:** purpose-trained on commit message conventions; produces concise, conventional-commit-style output.
- **Weaknesses:** does nothing else; do not use for general text.
- **Cost tier:** free (local).

### nuextract (Ollama, ~2 GB once pulled)

- **Use for:** pulling structured JSON out of unstructured text per a schema.
- **Invoke:** `ollama run nuextract` with the schema and source text.
- **Strengths:** small, fast, deterministic-ish for extraction tasks.
- **Weaknesses:** weak for free-form generation; will refuse non-extraction tasks.
- **Cost tier:** free (local).
- **Status:** not yet pulled (bootstrap will pull).

### deepseek-ocr (Ollama, 6.7 GB)

- **Use for:** OCR of images / scanned documents.
- **Invoke:** `ollama run deepseek-ocr` with image attached.
- **Cost tier:** free (local).

## General coders (Octopus usually routes here automatically)

### Cloud — paid quota

| Model | Backend | Context | Strengths | Watch out for |
|---|---|---|---|---|
| Claude Sonnet 4.6 | via Claude Code itself | 200k | Reasoning, planning, orchestration | Quota cost — orchestrator only, push grunt work elsewhere |
| Codex (GPT-5.x) | `codex` CLI | 256k | General coding | Paid API |
| Gemini (latest) | `gemini` CLI | 1M | Huge-context summarization, cross-file analysis | Free tier, but rate-limited |
| Copilot CLI | `gh copilot` / `copilot` | varies | Covered by Education sub — cheap effective coder | Newer, less battle-tested |

### Local — Ollama (free)

| Model | Size | Strengths | Weaknesses | Status |
|---|---|---|---|---|
| `devstral:24b` | 14 GB | Multi-file refactors, code that needs context | Slow first-token | Pulled |
| `qwen3:30b` | 18 GB | General reasoning, coding | Big VRAM footprint | Pulled |
| `qwen2.5-coder:7b-instruct-q5_K_M` | ~5 GB | Fast cycle, boilerplate, renames | Weaker on multi-file logic | Not yet pulled |
| `deepseek-coder-v2:16b-lite-instruct-q5_K_M` | ~10 GB | Code review, diff explanation, bug spotting | Slower than 7b coders | Not yet pulled |
| `phi4:14b-q8_0` | 15 GB | Fast general reasoning | Less code-specialized | Pulled |
| `gpt-oss:20b` | 13 GB | General | Older | Pulled |
| `hermes3:8b` | ~5 GB | Function-calling / tool-use tuned | Not yet a primary path | Not yet pulled |

### Local — LM Studio (free)

JIT-loaded; first call to a not-yet-loaded model takes 5–30 s.

| Model | Strengths | Notes |
|---|---|---|
| `qwen/qwen3-coder-30b` | Top-tier local coder | Mirror of devstral lane |
| `qwen/qwen3.5-35b-a3b` | Big general | High VRAM |
| `google/gemma-3-27b` | General | Permissive license |
| `zai-org/glm-4.7-flash` | Fast general | |
| `openai_gpt-oss-20b` | General | Mirror of Ollama gpt-oss |
| `nvidia/nemotron-3-nano` | Fast | |
| `qwen2.5-0.5b-instruct` | Tiny — sanity checks only | |
| `llama-3.2-1b-instruct` | Tiny — sanity checks only | |
| Embeddings: `text-embedding-qwen3-embedding-8b`, `text-embedding-nomic-embed-text-v1.5` | RAG | |

### Vision / multimodal

- `llama3.2-vision:11b-instruct-q8_0` (Ollama) — general vision.
- `deepseek-ocr` — see specialty section.

## Routing heuristics (evolves via consolidation)

- **Commit messages:** always `tavernari/git-commit-message`. Never Octopus.
- **Structured JSON extraction:** `nuextract` if schema is clean; Octopus → cloud model if extraction is ambiguous.
- **Single-file refactor in a known language:** `local-coder` lane (devstral or qwen3-coder-30b).
- **Multi-file analysis / huge context:** Gemini via `/octo:auto`.
- **Code review / second opinion:** `deepseek-coder-v2:16b-lite-instruct`.
- **Trivial edits, renames, formatting:** `qwen2.5-coder:7b` (warm if available, otherwise phi4:14b).
- **Anything touching sensitive data:** local only (Ollama or LM Studio).

## Pricing table (for OTel cost computation)

USD per million tokens, input / output. Update when providers change pricing.

| Model | Input | Output |
|---|---|---|
| claude-sonnet-4-6 | $3 | $15 |
| claude-opus-4-7 | $15 | $75 |
| claude-haiku-4-5 | $1 | $5 |
| gpt-5 | $TBD | $TBD |
| gemini-2.5-pro | $TBD | $TBD |
| (local) | $0 | $0 |

Note: TBD entries get filled when first observed in a journal `otel` line — the parser
logs a warning and uses $0 until a price is added here.
