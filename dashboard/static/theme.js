(function () {
  var KEY = "baton-theme";
  var root = document.documentElement;
  var select = document.getElementById("theme-picker");

  function apply(theme) {
    var t = theme || "brass";
    root.setAttribute("data-theme", t);
    try { localStorage.setItem(KEY, t); } catch (e) {}
    if (select && select.value !== t) select.value = t;
  }

  var saved = "brass";
  try { saved = localStorage.getItem(KEY) || "brass"; } catch (e) {}
  apply(saved);

  if (select) {
    select.addEventListener("change", function () {
      apply(select.value);
    });
  }

  window.BatonTheme = { apply: apply };
})();
