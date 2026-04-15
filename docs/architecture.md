# BXP - Architecture

> Part of the [developer guide](devel.md).

---

## Bird's-eye View

BXP is a single-binary ETL tool. All broker logic lives in a JSON5 config file -
the binary is a generic engine. The diagram below shows the high-level relationship
between components.

```mermaid
graph TD
    subgraph User["User / CI"]
        CFG["bxp-cli.json
        (JSON5 templates)"]
        DATA["Input files
        (.csv / .xlsx / .json)"]
    end

    subgraph CLI["bxp-cli (binary)"]
        MAIN["main.zig
        arg parsing · dispatch"]
        PIPE["pipeline.zig
        processBroker()"]
    end

    subgraph Core["bxp-core (library)"]
        CSV["csv.zig
        RFC 4180 parser"]
        XLSX["xlsx.zig
        ZIP+XML → CSV"]
        EXPR["expr.zig
        expression evaluator"]
        CFG2["config.zig
        config loader"]
        JSON["json.zig
        JSON array → rows"]
        JSON5["json5.zig
        JSON5 preprocessor"]
    end

    subgraph Ext["External"]
        SUNRISE["sunrise
        date/time library"]
    end

    CFG -->|read| MAIN
    DATA -->|read| PIPE
    MAIN --> CFG2
    MAIN --> PIPE
    PIPE --> CSV
    PIPE --> XLSX
    PIPE --> EXPR
    PIPE --> JSON
    CFG2 --> JSON5
    EXPR --> SUNRISE
    PIPE -->|write| OUT[".csvx output files"]
```

---

## Execution Flow

Step-by-step flow when `bxp-cli` is invoked.

```mermaid
flowchart TD
    START([bxp-cli invoked]) --> ARGS[Parse CLI args
    --config --template --data
    --debug --quiet --fresh]
    ARGS --> LOADCFG[Load bxp-cli.json
    json5.preprocess → std.json]
    LOADCFG --> VALIDATE[Validate all templates
    BrokerConfig.validate]
    VALIDATE --> XLSX_Q{Any templates
    with xlsx_sheet?}
    XLSX_Q -->|yes| XLSX_PASS[xlsxPrePass
    extract sheets → .csv]
    XLSX_Q -->|no| SELECT
    XLSX_PASS --> SELECT{--template
    specified?}
    SELECT -->|yes| ONE[processBroker
    for selected template]
    SELECT -->|no| ALL[processBroker
    for every template]
    ONE --> SUMMARY
    ALL --> SUMMARY[Print overall summary]
    SUMMARY --> EXIT{warnings?}
    EXIT -->|yes| CODE2([exit 2])
    EXIT -->|no| CODE0([exit 0])

    LOADCFG -->|file missing
    or parse error| FATAL([exit 1])
    VALIDATE -->|invalid config| FATAL
    XLSX_PASS -->|fatal error| FATAL
```

---

## Per-File Processing (processBroker)

For each input file matched by `file_pattern_in`:

```mermaid
flowchart TD
    FILE([Input file]) --> FRESH{--fresh
    and output exists?}
    FRESH -->|skip| NEXT([next file])
    FRESH -->|continue| DETECT{File type?}
    DETECT -->|.csv| CSV_READ[csv.splitRecords
    csv.splitFields]
    DETECT -->|.json| JSON_READ[json.readJsonRecords]
    CSV_READ --> PREPASS
    JSON_READ --> PREPASS

    PREPASS{pre_pass
    defined?}
    PREPASS -->|yes| PP[Pre-pass scan
    build lookup table
    LOOKUP key → values]
    PREPASS -->|no| MAINLOOP
    PP --> MAINLOOP

    MAINLOOP[Main loop - per row]
    MAINLOOP --> SCHEMA[Evaluate input_schema
    expr.evalString per $variable]
    SCHEMA --> RULES[Match row_rules
    first matching 'when' wins]
    RULES -->|rows: empty| SKIP[Skip row silently]
    RULES -->|rows: N entries| EMIT[Emit N output rows
    render output_schema]
    SKIP --> MAINLOOP
    EMIT --> MAINLOOP
    MAINLOOP -->|done| WRITE[Write .csvx
    RFC 4180 output]
    WRITE --> STATS[Update SectionStats
    warnings / empty_csv]
```

