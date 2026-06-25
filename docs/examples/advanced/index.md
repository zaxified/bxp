# Teaching — advanced

Synthetic multi-pass pipelines, joins, and capstones.

<div class="grid cards" markdown>

-   **[Free-Text Payment Memos → Structured References](freeform-payment-memos/index.md)**

    Pull the structured tokens a downstream ledger needs — an invoice number, an order reference, a has-any-reference flag — out of **free-text** payment memos, where each token sits at a _variable_ position inside an otherwise human-written sentence.

-   **[Messy Financial Export → Clean Transactions (combined)](messy-financial-export/index.md)**

    Take one realistically messy brokerage/ERP transaction export and clean **six** things at once in a single template: US date → ISO, transaction-code → label, accounting negatives → signed amount, currency-symbol price → number + currency, percent/bps fee → fraction, and null-variant notes → empty.

-   **[Mixed-Format Bridge (CSV batch + JSON batch → one dataset)](mixed-format-bridge/index.md)**

    Combine records that arrive in **two different file formats** — an old CSV batch and a new JSON batch of the same kind of data — into one unified table.

-   **[Multi-Stage ETL — chained two-hop JOIN + DST timezone (capstone)](multi-stage-etl/index.md)**

    A transitive (two-hop) JOIN that no single pass can do — order → product → category → name — chained across passes, while normalising three different date formats and bridging CSV ↔ JSON, finishing with a DST-aware Europe/Prague timestamp.

-   **[Two-File Keyed JOIN (concat + pre_pass + LOOKUP)](two-file-join/index.md)**

    Enrich a fact table that carries only a foreign key (orders → `customer_id`) with the human details from a separate dimension table (customers → `name`, `city`) — a real relational JOIN across two sources.

-   **[Vintage Harmonisation (one source, format drifted over time)](vintage-harmonise/index.md)**

    Fold several **vintages of the same source** — a broker export whose column names, date format and number format changed over the years — into one consistent table.

-   **[XLSX Tabs → One Long Table (sheet per period)](xlsx-tabs-merge/index.md)**

    Flatten an Excel workbook that keeps **one tab per period** (January / February / March) into a single long table with a `month` column.

</div>
