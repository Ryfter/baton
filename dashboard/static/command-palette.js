(function () {
  var overlay = document.getElementById("command-palette");
  if (!overlay) return;

  var input = document.getElementById("command-palette-input");
  var list = document.getElementById("command-palette-list");
  var hint = document.getElementById("command-palette-hint");
  var projects = [];
  var kbTimer = null;
  var open = false;

  var staticActions = [
    { id: "home", label: "Go to Home", href: "/" },
    { id: "gauges", label: "Open Gauges", href: "/gauges" },
    { id: "machines", label: "Open Machines", href: "/machines" },
    { id: "portfolio", label: "Open Portfolio", href: "/projects" },
    { id: "admit", label: "Focus admit bar", href: "/#maestro-compose-card" },
  ];

  function fetchProjects() {
    return fetch("/api/command-palette")
      .then(function (r) { return r.json(); })
      .then(function (data) {
        projects = data.projects || [];
      })
      .catch(function () { projects = []; });
  }

  function renderItems(items) {
    list.innerHTML = "";
    if (!items.length) {
      var empty = document.createElement("li");
      empty.className = "command-palette__empty muted";
      empty.textContent = "No matches";
      list.appendChild(empty);
      return;
    }
    items.forEach(function (item, idx) {
      var li = document.createElement("li");
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "command-palette__item" + (idx === 0 ? " is-active" : "");
      btn.dataset.href = item.href || "";
      btn.dataset.action = item.action || "";
      btn.innerHTML = "<span class=\"command-palette__label\">" + item.label + "</span>"
        + (item.meta ? "<span class=\"command-palette__meta\">" + item.meta + "</span>" : "");
      btn.addEventListener("click", function () { run(item); });
      li.appendChild(btn);
      list.appendChild(li);
    });
  }

  function filterStatic(q) {
    var needle = (q || "").toLowerCase().trim();
    var rows = staticActions.slice();
    projects.forEach(function (p) {
      rows.push({
        id: "project-" + p.id,
        label: "Open project: " + (p.name || p.id),
        meta: p.id,
        href: "/?project=" + encodeURIComponent(p.id) + "#maestro-compose-card",
      });
    });
    if (!needle) return rows.slice(0, 12);
    return rows.filter(function (r) {
      return (r.label + " " + (r.meta || "")).toLowerCase().indexOf(needle) >= 0;
    }).slice(0, 12);
  }

  function searchKb(q, base) {
    if (!q.trim()) {
      renderItems(base);
      return;
    }
    fetch("/kb/search?q=" + encodeURIComponent(q) + "&k=5")
      .then(function (r) { return r.json(); })
      .then(function (data) {
        var items = base.slice(0, 6);
        (data.hits || []).forEach(function (hit) {
          items.push({
            label: "KB: " + (hit.title || hit.path || hit.id || "hit"),
            meta: hit.path || "",
            href: "/projects",
          });
        });
        renderItems(items.slice(0, 12));
        if (data.error && hint) hint.textContent = data.error;
      })
      .catch(function () { renderItems(base); });
  }

  function run(item) {
    closePalette();
    if (item.href) {
      window.location.href = item.href;
      return;
    }
    if (item.action === "admit") {
      window.location.href = "/#maestro-compose-card";
      setTimeout(function () {
        var goal = document.getElementById("maestro-goal");
        if (goal) goal.focus();
      }, 300);
    }
  }

  function openPalette() {
    open = true;
    overlay.hidden = false;
    overlay.classList.add("is-open");
    document.body.classList.add("command-palette-open");
    if (hint) hint.textContent = "Search projects, KB, or jump to a page";
    fetchProjects().finally(function () {
      if (input) {
        input.value = "";
        input.focus();
        renderItems(filterStatic(""));
      }
    });
  }

  function closePalette() {
    open = false;
    overlay.hidden = true;
    overlay.classList.remove("is-open");
    document.body.classList.remove("command-palette-open");
  }

  function onInput() {
    var q = input ? input.value : "";
    var base = filterStatic(q);
    clearTimeout(kbTimer);
    kbTimer = setTimeout(function () {
      searchKb(q, base);
    }, q.trim() ? 180 : 0);
  }

  document.addEventListener("keydown", function (e) {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
      e.preventDefault();
      if (open) closePalette();
      else openPalette();
      return;
    }
    if (e.key === "Escape" && open) {
      e.preventDefault();
      closePalette();
    }
  });

  overlay.addEventListener("click", function (e) {
    if (e.target === overlay) closePalette();
  });

  if (input) input.addEventListener("input", onInput);

  window.BatonCommandPalette = { open: openPalette, close: closePalette };
})();
