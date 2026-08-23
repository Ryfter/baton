# Maestro Home Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace Home junk drawer with shift board: attention rail, capacity strip, compact admit, project cards with economics (policy C savings).

**Architecture:** New `home_board` + `project_economics` readers fold Maestro jobs, cockpit grid, gauges window, and fleet into one HTMX-polled payload. Home evicts BI widgets; compose gets compact mode.

**Tech Stack:** FastAPI, Jinja2, HTMX 2s poll, existing brass CSS tokens.

## Global Constraints

- Dashboard claim only — no `scripts/` edits
- Keep dark/brass theme palette
- Never show `empty-until-reset` or fake usable stubs
- Savings counterfactual **C** (per-provider policy)
- Hide cap gauges on Home — strip links to `/gauges`

---

### Task 1: Goal sanitizer + API rates fixture

**Files:**
- Create: `dashboard/readers/display_goal.py`
- Create: `dashboard/data/api-rates.json`
- Test: `dashboard/tests/test_display_goal.py`

---

### Task 2: Project economics reader (policy C)

**Files:**
- Create: `dashboard/readers/project_economics.py`
- Test: `dashboard/tests/test_project_economics.py`

---

### Task 3: Home board reader (attention, capacity, cards)

**Files:**
- Create: `dashboard/readers/home_board.py`
- Modify: `dashboard/readers/cockpit_grid.py` (use display_goal)
- Test: `dashboard/tests/test_home_board.py`

---

### Task 4: Router + templates + slim index

**Files:**
- Create: `dashboard/routers/home.py`
- Create: `dashboard/templates/partials/home_header.html`
- Create: `dashboard/templates/partials/home_floor.html`
- Modify: `dashboard/templates/index.html`
- Modify: `dashboard/main.py`

---

### Task 5: Compact compose + CSS

**Files:**
- Modify: `dashboard/templates/partials/maestro_compose.html`
- Modify: `dashboard/routers/maestro.py`
- Modify: `dashboard/static/style.css`

---

### Task 6: Verify tests + restart dashboard

Run: `.venv/bin/python -m pytest dashboard/tests/test_display_goal.py dashboard/tests/test_project_economics.py dashboard/tests/test_home_board.py dashboard/tests/test_gauges.py -q`
