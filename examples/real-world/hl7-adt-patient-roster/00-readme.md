# HL7 v2 ADT Feed → Patient Roster

[← all examples](../../README.md)

**What.** Pull a flat patient roster (MRN, name, birth date, sex) out of a feed
of HL7 v2 **ADT** messages — keeping only the `PID` segments, splitting the
`^`-delimited name components, and reformatting the birth date — with no HL7
parser library.

**Why interesting.** HL7 v2 is the messaging standard that runs hospitals, and
it is awkward for tabular tools: a feed is a stream of **pipe-delimited**
messages, each a stack of segments (`MSH`, `EVN`, `PID`, `PV1`, `OBX`, …) on
their own lines, with `^`-delimited sub-components nested inside fields. The
patient demographics you usually want live only in the `PID` segment, scattered
among a dozen other segment types. Extracting them is normally a job for a
dedicated HL7 library; bxp does it as a row filter plus a few field splits.

**Edge cases sourced from.**

- HL7 v2 segment/field structure (pipe field separator, `^` component
  separator, the `PID` segment, XPN name type) is defined by the
  [HL7 v2 standard](https://www.hl7.org/implement/standards/product_brief.cfm?product_id=185).
- Real names carry sub-components: `EVERYMAN&&&&Aniston^ADAM^…` (the family field
  itself has `&`-subcomponents).
- Birth dates appear as bare `YYYYMMDD` *and* as full timestamps
  (`198808181126+0215`); some patients are born **before 1970**.

**Data source.** Real published HL7 v2 sample messages from
[Microsoft's open-source FHIR-Converter](https://github.com/microsoft/FHIR-Converter)
(`data/SampleData/Hl7v2/ADT-*.hl7`, MIT licence) — a project documenting the
HL7-v2→FHIR conversion problem. The patient values are example data (real PHI
can't be published), but the message files are real published reference
artifacts, not fabricated. (This slice: five messages with distinct patients —
incl. Donald Duck, born 1924.)

**Run it on the complete file.**

```bash
bash fetch-full.sh          # downloads every ADT-*.hl7 (~57 messages), concatenated
bxp-cli --config full.json  # one roster row per PID segment (~60)
```

**The trick** (see `sample.json`):

- **Row filter:** `row_rules` with `when: "[1] = 'PID'"` — emit a row only for
  `PID` segments; `MSH`/`EVN`/`PV1`/`OBX`/… produce nothing.
- **Name components:** `SPLIT_PART([6], '^', N)` for family/given, then a second
  `SPLIT_PART(…, '&', 1)` to peel the surname out of its sub-components.
- **Birth date — string slice, not `DATE_CONVERT`.** This is a pure
  `YYYYMMDD`→ISO *reformat*, so
  `LEFT([8],4) & '-' & SUBSTR([8],5,2) & '-' & SUBSTR([8],7,2)` is the right
  tool. It also sidesteps a real limitation found while building this example:
  `DATE_CONVERT` silently returns `""` for dates before 1970 (the Unix epoch),
  which would **vanish a 1924 birth date**. String slicing has no such limit.

**Smoking gun.** A 57-line, 20-segment-type message reduces to the one patient row
that matters, and the pre-1970 birth date survives intact:

```text
mrn,family,given,dob,sex
PATID1234,EVERYMAN,ADAM,1988-08-18,M
10006579,DUCK,DONALD,1924-10-10,M
```

That roster drops straight into a spreadsheet or a master-patient-index load —
no HL7 toolkit, no per-segment bookkeeping.
