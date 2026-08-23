/**
 * Cockpit grid — live tails + click a factory-floor card to load that project.
 */
(function () {
  let wsHandle = null;

  window.BatonPickProject = function (id) {
    if (!id) return;
    window.__batonWantedProject = id;
    try {
      const url = new URL(window.location.href);
      url.searchParams.set("project", id);
      history.replaceState({}, "", url.pathname + url.search + url.hash);
    } catch (e) {
      /* ignore */
    }
    const select = document.getElementById("maestro-project");
    const root = document.getElementById("maestro-compose");
    if (select) {
      select.value = id;
      if (root) {
        root.querySelectorAll("[data-maestro-project]").forEach(function (el) {
          const on = el.getAttribute("data-maestro-project") === id;
          el.setAttribute("aria-pressed", on ? "true" : "false");
        });
      }
    }
    const card = document.getElementById("maestro-compose-card");
    if (card) card.scrollIntoView({ behavior: "smooth", block: "start" });
  };

  document.addEventListener("click", function (ev) {
    const skip = ev.target.closest("details, summary, a, button, input, select, textarea, form");
    if (skip) return;
    const cell = ev.target.closest(".cockpit-cell[data-project-id]");
    if (!cell) return;
    ev.preventDefault();
    window.BatonPickProject(cell.getAttribute("data-project-id"));
  });

  document.addEventListener("keydown", function (ev) {
    if (ev.key !== "Enter" && ev.key !== " ") return;
    const cell = ev.target.closest && ev.target.closest(".cockpit-cell[data-project-id]");
    if (!cell || ev.target !== cell) return;
    ev.preventDefault();
    window.BatonPickProject(cell.getAttribute("data-project-id"));
  });

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

    function renderTurns(turns) {
      if (!turns || !turns.length) {
        return '<p class="muted cockpit-cell__empty">— waiting for activity —</p>';
      }
      return (
        '<div class="cockpit-cell__turns">' +
        turns
          .slice(-6)
          .map(function (t) {
            const open = t.collapsed ? "" : " open";
            return (
              '<details class="turn turn--' +
              esc(t.kind) +
              '"' +
              open +
              "><summary>" +
              esc(t.kind) +
              " · " +
              esc(t.label) +
              "</summary><pre>" +
              esc(t.detail) +
              "</pre></details>"
            );
          })
          .join("") +
        "</div>"
      );
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
          const goal = cell.goal
            ? '<p class="cockpit-cell__goal">' + esc(cell.goal) + "</p>"
            : "";
          const output = cell.last_output
            ? '<p class="cockpit-cell__output">' + esc(cell.last_output) + "</p>"
            : "";
          return (
            '<article class="cockpit-cell status-' +
            esc(cell.status) +
            live +
            '" data-project-id="' +
            esc(cell.project_id) +
            '" role="link" tabindex="0" title="Open ' +
            esc(cell.name) +
            ' in the front door">' +
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
            '<p class="cockpit-cell__jump"><a href="/?project=' +
            encodeURIComponent(cell.project_id) +
            '#maestro-compose-card" data-project-id="' +
            esc(cell.project_id) +
            '">Open in front door</a></p>' +
            goal +
            '<dl class="cockpit-cell__meta">' +
            meta.join("") +
            "</dl>" +
            output +
            renderTurns(cell.turns) +
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
