/* BXP docs playground — run the real expression engine in the reader's browser.
 *
 * The `.wasm` this loads is bxp-core compiled for wasm32-freestanding
 * (bxp-core/src/wasm.zig → inspect.evalBatchIo), i.e. the SAME evaluator behind
 * bxp-cli, bxp-mcp's `bxp_eval_batch` and the GUI bridge. Nothing here
 * reimplements expression semantics: this file only marshals rows in and
 * renders results out. If the page and the CLI ever disagree, that is a bug in
 * the marshalling, not two engines drifting.
 *
 * Scope is deliberately ONE expression at a time. A full config runner was
 * considered and dropped: reproducing bxp-cli in the browser would mean
 * reimplementing rule selection, variable merging and CSV serialisation in
 * JavaScript — bxp semantics written a second time, in a language that cannot
 * share the first. `bxp-cli` is the runner; this is the thing that makes a
 * documented formula legible.
 *
 * Two ways to reach it, one panel:
 *
 *   generated reference   `<button class="bxp-try" data-bxp-expr="…">`
 *                         (docs.zig writeFunctionsMd — raw catalog source in
 *                         the attribute, since the visible text is highlighted)
 *
 *   hand-written pages    attr_list on an inline code span:
 *                         `` `PRICE_VALUE([Price])`{.bxp-try} ``
 *
 * A page that also marks its sample CSV — ```{.csv .bxp-sample} — gets the
 * expression evaluated against that data: the first row inline, and every row
 * behind "show all".
 */
