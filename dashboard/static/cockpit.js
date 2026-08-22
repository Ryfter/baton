/**
 * Cockpit grid — WebSocket live tails (OctoAlly-shaped slice 4).
 * Falls back to HTMX poll if WebSocket unavailable.
 */
(function () {
  let wsHandle = null;

  function boot() {
  const root = document.getElementById("cockpit-grid");
  if (!root) return;
  if (wsHandle) return;

  const cellsHost = document.getElementById("cockpit-cells");
  const updatedEl = document.getElementById("cockpit-updated");
  const wsUrl = root.dataset.wsUrl;

  function esc(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function renderCells(cells) {
    if (!cellsHost || !Array.isArray(cells)) return;
    cellsHost.innerHTML = cells
      .map(function (cell) {
        const live = cell.live ? " cockpit-cell--live" : "";
        const meta = [];
        if (cell.job_id) meta.push("<div><dt>job</dt><dd><code>" + esc(cell.job_id) + "</code></dd></div>");
        if (cell.run_id) meta.push("<div><dt>run</dt><dd><code>" + esc(cell.run_id) + "</code></dd></div>");
        if (cell.provider) meta.push("<div><dt>instrument</dt><dd>" + esc(cell.provider) + "</dd></div>");
        if (cell.current_step) meta.push("<div><dt>step</dt><dd>" + esc(cell.current_step) + "</dd></div>");
        const tail = (cell.tail || [])
          .map(function (line) {
            return esc(line);
          })
          .join("\n");
        const goal = cell.goal
          ? '<p class="cockpit-cell__goal">' + esc(cell.goal) + "</p>"
          : "";
        return (
          '<article class="cockpit-cell status-' +
          esc(cell.status) +
          live +
          '" data-project-id="' +
          esc(cell.project_id) +
          '">' +
          '<header class="cockpit-cell__head">' +
          '<span class="cockpit-cell__name">' +
          esc(cell.name) +
          "</span>" +
          '<span class="cockpit-cell__status status-' +
          esc(cell.status) +
          '">' +
          esc(cell.status) +
          "</span>" +
          "</header>" +
          goal +
          '<dl class="cockpit-cell__meta">' +
          meta.join("") +
          "</dl>" +
          '<pre class="cockpit-cell__tail" data-tail>' +
          (tail || '<span class="muted">— waiting for activity —</span>') +
          "</pre>" +
          "</article>"
        );
      })
      .join("");
  }

  function applyPayload(data) {
    if (!data || data.heartbeat) return;
    if (data.updated_at && updatedEl) updatedEl.textContent = data.updated_at;
    const liveEl = root.querySelector(".cockpit-live-count");
    if (liveEl && typeof data.live_count === "number") {
      liveEl.innerHTML = '<span class="pulse-dot"></span> ' + data.live_count + " live";
    }
    renderCells(data.cells);
  }

  function connect() {
    if (!wsUrl || typeof WebSocket === "undefined") return false;
    try {
      const ws = new WebSocket(wsUrl);
      wsHandle = ws;
      ws.onmessage = function (ev) {
        try {
          applyPayload(JSON.parse(ev.data));
        } catch (e) {
          /* ignore */
        }
      };
      ws.onclose = function () {
        wsHandle = null;
        setTimeout(function () {
          boot();
        }, 4000);
      };
      return true;
    } catch (e) {
      return false;
    }
  }

  if (!connect()) {
    // HTMX fallback: poll partial every 3s
    if (typeof htmx !== "undefined") {
      htmx.ajax("GET", "/partials/cockpit-grid", { target: "#cockpit-grid-mount", swap: "innerHTML" });
      setInterval(function () {
        htmx.ajax("GET", "/partials/cockpit-grid", { target: "#cockpit-grid-mount", swap: "innerHTML" });
      }, 3000);
    }
  }
  }

  document.addEventListener("DOMContentLoaded", boot);
  document.body.addEventListener("htmx:afterSwap", function (ev) {
    if (ev.detail && ev.detail.target && ev.detail.target.id === "cockpit-grid-mount") {
      wsHandle = null;
      boot();
    }
  });
})();
