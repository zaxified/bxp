# Data Structures

```mermaid
classDiagram
    class Config {
        +brokers: StringArrayHashMap~BrokerConfig~
        +deinit()
    }

    class BrokerConfig {
        +data_dir: string
        +file_pattern_in: string
        +file_pattern_out: ?string
        +date_filter_from_filename: bool
        +combined_output: bool
        +maps: MapRegistry
        +xlsx_sheet: ?XlsxSheet
        +pre_passes: StringArrayHashMap~PrePass~
        +input_schema: StringArrayHashMap~string~
        +row_rules: []RowRule
        +output_schema: StringArrayHashMap~string~
        +validate(id, writer)
    }

    class PrePass {
        +when: string
        +key: string
        +values: StringArrayHashMap~string~
    }

    class Diagnostics {
        +items: ArrayList~Diagnostic~
        +append(diag)
        +count() usize
        +countBySeverity(sev) usize
    }

    class Diagnostic {
        +path: string
        +severity: Severity
        +code: string
        +message: string
        +suggest: ?string
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
        +string: []const u8
        +decimal: Decimal
        +boolean: bool
    }

    class Context {
        +fields: [][]const u8
        +col_index: StringHashMap~usize~
        +maps: ?*MapRegistry
        +lookup_table: ?*LookupTable
        +alloc: Allocator
        +decimal_sep_in: u8
        +quote_out: u8
    }

    class MapRegistry {
        +maps: StringHashMap~NamedMap~
    }

    class NamedMap {
        +entries: StringArrayHashMap~string~
    }

    class LookupTable {
        +map: StringHashMap~string~
    }

    class SectionStats {
        +warnings: u32
        +errors: u32
        +empty_csv: u32
        +elapsed_ns: u64
        +merge(other)
    }

    class SheetSpec {
        +name: string
        +header_row: u32
        +output_suffix: string
    }

    Config "1" *-- "many" BrokerConfig
    BrokerConfig "1" *-- "0..*" PrePass
    BrokerConfig "1" *-- "many" RowRule
    BrokerConfig "1" *-- "0..1" XlsxSheet
    BrokerConfig "1" *-- "1" MapRegistry
    MapRegistry "1" *-- "many" NamedMap
    Context --> Value : eval returns
    Context --> LookupTable : Context.lookup_table
    Context --> MapRegistry : Context.maps
    XlsxSheet ..> SheetSpec : runtime form\nfor xlsx.zig
    Diagnostics "1" *-- "many" Diagnostic
```

`SectionStats` is bxp-cli's per-section accumulator (one per template, plus
a top-level total). Warnings tick the exit code from 0 → 2 even when the run
completes; errors push it to 1.

`LookupTable` is owned by `Context` for the duration of one file's main
loop. The composite key encoding keeps multi-namespace `pre_passes` sharing
one storage map without needing nested structures.

`MapRegistry` is each template's resolved named-map view: the top-level
`maps: { name: { ... } }` registry merged with the template's own `maps` block
(template-local wins on a name collision), built once at config-load time. Each
`NamedMap` preserves JSON key order (`StringArrayHashMap`) so `REPLACE` applies a
map's pairs in declaration order; `REMAP` uses the same map for O(1) whole-value
lookup. `REMAP(s, 'name')` / `REPLACE(s, 'name')` resolve the name against it.