---

## Two-Pass Pipeline Detail

The `pre_pass` mechanism enables **cross-row lookups** - values from one row
can be referenced when processing a different row.

```mermaid
sequenceDiagram
    participant F as Input file
    participant PP as pre_pass
    participant LT as LookupTable
    participant ML as Main loop
    participant OUT as Output

    Note over F,OUT: Pass 1 - build lookup table

    loop Every row in file
        F->>PP: raw field values
        PP->>PP: evaluate 'when' condition
        alt row matches
            PP->>PP: evaluate 'key' expression
            PP->>PP: evaluate 'values' expressions
            PP->>LT: store key → {field: value, ...}
        end
    end

    Note over F,OUT: Pass 2 - transform rows

    loop Every row in file
        F->>ML: raw field values
        ML->>ML: evaluate input_schema ($variables)
        Note right of ML: LOOKUP(key_expr, 'field') reads from LookupTable
        ML->>LT: LOOKUP(key, 'field')
        LT-->>ML: stored value
        ML->>ML: match row_rules → $action
        ML->>OUT: render output_schema columns
    end
```

**Example use case (AnyCoin):** A `trade payment` row holds the currency; a `trade fill`
row holds the ticker and quantity. Both share an `Order ID`. `pre_pass` indexes payment
rows by `Order ID`; the main loop uses `LOOKUP([Order ID], 'currency')` when processing
fill rows.

---

## Expression Evaluator - Call Stack

```mermaid
graph TD
    CALL["expr.eval(expr_string, ctx)"]
    CALL --> ES["evalString()
    coerces Value → string"]
    CALL --> EV["eval()
    returns Value"]
    EV --> PARSE["Parser
    recursive descent"]
    PARSE --> OR["parseOr"]
    OR --> AND["parseAnd"]
    AND --> CMP["parseCmp
    = != < > <= >="]
    CMP --> ADD["parseAdd
    + - &"]
    ADD --> MUL["parseMul
    * /"]
    MUL --> UNARY["parseUnary
    unary -"]
    UNARY --> ATOM["parseAtom"]
    ATOM --> LIT["string / number literal"]
    ATOM --> FIELD["[ColumnName] / [n]"]
    ATOM --> FUNC["function call
    IF, DATE_CONVERT,
    PRICE_VALUE, TICKER,
    LOOKUP, SPLIT_PART,
    CONTAINS, REPLACE,
    TRIM, ROUND, ..."]
    FUNC --> SUNRISE_CALL["sunrise
    (DATE_CONVERT only)"]
```

---

## Data Structures

```mermaid
classDiagram
    class Config {
        +brokers: StringArrayHashMap~BrokerConfig~
        +ticker_maps: StringHashMap~TickerMap~
        +deinit()
    }

    class BrokerConfig {
        +data_dir: string
        +file_pattern_in: string
        +file_pattern_out: ?string
        +date_filter_from_filename: bool
        +ticker_map: TickerMap
        +xlsx_sheet: ?XlsxSheet
        +pre_pass: ?PrePass
        +input_schema: StringArrayHashMap~string~
        +row_rules: []RowRule
        +output_schema: StringArrayHashMap~string~
        +validate(id, writer)
    }

    class PrePass {
        +when: string
        +key: string
        +values: StringHashMap~string~
    }

    class RowRule {
        +when: string
        +rows: []StringHashMap~string~
    }

    class XlsxSheet {
        +name: string
        +header_row: u32
        +output_suffix: string
    }

    class Value {
        +number: f64
        +string: []const u8
        +boolean: bool
    }

    class Context {
        +fields: [][]const u8
        +col_index: StringHashMap~usize~
        +ticker_map: StringHashMap~string~
        +lookup_table: ?*LookupTable
        +alloc: Allocator
        +decimal_sep_in: u8
        +quote_out: u8
    }

    Config "1" *-- "many" BrokerConfig
    BrokerConfig "1" *-- "0..1" PrePass
    BrokerConfig "1" *-- "many" RowRule
    BrokerConfig "1" *-- "0..1" XlsxSheet
    Context --> Value : eval returns
```
