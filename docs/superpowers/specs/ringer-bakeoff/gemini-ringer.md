# Gemini view: UX/UI and Developer Experience for Ringer in Baton

**Author:** Gemini (Design & Interface Reviewer)  
**Date:** 2026-07-10  
**Status:** Independent UI/UX and Developer Experience Specification & Critique  
**Sources:** [Unlock AI Ringer guide](https://unlock-ai.natebjones.com/guides/ringer) · [NateBJones-Projects/ringer](https://github.com/NateBJones-Projects/ringer) · [codex-ringer.md](file:///D:/Dev/Baton/codex-ringer.md) · [grok-ringer.md](file:///D:/Dev/Baton/grok-ringer.md) · Baton dashboard master at `db16454` · Baton decisions d009, d010, d038, d056, d078, d080

---

## 0. Executive design verdict

As Baton's **Design & Interface Reviewer** (decisions d009/d010), my role is to evaluate proposals from the perspective of **Developer Experience (DX)**, **User Experience (UX)**, and **Visual Interface Design (UI)**. 

Grok's proposal (Approach B - Tool Adapter) and Codex's proposal (Approach A - Native Verification Contract) present a classic architectural tension. However, when evaluated through a design-first lens, **the UI/UX stakes dictate the backend choice**:

1. **Reject Grok's double-dashboard design (Approach B)**: Having a native dashboard on port `8765` and a separate Ringside dashboard on port `8700` creates severe visual and cognitive fragmentation. Split-attention HUDs lead to poor operator trust, fragmented telemetry logging, duplicate configuration files, and credential routing chaos.
2. **Adopt Codex's native control plane (Approach A)**: A unified, native verification lifecycle is the only way to deliver a single, coherent, zero-dependency product.
3. **Elevate the Visual Experience**: Codex's native proposal is highly functional but UI-conservative, treating the dashboard as an afterthought of basic tables. **Gemini recommends a hybrid compromise**: implement Codex's native backend engine, but design a premium, high-fidelity **"Swarm Cockpit" UI** directly inside Baton's dashboard. This UI will match Ringside's live execution streams, progress indicators, and visual telemetry, wrapped in a premium, accessible dark-mode UI.

---

## 1. Deep Critique: Codex (`codex-ringer.md`) vs. Grok (`grok-ringer.md`)

Below is the comparative analysis and critique of the two specifications, identifying where each excels and fails, followed by unified recommendations.

```text
                     BATON INTEGRATION LANDSCAPE
                     
     Grok's View (Composition)          Codex's View (Native Implementation)
     ┌───────────────────────┐          ┌───────────────────────┐
     │  Baton Conductor      │          │  Baton Conductor      │
     │         │             │          │         │             │
     │         ▼             │          │         ▼             │
     │  ringer.py CLI        │          │  Baton Native Verify  │
     │    ├── Ringside HUD   │          │  (PowerShell/Python)  │
     │    └── WSL Workers    │          │         │             │
     └───────────────────────┘          │         ▼             │
                                        │  Baton UI / DB        │
                                        └───────────────────────┘
```

### 1.1 Grok's Approach B (Tool Adapter) - Critique

Grok advocates for a **compositional approach**: treat Ringer as a separate tool installed on the user's system, invoking `ringer.py` via PowerShell scripts and letting the user monitor executions using Ringer's own browser HUD (Ringside).

#### Where Grok is BETTER (Strengths)
*   **Time-to-Market**: Grok leverages Ringer's existing codebase immediately. Re-implementing a parallel process pool, scoreboard telemetry, and a live web server is highly complex. Grok's wrapper is a few scripts, whereas Codex's native proposal is a massive engineering project.
*   **Logical Triage Heuristics**: Grok's Section 4.7 defines clear, sensible guidelines on *when* the Conductor should choose Ringer vs. Baton's standard sequential DAG (e.g. independent execution tasks with shell tests go to Ringer; complex, dependent research steps go to Conductor).
*   **Worktree Lifecycle Detail**: Grok notes a critical Ringer execution detail Codex missed: Ringer deletes successful worktrees upon completion. Grok details a harvesting verification wrapper to prevent deliverables from being deleted.

#### Where Grok is WORSE (Weaknesses)
*   **Cognitive & Visual Split**: Forces developers to run two dashboard servers (Baton on `:8765`, Ringside on `:8700`). Bouncing between two screens, two run repositories, and two logging models degrades usability.
*   **WSL & Windows Path Friction**: Ringer relies on Linux/macOS process group management and sandboxing. Running it on Windows via WSL (as is necessary on this box) requires translating directory path semantics (e.g. `D:\Dev\Baton` vs `/mnt/d/Dev/Baton`) and managing credentials across shell layers. This is highly brittle.
*   **Config Duplication**: Requires maintaining duplicate configurations for models and API keys in `~/.baton/fleet.yaml` and `~/.config/ringer/config.toml`. Attempts to sync them dynamically add unnecessary file-parsing complexity.
*   **Security Vulnerability**: Grok accepts Ringer's default shell-string execution. Running arbitrary, model-generated shell tests in an automated Conductor loop introduces critical command injection vectors.

---

### 1.2 Codex's Approach A (Baton-Native Verification) - Critique

Codex advocates for a **native cleanroom implementation**: implement verification directly in Baton's existing Conductor and runner, rejecting any execution dependency on Ringer.

#### Where Codex is BETTER (Strengths)
*   **Security & Argument Vectors**: Codex mandates executing verification as argument vectors (`argv`) rather than shell strings. This eliminates command injection, quote escaping, and wildcards during automated runs.
*   **Oracle Protection**: Codex addresses a critical Ringer blindspot: cheap models cheating checks by modifying unit tests or fake assertion files. Codex's "Evidence Grading" system hashes fixture/test paths before the labor phase and downgrades results if the oracle was tampered with.
*   **Platform Purity**: By keeping the runner native to Baton's PowerShell/Python tools, it works natively on Windows without WSL overhead.
*   **License Safety**: Avoids wrapping, calling, or distributing Ringer code, mitigating any PolyForm Shield non-compete licensing disputes.

#### Where Codex is WORSE (Weaknesses)
*   **NIH (Not Invented Here) / Re-invention Tax**: Rebuilding parallel worker pools, scoreboard visualizations, and catalog synchronization from scratch is a massive development commitment.
*   **Delayed Swarm Parallelism**: Codex pushes parallel task execution all the way to "V5." For the foreseeable future, Baton remains a slow, sequential worker runner.
*   **UX Deprivation**: Codex treats the dashboard integration as a simple text log view. It ignores Ringside's most valuable UX contribution: the live visual feedback of parallel swarms in action.

---

### 1.3 Feature Comparison Matrix

| Feature / Metric | Grok's Spec | Codex's Spec | Gemini's Synthesized Spec |
|:---|:---:|:---:|:---:|
| **Security (Command Injection)** | 🔴 Unsafe (Shell strings) | 🟢 Safe (Argv only) | 🟢 Safe (Argv only) |
| **Platform Compatibility** | 🟡 Brittle (WSL translation) | 🟢 Excellent (Native Windows) | 🟢 Excellent (Native Windows) |
| **Licensing Risk** | 🟡 Moderate (Wrap/Dependency) | 🟢 None (Cleanroom) | 🟢 None (Cleanroom) |
| **Development Cost** | 🟢 Low (Adapter wrapper) | 🔴 High (Native rebuild) | 🟡 Moderate (PowerShell Jobs + UI) |
| **UI/UX Fragmentation** | 🔴 Bad (Two Dashboards) | 🟡 Weak (Basic Tables) | 🟢 Excellent (Unified Cockpit) |
| **Worker Cheating Protection**| 🔴 None (Trusts exit code) | 🟢 Strong (Oracle checks) | 🟢 Strong (Oracle checks) |
| **Time to Parallelism** | 🟢 Immediate (Ringer fans out) | 🔴 Delayed (V5 feature) | 🟡 Medium (PowerShell ThreadJobs) |
| **Config Complexity** | 🔴 Dual configs | 🟢 Single `fleet.yaml` | 🟢 Single `fleet.yaml` |

---

### 1.4 Recommendations to Codex and Grok

1.  **To Grok**: We must reject the dual-dashboard (`:8700` and `:8765`) design and the WSL process-group mapping layer. Baton must maintain a single, native control plane on Windows.
2.  **To Codex**: We must not defer parallel execution to a distant release slice. Instead of re-implementing Ringer's complex engine, implement a lightweight parallel job runner using PowerShell ThreadJobs (`Start-ThreadJob`) in Slice 2. Additionally, we must commit to building a rich visual Swarm Cockpit rather than dry text tables.
3.  **To Both**: We must adopt Codex's static `argv` verification schema and pre-labor oracle hashing. We must route all model selections exclusively through Baton's `fleet.yaml` to ensure unified budget, usage, and capability routing.

---

## 2. CLI Developer Experience (DX) design

When running a swarm, the terminal output is the developer's primary focus. The command-line output should be structured to show progress, parallel lanes, and verification results without overwhelming the buffer.

### 2.1 Terminal output flow
When Conductor runs a verified task (or batch of parallel verified tasks), it should use clean ANSI coloring and status indicators:

```text
baton:go Run 2026-07-10_0124 [branch: baton/run-0124]
────────────────────────────────────────────────────────────────────────────────
[+] Task t2: "Generate invoice validator and write focused tests"
    ├─ Fleet Route: codex-cli [cost_tier: free]
    ├─ Expected Artifacts: src/invoice.py, tests/test_invoice.py
    ├─ Verification: pytest tests/test_invoice.py -q
    └─ Oracle: Integrity checks enabled on tests/fixtures/invoice_cases.json

[RUNNING] Dispatching worker to worktree...
[WORKER]  Completed in 14.2s (exit 0)
[CHECK]   Running verification: python -m pytest tests/test_invoice.py -q
[PASS]    Verification succeeded.
          ✓ Proves: the focused invoice validation suite passes against protected fixture cases
          ✓ Allowed paths: src/invoice.py and tests/test_invoice.py untouched other files.
          ✓ Protected oracle: tests/fixtures/invoice_cases.json matches signature.
[OK]      Task t2 verified on first attempt.

[+] Task t3: "Add database connection pool retry logic"
    ├─ Fleet Route: grok-cli [cost_tier: standard]
    ├─ Expected Artifacts: src/db.py
    ├─ Verification: python scripts/test-db-retry.py
    
[RUNNING] Dispatching worker to worktree...
[WORKER]  Completed in 8.5s (exit 0)
[CHECK]   Running verification: python scripts/test-db-retry.py
[FAIL]    Verification failed (exit 1).
          Output Excerpt:
          >>> ConnectionError: Pool exhausted and no retry attempted.
          >>> AssertionError: Retry count expected 3, got 0.
[RETRY]   Dispatching attempt #2 (Injected failure output)...
[RUNNING] Dispatching worker to worktree...
[WORKER]  Completed in 11.1s (exit 0)
[CHECK]   Running verification: python scripts/test-db-retry.py
[PASS]    Verification succeeded on attempt #2.
          ✓ Proves: pool retries three times before raising ConnectionError
[OK]      Task t3 verified (rescued on attempt 2).
────────────────────────────────────────────────────────────────────────────────
```

### 2.2 ANSI escape design system
* **Headers**: Accent color (e.g., Magenta/Cyan) to separate stages of orchestration.
* **Worker Status**: 
  - `[RUNNING]` - Bold yellow pulsing or standard yellow text.
  - `[PASS]` - Bold green background/foreground `✓` status.
  - `[FAIL]` - Bold red `✕` status with error output indented by 4 spaces.
  - `[RETRY]` - Cyan text highlighting the recovery process.
* **Oracle Verification**: High-contrast checkmarks (`✓` in green, `✕` in red) to show individual contract requirements.

---

## 3. Web UI: "The Swarm Cockpit" spec

To replace Ringside's HUD natively, we will add a dedicated **Swarm Cockpit** view to the Baton dashboard (`http://127.0.0.1:8765/runs/<run-id>/swarm`).

### 3.1 Layout wireframe (Dark Mode)
```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ 🐙 Baton Conductor  [Roster]  [KB]  [Projects]  [Runs]          2026-07-10 01:24:00 AM │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ BACK TO RUN: 2026-07-10_0124 (baton/run-0124)                   [ACCEPTANCE GATE: PENDING]│
│                                                                                        │
│ ┌────────────────────────────────────────────────────────────────────────────────────┐ │
│ │  SWARM PROGRESS: 75% COMPLETE                                                      │ │
│ │  [■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■       ] [3/4 Tasks Passed]    │ │
│ └────────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                        │
│ ┌──────────────────────────────────────┐  ┌──────────────────────────────────────────┐ │
│ │ ACTIVE WORKERS (2/3 Parallel)        │  │ DETAILED RUN TRACE                       │ │
│ ├──────────────────────────────────────┤  ├──────────────────────────────────────────┤ │
│ │ [✓] Task t1: setup_env (codex-cli)   │  │ Selected: Task t3 (grok-cli)             │ │
│ │     Pass: 1.2s | exit 0 | First-try  │  │ Status: [FAILING] -> [RETRYING]          │ │
│ │                                      │  │                                          │ │
│ │ [⟳] Task t3: db_retry (grok-cli)     │  │ ── WORKER OUTPUT ─────────────────────── │ │
│ │     Running: Attempt #2 (4.1s)       │  │ 2026-07-10 01:24:12 - Info: writing      │ │
│ │                                      │  │ db retry logic in src/db.py...           │ │
│ │ [✕] Task t4: auth_jwt (opencode)     │  │                                          │ │
│ │     Fail: 18.4s | exit 1 | 0 Retries │  │ ── VERIFICATION OUTPUT ───────────────── │ │
│ │                                      │  │ AssertionError: Retry count expected 3,  │ │
│ │ [◌] Task t5: docs (codex-cli)        │  │ got 0.                                   │ │
│ │     Status: Queued                   │  │                                          │ │
│ └──────────────────────────────────────┘  └──────────────────────────────────────────┘ │
│                                                                                        │
│ ┌────────────────────────────────────────────────────────────────────────────────────┐ │
│ │ ROUTING PERFORMANCE SCOREBOARD (Cumulative Telemetry)                              │ │
│ ├───────────────────────┬──────────────────────┬───────────────────────┬─────────────┤ │
│ │ Model/Worker          │ Task Type            │ First-Try Pass Rate   │ Avg Duration│ │
│ ├───────────────────────┼──────────────────────┼───────────────────────┼─────────────┤ │
│ │ codex-cli             │ code-feature         │ 84% (21/25)           │ 12.4s       │ │
│ │ grok-cli              │ test-hardening       │ 72% (18/25)           │ 8.9s        │ │
│ │ opencode (deepseek)   │ code-refactor        │ 90% (9/10)            │ 22.1s       │ │
│ └───────────────────────┴──────────────────────┴───────────────────────┴─────────────┘ │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Visual Aesthetics (per Web Development Guidelines)
To deliver a premium UI that wows the operator and stays highly scannable:
* **Typography**: Clean sans-serif stack (`ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial`) matching the vendored offline styling in the redesigned dashboard.
* **Palette**: Sleek, utilitarian dark-mode palette using HSL tokens.
  - Body Background: `#0B0F19` (Deep slate)
  - Card Background: `#161F30` (Medium slate)
  - Border/Dividers: `#24324D` (Cobalt gray)
  - Text Primary: `#F3F4F6` (Cool gray 100)
  - Text Muted: `#9CA3AF` (Cool gray 400)
  - Accent Color: `#8B5CF6` (Vibrant violet)
* **Status Colors**:
  - Success (Pass): Green HSL (`hsl(142, 70%, 45%)`)
  - Warning/Retry: Yellow HSL (`hsl(45, 93%, 47%)`)
  - Failure/Error: Crimson HSL (`hsl(346, 84%, 50%)`)
  - Running: Pulse effect utilizing the violet accent.
* **Transitions**: Smooth HSL transforms (`150ms ease-in-out`) for active runs and hover selectors.
* **Radius constraints**: Hard rule: Card and list elements must use a maximum of `8px` (`--radius: 8px`) border-radius to maintain an operational cockpit aesthetic (Codex audit fix #5).

---

## 4. UI Component & Template implementation

### 4.1 HTML / Jinja2 partial: `dashboard/templates/partials/swarm_activity.html`
This partial renders the live grid of parallel tasks and can be updated via HTMX polling (`hx-trigger="every 2s"`).

```html
<!-- dashboard/templates/partials/swarm_activity.html -->
<div id="swarm-cockpit" class="swarm-container" data-run-id="{{ run.id }}" hx-get="/partials/runs/{{ run.id }}/swarm" hx-trigger="every 2s" hx-swap="outerHTML">
  
  <!-- Swarm Header with Status and Progress -->
  <div class="swarm-header-card">
    <div class="swarm-meta">
      <h3>Swarm Execution: {{ run.name }}</h3>
      <span class="run-branch-badge">branch: <code>{{ run.branch }}</code></span>
    </div>
    
    <div class="progress-bar-container">
      <div class="progress-labels">
        <span class="progress-pct">{{ run.progress_pct }}% Complete</span>
        <span class="progress-fraction">{{ run.passed_tasks }}/{{ run.total_tasks }} Passed</span>
      </div>
      <div class="progress-track">
        <div class="progress-fill" style="width: {{ run.progress_pct }}%; background: var(--accent-gradient);"></div>
      </div>
    </div>
  </div>

  <!-- Main Grid: Split between List and Console Log -->
  <div class="swarm-grid">
    
    <!-- Workers List Column -->
    <div class="workers-card card-outline">
      <h4 class="card-title">Parallel Workers (max_parallel: {{ run.max_parallel }})</h4>
      <ul class="worker-list" id="worker-task-list">
        {% for task in run.tasks %}
        <li class="worker-item {% if task.status == 'running' %}active-pulse{% endif %} {% if task.id == selected_task_id %}selected{% endif %}"
            hx-get="/partials/runs/{{ run.id }}/swarm?selected_task_id={{ task.id }}"
            hx-target="#swarm-cockpit"
            hx-swap="outerHTML"
            id="task-item-{{ task.id }}">
          
          <div class="worker-status-badge {{ task.status }}">
            {% if task.status == 'passed' %} ✓ 
            {% elif task.status == 'failed' %} ✕ 
            {% elif task.status == 'running' %} ◌ 
            {% else %} ⌛ {% endif %}
          </div>
          
          <div class="worker-details">
            <span class="task-key"><code>{{ task.key }}</code></span>
            <span class="task-model-desc">{{ task.worker_name }} ({{ task.model }})</span>
            <span class="task-proves">{{ task.proves }}</span>
          </div>
          
          <div class="worker-meta">
            {% if task.duration %}
              <span class="task-time">{{ task.duration }}s</span>
            {% endif %}
            {% if task.attempt_count > 1 %}
              <span class="retry-badge">Retry #{{ task.attempt_count }}</span>
            {% endif %}
          </div>
        </li>
        {% endfor %}
      </ul>
    </div>

    <!-- Active Console Trace Column -->
    <div class="console-card card-outline">
      <h4 class="card-title">Detailed Console Trace: <code>{{ selected_task.key }}</code></h4>
      <div class="console-tab-headers">
        <span class="tab-header active">Logs</span>
        <span class="tab-header">Verification Contract</span>
      </div>
      
      <div class="console-body" id="console-stream">
        {% if selected_task %}
          <div class="console-metadata">
            <p><strong>Capability:</strong> <code>{{ selected_task.capability }}</code></p>
            <p><strong>Expect Files:</strong> <code>{{ selected_task.expect_files | join(', ') }}</code></p>
            <p><strong>Verifier:</strong> <code>{{ selected_task.check_command }}</code></p>
          </div>
          
          <pre class="terminal-log">
<code>{{ selected_task.raw_log }}</code>
          </pre>
        {% else %}
          <div class="console-empty-state">
            <p class="text-muted">Select a running or completed task to view real-time log traces.</p>
          </div>
        {% endif %}
      </div>
    </div>
    
  </div>
</div>
```

### 4.2 CSS stylesheet tokens and components
We append these cohesive styles to `dashboard/static/style.css`. In keeping with offline, high-aesthetics rules, we avoid external resources and keep elements highly functional.

```css
/* Swarm Cockpit Dashboard Styles */

:root {
  --bg-slate-900: #0B0F19;
  --bg-slate-800: #161F30;
  --border-slate-700: #24324D;
  --text-slate-100: #F3F4F6;
  --text-slate-400: #9CA3AF;
  
  --color-pass: #10B981;
  --color-fail: #EF4444;
  --color-warn: #F59E0B;
  --color-run: #8B5CF6;
  
  --accent-gradient: linear-gradient(135deg, #8B5CF6 0%, #6366F1 100%);
  --radius-op: 8px;
}

.swarm-container {
  display: flex;
  flex-direction: column;
  gap: 16px;
  padding: 16px;
  background-color: var(--bg-slate-900);
  color: var(--text-slate-100);
}

.swarm-header-card {
  background-color: var(--bg-slate-800);
  border: 1px solid var(--border-slate-700);
  border-radius: var(--radius-op);
  padding: 16px;
  display: flex;
  flex-direction: column;
  gap: 16px;
}

.run-branch-badge {
  background-color: var(--border-slate-700);
  padding: 4px 8px;
  border-radius: 4px;
  font-size: 0.85rem;
}

/* Progress bar */
.progress-bar-container {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.progress-labels {
  display: flex;
  justify-content: space-between;
  font-size: 0.9rem;
}
.progress-track {
  height: 8px;
  background-color: var(--bg-slate-900);
  border-radius: 4px;
  overflow: hidden;
}
.progress-fill {
  height: 100%;
  border-radius: 4px;
  transition: width 0.4s ease-out;
}

/* Grid Layout */
.swarm-grid {
  display: grid;
  grid-template-columns: 1fr 1.2fr;
  gap: 16px;
}

@media (max-width: 1024px) {
  .swarm-grid {
    grid-template-columns: 1fr;
  }
}

.card-outline {
  background-color: var(--bg-slate-800);
  border: 1px solid var(--border-slate-700);
  border-radius: var(--radius-op);
  padding: 16px;
}

.card-title {
  margin-top: 0;
  margin-bottom: 16px;
  border-bottom: 1px solid var(--border-slate-700);
  padding-bottom: 8px;
  font-weight: 600;
}

/* Worker List */
.worker-list {
  list-style: none;
  padding: 0;
  margin: 0;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.worker-item {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 10px 12px;
  border-radius: 6px;
  border: 1px solid transparent;
  background-color: var(--bg-slate-900);
  cursor: pointer;
  transition: all 150ms ease-in-out;
}

.worker-item:hover {
  border-color: var(--border-slate-700);
  background-color: rgba(36, 50, 77, 0.3);
}

.worker-item.selected {
  border-color: var(--color-run);
  background-color: rgba(139, 92, 246, 0.1);
}

.worker-status-badge {
  width: 24px;
  height: 24px;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  font-weight: bold;
  font-size: 0.8rem;
}

.worker-status-badge.passed { background-color: rgba(16, 185, 129, 0.2); color: var(--color-pass); }
.worker-status-badge.failed { background-color: rgba(239, 68, 68, 0.2); color: var(--color-fail); }
.worker-status-badge.running { background-color: rgba(139, 92, 246, 0.2); color: var(--color-run); }
.worker-status-badge.queued { background-color: rgba(156, 163, 175, 0.2); color: var(--text-slate-400); }

/* Pulses for running tasks */
@keyframes pulse-violet {
  0%, 100% { opacity: 0.6; }
  50% { opacity: 1; transform: scale(1.02); }
}

.active-pulse {
  animation: pulse-violet 2s infinite ease-in-out;
}

/* Terminal Console styling */
.terminal-log {
  background-color: #05070B;
  color: #10B981;
  padding: 12px;
  border-radius: 6px;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 0.85rem;
  max-height: 400px;
  overflow-y: auto;
  border: 1px solid var(--border-slate-700);
  white-space: pre-wrap;
}

.console-metadata {
  background-color: var(--bg-slate-900);
  border: 1px solid var(--border-slate-700);
  border-radius: 6px;
  padding: 12px;
  margin-bottom: 12px;
  font-size: 0.85rem;
}
.console-metadata p {
  margin: 4px 0;
}
```

---

## 5. UI/UX integration slices (Design Rollout)

To deliver this interface incrementally alongside Codex's V1–V5 implementation layers, we split the front-end rollout into three focused slices:

### Slice UI-1: Basic Swarm telemetry tables (Aligned with Codex V3)
* **Goal**: Enable basic visibility of verification metadata in the existing run list template.
* **UX Deliverable**:
  - Extend the run-details view on `/runs/<run-id>` to show a summary row for tasks carrying a `verify` block.
  - Render an Inline SVG checkmark icon for `verified` and a warning icon for `unverified` (legacy) tasks.
  - Implement a scrollable diff block next to the task summary showing the verification output excerpt in a styled code snippet.
* **Accessibility**: Verify color contrast passes WCAG AA on background panels.

### Slice UI-2: Live Swarm HUD Partial via HTMX (Aligned with Codex V5)
* **Goal**: Introduce the live `swarm_activity.html` partial and support real-time execution monitoring.
* **UX Deliverable**:
  - Create the endpoint `/runs/<run-id>/swarm` displaying the full layout in section 3.
  - Hook HTMX polling to update the progress bar and active worker statuses every 2 seconds.
  - Render terminal log streams inside the console panel with autoscroll.
  - Support clicking a worker item to load its current output without reloading the parent page.
* **Performance**: Restrict log content updates to a maximum of 50KB to protect browser memory.

### Slice UI-3: The Scoreboard Dashboard and Auditing View
* **Goal**: Provide the model routing scoreboard natively in the UI, replacing Ringer's `./ringer.py models` visual view.
* **UX Deliverable**:
  - Add a "Routing Insights" tab to the dashboard global navigation.
  - Render a clean bar chart (using the vendored Chart.js) visualizing **First-Try Pass Rate vs Rescued-Pass Rate** by model and task type.
  - Provide a "Rookie Audit Board" section listing cheap untested candidates fetched from the OpenRouter local snapshot. Include an affordance to "Audition" (e.g., generate a manifest entry for a model with a single click).
  - No external styling libraries: all colors and layouts follow the local stylesheet.

---

## 6. Verification and Design QA checks

When a UI slice is ready to merge, it must pass a strict manual design QA gate:

1. **Accessibility (a11y)**:
   - Run the dashboard with the browser's "prefers-reduced-motion" setting turned on. Ensure all pulse animations and progress transitions disable gracefully.
   - Run keyboard navigation (Tab-key) through the worker grid. Ensure the focused worker item gains a clear purple ring outline (`outline: 2px solid var(--color-run)`).
2. **Offline Resilience**:
   - Disconnect the system from the internet and load the swarm panel. Ensure no charts clip, icons render correctly, and fonts render using the local sans-serif stack.
3. **Viewport Adaptability**:
   - Check the grid layout at a 390px (mobile) viewport. The list of tasks and the console pane should stack vertically to prevent text overlapping or horizontal site scrolling.

---

## 7. Recommended Grimdex decision mapping

Gemini recommends merging the architectural insights of Codex and Grok into a final Grimdex decision record structured as follows:

> **Title**: Native Verification Contract with Unified Swarm Cockpit Dashboard UI  
> **Chosen Approach**: Codex's Approach A (Baton-native execution contracts to avoid license risk and Windows process friction) combined with Gemini's UI/UX Spec (recreating Ringside's telemetry, progress bars, and log streams natively in Baton's FastAPI web dashboard).  
> **Key Decisions**:
> 1. Use pure argument vectors for verification checks to prevent shell injection.
> 2. Implement the live-updating "Swarm Cockpit" partial in Baton's web app using local HTMX polling.
> 3. Reject external telemetry endpoints; write verified execution outcomes to Baton's local database for unified Chart.js routing insights.
