# BXP - Broker eXchange Parser

## Table of Contents

- [About](#about)
- [Quick start](#quick-start)
- [Supported brokers](#supported-brokers)
- [How to Contribute](#how-to-contribute)
- [Licence](#licence)

## About

BXP is a configuration-driven data pipeline tool written in Zig. It was born from my desire to try vibe coding with Zig language and need converting broker platform exports (CSV, XLSX, JSON) into a unified format for [Wealthfolio](https://wealthfolio.app/) portfolio tracker. Now the situation is a bit messi, every broker has a different export format, different columns, different conventions - and manual adjustments in a spreadsheet are time-consuming and error-prone. You can try to invent your own scripts and procedures to get the data you really need, but it doesn't always end in success.

BXP solves this problem differently than most tools or scripts. Instead of a hard-coded parser for each broker, it uses **declarative configuration** in a fully supported [**JSON5 format**](https://json5.org/) (a superset of JSON - comments, trailing commas, unquoted keys) with its own **expression engine**. Adding a new data source
means writing a JSON/JSON5 template - no code, no compilation.

**The expression language currently supports**:

- conditionals **(IF)**
- math **(ABS, ROUND, FLOOR, CEILING)**
- string operations **(REPLACE, SPLIT_PART, TRIM, CONTAINS)**
- price and currency extraction **(PRICE_VALUE, PRICE_CURRENCY)**
- date format conversion **(DATE_CONVERT)**
- identifier mapping **(TICKER)**
- cross-row lookup tables **(LOOKUP)** for pairing
related rows

Inputs and outputs can be CSV, XLSX, or JSON - BXP is not limited to
one-directional conversion. The architecture is two-pass: the first pass
(pre_pass) builds a lookup map from selected rows, the second pass performs transformation and routing - a single input row can generate 0, 1, or N output rows based on rules (row_rules).
Output complies with the [**RFC 4180**](https://www.rfc-editor.org/rfc/rfc4180) standard and basic protection against formula injection.

But here is the key point: ***BXP no longer just looks like broker export converter.*** The combination of a generic expression engine, JSON5-driven configuration, and a two-pass pipeline makes it a universal [**ETL micro-tool**](https://w.wiki/32mw). The project is open-source and welcomes contributions from the community - whether it's new conversion templates, extending the expression engine with new functions or adding support for additional input/output formats or you just want to try vibe code in Zig language.

**Future directions BXP can take with community help**:

- **Bank statement normalization** - unifying exports from different banks into a single standard for accounting software or tax returns
- **E-commerce data transformation** - converting orders/invoices between platforms (Shopify JSON --> internal ERP CSV, WooCommerce export --> accounting)
- **Data migration** - reformatting CSV, XLSX, or JSON dumps when switching between systems (CRM, helpdesk, issue tracker) without writing throwaway scripts
- **IoT / sensor data** - remapping columns and units from JSON API sensor platforms into a unified format for visualization or archiving
- **Compliance reporting** - extracting and transforming data from various sources into a regulatory-required format (MiFID II, EMIR)

BXP is a single binary with no external dependencies. Thanks to Zig cross-compilation, currently it runs on Linux, macOS, Windows.
And if needed other platforms supported by the Zig toolchain. Configuration is human-readable, version-controllable, and shareable between users. No Python, no Docker, no runtime dependencies - just a binary and JSON5.

An important aspect: thanks to the declarative nature of the configuration, users
can create their own conversion templates with the help of an AI assistant
(ChatGPT, Claude, etc.) - just describe the input format and the desired output.
Data never leaves the machine, everything runs locally. No cloud, no API keys,
no sending sensitive financial data to third parties.

## Quick start

Download last package from [`releases`](https://github.com/zaxified/bxp/releases), extract files and run.

or you can build your own binary:

```bash
git clone https://github.com/zaxified/bxp.git
cd ./bxp/bxp-cli
zig build
./zig-out/bin/bxp-cli --help
```

See [`resources/readme.md`](resources/readme.md) for full usage, configuration reference.

## Supported brokers

Revolut X, Trading 212, Anycoin, XTB and more will come soon.

## How to Contribute

We welcome contributions from the community! Specifically, we are looking for new **datasets** ( broker exports / expected results / json templates ) to make this tool better for everyone.

For development documentation see [`docs/devel.md`](docs/devel.md)

---

## Licence

This project is licensed under the **Apache License 2.0**. You are free to use, modify, and distribute the code, even for commercial purposes. See the [LICENSE.md](LICENSE.md) file for details.