(function () {
  'use strict';

  // Resolved from this file's own URL rather than hardcoded: the site is served
  // from `/` under `mkdocs serve` but from `/bxp/` on GitHub Pages, so an
  // absolute path would work in exactly one of the two.
  var WASM_URL = new URL('../wasm/bxp-eval.wasm', document.currentScript.src).href;
  var MAX_ROWS = 200; // a teaching sample, not a dataset viewer
  var DEBOUNCE_MS = 120;

  // ── wasm module ────────────────────────────────────────────────────────────
  // One instance per page load, fetched on first use so a reader who never
  // clicks an expression never downloads it.
  var enginePromise = null;
  var exportsOf = null;
  var encoder = new TextEncoder();
  var decoder = new TextDecoder();

  function engine() {
    if (enginePromise) return enginePromise;
    var imports = {
      env: {
        // The two things the evaluator asks the host for: a wall clock (NOW)
        // and CSPRNG entropy (RAND). See the browser-io note in wasm.zig.
        js_now_ms: function () { return Date.now(); },
        js_random_bytes: function (ptr, len) {
          crypto.getRandomValues(new Uint8Array(exportsOf.memory.buffer, ptr, len));
        },
      },
    };
    // `instantiateStreaming` insists on a Content-Type of `application/wasm`.
    // GitHub Pages sends it; not every dev server does, and there the streaming
    // call rejects on a file that is perfectly valid. Fall back to buffering so
    // the widget cannot be "broken locally, fine in production".
    // `no-cache` = revalidate, not "don't cache": the browser still keeps the
    // bytes and still gets a cheap 304 when they are unchanged. The asset has a
    // fixed name and no version in it, so without this a reader who visited
    // before a rebuild could keep running the previous engine against the new
    // pages — the one way this feature can silently disagree with its docs.
    enginePromise = fetch(WASM_URL, { cache: 'no-cache' })
      .then(function (res) {
        if (!res.ok) throw new Error('HTTP ' + res.status);
        if ((res.headers.get('content-type') || '').indexOf('application/wasm') === 0) {
          return WebAssembly.instantiateStreaming(Promise.resolve(res), imports);
        }
        return res.arrayBuffer().then(function (buf) {
          return WebAssembly.instantiate(buf, imports);
        });
      })
      .then(function (res) {
        exportsOf = res.instance.exports;
        return exportsOf;
      });
    return enginePromise;
  }

  /* Evaluate `exprs` against one row. Returns the engine's own per-expression
   * result objects ({ok:true,value} | {ok:false,error,detail,off?,len?}).
   *
   * Every typed array is built fresh against `memory.buffer`: a wasm allocation
   * can grow linear memory, which DETACHES any view taken before it. */
  function evalRow(ex, headers, fields, exprs) {
    var body = encoder.encode(JSON.stringify({
      headers: headers, fields: fields, exprs: exprs,
    }));
    var ptr = ex.bxp_input_alloc(body.length);
    if (ptr === 0) throw new Error('out of memory');
    new Uint8Array(ex.memory.buffer, ptr, body.length).set(body);

    var rc = ex.bxp_eval_batch(body.length);
    var out = decoder.decode(
      new Uint8Array(ex.memory.buffer, ex.bxp_result_ptr(), ex.bxp_result_len())
    );
    if (rc !== 0) throw new Error(out);
    return JSON.parse(out).results;
  }

  /* `{FUNCTION_NAME: "fields"|"source"|"prepass"}` for the builtins that need
   * context a standalone expression cannot supply — read out of the engine's
   * own catalog (`FnDoc.needs` via inspect.docsJson), not out of the page, so
   * the hint works on hand-written pages as well as the generated reference.
   * Cached: the catalog is fixed for a given build. */
  var needsCache = null;

  function fnNeeds(ex) {
    if (needsCache) return needsCache;
    needsCache = {};
    try {
      if (ex.bxp_docs() === 0) {
        var doc = JSON.parse(decoder.decode(
          new Uint8Array(ex.memory.buffer, ex.bxp_result_ptr(), ex.bxp_result_len())
        ));
        (doc.functions || []).forEach(function (f) {
          if (f.needs && f.needs !== 'none') needsCache[f.name] = f.needs;
        });
      }
    } catch (e) {
      // A catalog we cannot read costs a hint, never a result — leave it empty.
    }
    return needsCache;
  }

  // ── CSV ────────────────────────────────────────────────────────────────────
  /* Deliberately mirrors bxp's lazy-quotes rule rather than RFC 4180 §2.6: a
   * '\n' ALWAYS ends a record, even inside an open quote. That is what keeps a
   * stray quote a one-line problem in the engine, and the page has to agree
   * with it or a malformed sample would read differently here than it converts.
   * Field values are NOT trimmed — the engine trims at access time
   * (expr.Context.field); header names ARE, matching the pipeline's col_index. */
  function parseCsv(text, delim) {
    var records = [];
    var field = '';
    var record = [];
    var inQuotes = false;

    for (var i = 0; i < text.length; i++) {
      var c = text[i];
      if (c === '\r') continue;
      if (c === '\n') {
        record.push(field);
        records.push(record);
        field = '';
        record = [];
        inQuotes = false; // the lazy-quotes rule
        continue;
      }
      if (inQuotes) {
        if (c === '"') {
          if (text[i + 1] === '"') { field += '"'; i++; } else { inQuotes = false; }
        } else {
          field += c;
        }
        continue;
      }
      if (c === '"' && field === '') { inQuotes = true; continue; }
      if (c === delim) { record.push(field); field = ''; continue; }
      field += c;
    }
    if (field !== '' || record.length) { record.push(field); records.push(record); }
    return records.filter(function (r) { return r.length > 1 || r[0] !== ''; });
  }

  /* Examples are not all comma-separated: `csv_delimiter_in` is a per-template
   * setting and the tree ships semicolon, pipe and tab samples. A page whose
   * sample is not comma-separated says so on the fence —
   * ```{.csv .bxp-sample data-delim="\t"} — copied from its own sample.json.
   *
   * Sniffing was tried first and rejected. Eurostat's TSV has comma-separated
   * key columns followed by tab-separated period columns, so "whichever
   * delimiter yields more fields" confidently picks the wrong one, and the
   * panel then shows plausible values that are not the ones bxp-cli produces —
   * a worse failure than showing nothing. An explicit declaration cannot be
   * confidently wrong; if a page forgets it, column references come back empty,
   * which is visible. */
  function sampleDelimiter(node) {
    var d = node.getAttribute('data-delim');
    if (!d) return ',';
    return d === '\\t' ? '\t' : d;
  }

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined) n.textContent = text;
    return n;
  }

  // ── the panel ──────────────────────────────────────────────────────────────
  var pad = null;

  /* Sample data the page offers, or null. Read from the CSV block the page
   * already displays (```{.csv .bxp-sample}) rather than from a second hidden
   * copy: the reader sees exactly the rows the expression runs against. */
  var sample = null;

  function scratchpad() {
    if (pad) return pad;

    var root = el('div', 'bxp-scratch');
    // Non-modal by design: the page stays readable and usable behind it, so
    // `aria-modal` is deliberately absent. It still needs a name and a role, or
    // a screen reader meets an unlabelled div that appeared from nowhere.
    root.setAttribute('role', 'dialog');
    root.setAttribute('aria-label', 'Expression scratchpad');

    var bar = el('div', 'bxp-scratch-bar');
    var title = el('span', 'bxp-scratch-title');
    bar.appendChild(title);
    var allBtn = el('button', 'bxp-scratch-all');
    allBtn.type = 'button';
    if (sample) bar.appendChild(allBtn);
    var close = el('button', 'bxp-scratch-close', '×');
    close.type = 'button';
    close.setAttribute('aria-label', 'close');
    bar.appendChild(close);
    root.appendChild(bar);

    var row = el('div', 'bxp-scratch-row');
    var input = el('input', 'bxp-pg-input');
    input.type = 'text';
    input.spellcheck = false;
    input.setAttribute('aria-label', 'expression to evaluate');
    var arrow = el('span', 'bxp-scratch-arrow', '→');
    var out = el('span', 'bxp-scratch-value');
    row.appendChild(input);
    row.appendChild(arrow);
    row.appendChild(out);
    root.appendChild(row);

    var note = el('div', 'bxp-scratch-note');
    root.appendChild(note);
    var table = el('div', 'bxp-scratch-table');
    root.appendChild(table);
    // The result is the whole point of the panel and it changes without any
    // navigation, so announce it. `polite` because it re-renders on every
    // keystroke — `assertive` would talk over the reader as they type.
    var live = el('div', 'bxp-scratch-live');
    live.setAttribute('role', 'status');
    live.setAttribute('aria-live', 'polite');
    root.appendChild(live);
    document.body.appendChild(root);

    var showAll = false;
    var opener = null;   // trigger to restore focus to on close

    var NEEDS_TEXT = {
      fields: 'needs a row — this page evaluates against none, so field access ' +
              'returns "". In a template it reads the row being converted.',
      source: 'needs the source file — file name, sheet and record position are ' +
              'not part of a standalone evaluation, so this answers ""/0 here. ' +
              'In a conversion it returns the real value.',
      prepass: 'needs a pre_pass table — there is none here, so the lookup finds ' +
               'nothing. In a template it returns the stored value.',
    };

    /* Word-boundary match on the call, so `LOOKUPS_TOTAL` or a quoted
     * 'FILENAME' string does not trigger the hint. */
    function missingContext(src) {
      var needs = fnNeeds(exportsOf);
      for (var name in needs) {
        // `fields` is satisfiable: with a sample row FIELDS returns a real
        // value and there is nothing to explain.
        if (needs[name] === 'fields' && sample) continue;
        if (new RegExp('(^|[^A-Za-z0-9_])' + name + '\\s*\\(', 'i').test(src)) return needs[name];
      }
      return null;
    }

    function renderValue(node, r) {
      if (r.ok) {
        if (r.value === '') {
          node.textContent = '∅  (empty)';
          node.className = 'bxp-scratch-value bxp-scratch-value--empty';
        } else {
          node.textContent = r.value;
          node.className = 'bxp-scratch-value';
        }
      } else {
        node.textContent = r.detail || r.error;
        node.className = 'bxp-scratch-value bxp-scratch-value--bad';
      }
    }

    function runOne(src) {
      var r = evalRow(
        exportsOf,
        sample ? sample.headers : [],
        sample ? sample.rows[0] : [],
        [src]
      )[0];
      renderValue(out, r);
      title.textContent = sample
        ? 'Scratchpad · row 1 of ' + sample.rows.length
        : 'Scratchpad · no row';
    }

    /* Every row of the sample against one expression. The input columns come
     * along so the mapping is readable as "this row in, that value out" — the
     * whole reason a reader opens this instead of trusting the prose. */
    function runAll(src) {
      var t = el('table', 'bxp-pg-table');
      var thead = el('thead');
      var htr = el('tr');
      sample.headers.forEach(function (h) { htr.appendChild(el('th', null, h)); });
      htr.appendChild(el('th', 'bxp-scratch-outcol', '→ result'));
      thead.appendChild(htr);
      t.appendChild(thead);

      var tbody = el('tbody');
      sample.rows.forEach(function (fields) {
        var r = evalRow(exportsOf, sample.headers, fields, [src])[0];
        var tr = el('tr');
        sample.headers.forEach(function (_, i) {
          tr.appendChild(el('td', null, fields[i] === undefined || fields[i] === ''
            ? '∅' : fields[i]));
        });
        var td = el('td', 'bxp-scratch-outcol');
        var span = el('span');
        renderValue(span, r);
        td.appendChild(span);
        tr.appendChild(td);
        tbody.appendChild(tr);
      });
      t.appendChild(tbody);

      var wrap = el('div', 'bxp-pg-scroll');
      wrap.appendChild(t);
      table.textContent = '';
      table.appendChild(wrap);
      title.textContent = 'Scratchpad · all ' + sample.rows.length + ' rows';
    }

    function run() {
      if (!exportsOf) return;
      var src = input.value;
      note.textContent = '';
      table.textContent = '';
      if (!src.trim()) {
        out.textContent = '';
        out.className = 'bxp-scratch-value';
        return;
      }
      try {
        if (showAll && sample) {
          out.textContent = '';
          out.className = 'bxp-scratch-value';
          runAll(src);
        } else {
          runOne(src);
        }
      } catch (err) {
        out.textContent = err.message;
        out.className = 'bxp-scratch-value bxp-scratch-value--bad';
        return;
      }
      var why = missingContext(src);
      if (why) note.textContent = NEEDS_TEXT[why];
      live.textContent = (showAll && sample)
        ? sample.rows.length + ' rows evaluated'
        : 'Result: ' + out.textContent;
    }

    function syncAllBtn() {
      allBtn.textContent = showAll ? 'show one' : 'show all';
      root.classList.toggle('bxp-scratch--wide', showAll);
    }
    syncAllBtn();

    var timer = null;
    input.addEventListener('input', function () {
      clearTimeout(timer);
      timer = setTimeout(run, DEBOUNCE_MS);
    });
    allBtn.addEventListener('click', function () {
      showAll = !showAll;
      syncAllBtn();
      run();
    });
    /* Closing must hand focus back to whatever opened the panel. Without it
     * focus stays on the input inside a `display:none` subtree, which strands
     * keyboard and screen-reader users at the top of the document. */
    function dismiss() {
      if (!root.classList.contains('bxp-scratch--open')) return;
      root.classList.remove('bxp-scratch--open');
      if (opener && document.contains(opener)) opener.focus();
      opener = null;
    }
    close.addEventListener('click', dismiss);
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') dismiss();
    });

    pad = {
      open: function (expr, trigger) {
        opener = trigger || null;
        root.classList.add('bxp-scratch--open');
        input.value = expr;
        out.textContent = 'loading engine…';
        out.className = 'bxp-scratch-value';
        table.textContent = '';
        note.textContent = '';
        engine().then(function () {
          run();
          input.focus();
          // Focusing parks the caret at the end, which scrolls a long
          // expression so it reads from the middle. Send it back to the start:
          // the reader is here to see the expression, not to append to it.
          input.setSelectionRange(0, 0);
          input.scrollLeft = 0;
        }, function (err) {
          out.textContent = 'could not load the engine: ' + err.message;
          out.className = 'bxp-scratch-value bxp-scratch-value--bad';
        });
      },
    };
    return pad;
  }

  // ── wiring ─────────────────────────────────────────────────────────────────
  function init() {
    // Reset per navigation: instant-navigation swaps the page under us, and a
    // sample carried over from the previous one would silently evaluate the new
    // page's expressions against the old page's data.
    sample = null;
    pad = null;
    var stale = document.querySelector('.bxp-scratch');
    if (stale) stale.remove();

    var csvNode = document.querySelector('.bxp-sample');
    if (csvNode) {
      // textContent, not innerHTML: the block is syntax-highlighted into spans,
      // and their text content is the original CSV byte for byte.
      var raw = csvNode.textContent.replace(/\n+$/, '');
      var recs = parseCsv(raw, sampleDelimiter(csvNode));
      if (recs.length >= 2) {
        sample = {
          headers: recs[0].map(function (h) { return h.trim(); }),
          rows: recs.slice(1, 1 + MAX_ROWS),
        };
      }
    }

    /* Hand-written pages mark an expression clickable with attr_list —
     * `` `UPPER([Item])`{.bxp-try} `` for an inline span, or ```{.text .bxp-try}
     * around the fenced block where the page displays its key expression. The
     * fence form matters: most examples introduce their one central expression
     * as a display block and then explain it line by line underneath, so that
     * block — not a restatement somewhere else — is where a reader wants to
     * click. Neither shape is a <button> (unlike the generated reference), so
     * give both the button semantics they are missing rather than leaving the
     * feature mouse-only. */
    var spans = document.querySelectorAll('code.bxp-try:not([role]), .bxp-try.highlight:not([role])');
    for (var s = 0; s < spans.length; s++) {
      spans[s].setAttribute('role', 'button');
      spans[s].setAttribute('tabindex', '0');
    }

    // One delegated listener rather than one per trigger: the function
    // reference has 57 of them, and instant-navigation replaces them wholesale.
    if (!document.body.dataset.bxpTryReady) {
      document.body.dataset.bxpTryReady = '1';
      var openFrom = function (node) {
        // The generated reference carries the raw catalog source in the
        // attribute (its visible text is syntax-highlighted markup); the
        // attr_list forms are their own plain text.
        var src = node.getAttribute('data-bxp-expr');
        if (!src) {
          // A display block wraps its expression over several lines for
          // readability. Fold only the line break plus its indentation — never
          // runs of spaces, which are significant inside a string literal
          // (`REPLACE(x, '  ', ' ')` must not become `REPLACE(x, ' ', ' ')`).
          src = node.textContent.replace(/\n\s*/g, ' ').trim();
        }
        scratchpad().open(src, node);
      };
      document.body.addEventListener('click', function (e) {
        var t = e.target.closest ? e.target.closest('.bxp-try') : null;
        if (!t) return;
        e.preventDefault();
        openFrom(t);
      });
      document.body.addEventListener('keydown', function (e) {
        if (e.key !== 'Enter' && e.key !== ' ') return;
        var t = e.target.closest ? e.target.closest('code.bxp-try, .bxp-try.highlight') : null;
        if (!t) return;
        e.preventDefault();
        openFrom(t);
      });
    }
  }

  // Material's `navigation.instant` swaps page content without a reload, so
  // one DOMContentLoaded is not enough — `document$` fires on every navigation.
  if (typeof document$ !== 'undefined') {
    document$.subscribe(init);
  } else if (document.readyState !== 'loading') {
    init();
  } else {
    document.addEventListener('DOMContentLoaded', init);
  }
})();
