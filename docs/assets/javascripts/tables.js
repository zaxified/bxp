/* Reference-table ergonomics: make Markdown tables sortable (click a header)
   and, for long tables, add a type-to-filter box above them.

   Hooks Material's `document$` observable so it re-runs after every instant
   (SPA) navigation, not just the first full page load. Vanilla DOM + the
   vendored Tablesort global — no framework. */

document$.subscribe(function () {
  // Markdown tables carry no class; Material wraps them in `.md-typeset__table`.
  document.querySelectorAll(".md-typeset table:not([class])").forEach(function (table) {
    if (!table.tHead || !table.tBodies.length) return;
    if (table.dataset.toolsReady === "1") return; // idempotent across re-subscribes
    table.dataset.toolsReady = "1";

    // Click-to-sort on every column.
    if (window.Tablesort) new Tablesort(table);

    var rows = table.tBodies[0].rows;
    if (rows.length < 8) return; // small tables: sort only, skip the filter box

    var wrapper = table.closest(".md-typeset__table") || table;
    var bar = document.createElement("div");
    bar.className = "table-filter";

    var input = document.createElement("input");
    input.type = "search";
    input.placeholder = "Filter " + rows.length + " rows…";
    input.setAttribute("aria-label", "Filter table rows");
    bar.appendChild(input);

    var count = document.createElement("span");
    count.className = "table-filter__count";
    bar.appendChild(count);

    wrapper.parentNode.insertBefore(bar, wrapper);

    input.addEventListener("input", function () {
      var q = input.value.trim().toLowerCase();
      var shown = 0;
      Array.prototype.forEach.call(rows, function (row) {
        var hit = !q || row.textContent.toLowerCase().indexOf(q) !== -1;
        row.hidden = !hit;
        if (hit) shown++;
      });
      count.textContent = q ? shown + " / " + rows.length + " shown" : "";
    });
  });
});
