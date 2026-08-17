# HL7 v2 ADT Feed → Patient Roster

[:material-github: View on GitHub](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/hl7-adt-patient-roster){ .md-button }

!!! abstract "What"
    Pull a flat patient roster (MRN, name, birth date, sex) out of a feed
    of HL7 v2 **ADT** messages — keeping only the `PID` segments, splitting the
    `^`-delimited name components, and reformatting the birth date — with no HL7
    parser library.

## Why interesting

HL7 v2 is the messaging standard that runs hospitals, and it is awkward for
tabular tools: a feed is a stream of **pipe-delimited** messages, each a stack
of segments (`MSH`, `EVN`, `PID`, `PV1`, `OBX`, …) on their own lines, with
`^`-delimited sub-components nested inside fields. The patient demographics you
usually want live only in the `PID` segment, scattered among a dozen other
segment types. Extracting them is normally a job for a dedicated HL7 library;
bxp does it as a row filter plus a few field splits.

**Edge cases sourced from.**

- HL7 v2 segment/field structure (pipe field separator, `^` component
  separator, the `PID` segment, XPN name type) is defined by the
  [HL7 v2 standard](https://www.hl7.org/implement/standards/product_brief.cfm?product_id=185).
- Real names carry sub-components: `EVERYMAN&&&&Aniston^ADAM^…` (the family field
  itself has `&`-subcomponents).
- Birth dates appear as bare `YYYYMMDD` _and_ as full timestamps
  (`198808181126+0215`); some patients are born **before 1970**.

**Data source.** Real published HL7 v2 sample messages from
[Microsoft's open-source FHIR-Converter](https://github.com/microsoft/FHIR-Converter)
(`data/SampleData/Hl7v2/ADT-*.hl7`, MIT licence) — a project documenting the
HL7-v2→FHIR conversion problem. The patient values are example data (real PHI
can't be published), but the message files are real published reference
artifacts, not fabricated. (This slice: five messages with distinct patients —
incl. Donald Duck, born 1924.)

## The trick

(see `sample.json`):

- **Headerless input:** `csv_delimiter_in: "|"` makes each segment a row, and
  `csv_header_line: 0` says the file has no header line at all — nothing is
  consumed as column names, so the very first `MSH` segment stays a data row.
  With no header names to look up, fields are addressed positionally with the
  `FIELDS(n)` accessor (`[Name]` in bxp is *always* a by-header lookup, never an
  index).
- **Row filter:** `row_rules` with `when: "FIELDS(1) = 'PID'"` — emit a row only
  for `PID` segments; `MSH`/`EVN`/`PV1`/`OBX`/… produce nothing.
- **Name components:** `SPLIT_PART(FIELDS(6), '^', N)` for family/given, then a
  second `SPLIT_PART(…, '&', 1)` to peel the surname out of its sub-components.
- **Birth date — string slice.** This is a pure `YYYYMMDD`→ISO _reformat_, so
  `LEFT(FIELDS(8),4) & '-' & SUBSTR(FIELDS(8),5,2) & '-' & SUBSTR(FIELDS(8),7,2)`
  does the job directly — no format tokens to get right, no date validation.
  `DATE_CONVERT(FIELDS(8), 'YYYYMMDD', 'YYYY-MM-DD')` works equally well here
  (including the 1924 birth date, and it ignores the trailing time on
  `198808181126+0215` — `DATE_CONVERT` is a pure parse→format reshuffle with no
  lower-year limit); string slicing is shown as the leaner idiom for a
  fixed-width layout.

## At full scale

```bash
bash fetch-full.sh          # downloads every ADT-*.hl7 (~57 messages), concatenated
bxp-cli --config full.json  # one roster row per PID segment (~60)
```

## Final result

A 53-line feed carrying 22 different segment types reduces to the five patient
rows that matter, and the pre-1970 birth date survives intact:

```text
mrn,family,given,dob,sex
PATID1234,EVERYMAN,ADAM,1988-08-18,M
12345,Test,Test,2018-02-05,F
10006579,DUCK,DONALD,1924-10-10,M
MRN12345,Doe,Jane,1978-01-01,F
0000000001,Bixby,Timothy,2008-01-06,M
```

That roster drops straight into a spreadsheet or a master-patient-index load —
no HL7 toolkit, no per-segment bookkeeping.

## Sample data

Run it with `bxp-cli --config ./sample.json --template hl7_adt_patient_roster`:

=== "sample.json (config)"

    ```js
    --8<-- "examples/real-world/hl7-adt-patient-roster/sample.json"
    ```

=== "sample.hl7"

    ```text
    --8<-- "examples/real-world/hl7-adt-patient-roster/sample.hl7"
    ```

**Full-scale &amp; binary files** (run it on the complete dataset): [`fetch-full.sh`](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/hl7-adt-patient-roster/fetch-full.sh) · [`full.json`](https://github.com/zaxified/bxp/tree/master/docs/examples/real-world/hl7-adt-patient-roster/full.json).
