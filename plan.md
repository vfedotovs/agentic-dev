# Project Plan — esxtop CSV stats & charts

This file is the single source of truth for planned work. The agentic-dev
**slicer** (Stage 1) runs daily, turns each unchecked `- [ ]` item below into a
GitHub issue, and optionally checks the box with a link to the issue it created.

## Conventions

- One action item per line, phrased as an outcome.
- Optional leading `(type)` — one of `feature`, `bug`, `refactor`, `docs`,
  `chore`. Untyped items are classified by the slicer.
- Group related items under a `##` heading; the heading is passed to the agent
  as context (`Heading :: item text`).
- Check the box (`- [x]`) to retire an item. The slicer never re-slices a
  checked item, and fingerprints item text so an edited-but-equivalent line is
  not sliced twice.
- Items typed `docs` / `chore` still become issues, but Stage 2/3 skip them —
  they are left for humans.

## Where we are today

Already working: CSV load and data extraction, chart generation driven by
`Makefile` targets, text output and charts produced **manually, one category at
a time**, and a Docker container that extracts **text only**, and **only** for
VM VMDK stats. The phases below take that container from a single hardcoded
report to full text+chart coverage of every VMDK and device category, then CPU
`%RDY`, on CSV inputs up to 1 GB.

## Phase 1 — All VMDK categories, text min/max/average in the container

- [ ] (feature) The container discovers and lists every VM VMDK stat category present in the loaded CSV instead of the current hardcoded subset
- [ ] (feature) `--list-categories` prints the discovered categories grouped by VM and VMDK, one per line, in a machine-readable form
- [ ] (feature) The text report prints min, max and average for each selected VMDK category
- [ ] (feature) A `make` target runs the container's text-stats report against a CSV mounted from the host
- [ ] (bug) Category matching is case-, whitespace- and punctuation-insensitive so esxtop counter names containing spaces, parentheses and backslashes are not silently dropped
- [ ] (feature) The text report is emitted both as a human-readable table and as CSV/JSON for downstream tooling
- [ ] (feature) Categories with no samples, or with all-empty values, are reported explicitly instead of being omitted from the output

## Phase 2 — Chart for a manually selected category

- [ ] (feature) `--category <name>` renders a time-series chart for one manually selected VMDK category from inside the container
- [ ] (feature) Chart output path, image format (PNG/SVG) and size are configurable from the CLI and from the `Makefile`
- [ ] (feature) Chart axes are labelled with the counter name and its unit, and the x-axis is driven by the CSV timestamp column
- [ ] (feature) A single invocation produces both the chart and the min/max/average text block for the selected category
- [ ] (bug) Selecting a category that does not exist exits non-zero and prints the closest matching category names instead of writing an empty chart
- [ ] (feature) Min, max and average are drawn on the chart as annotated reference lines

## Phase 3 — Full coverage: text + chart for every VMDK and device category

- [ ] (feature) One command produces the min/max/average text block **and** a chart for every VMDK category of every VM in the CSV
- [ ] (feature) Read latency and write latency are covered per VMDK, per VM
- [ ] (feature) Read commands/s and write commands/s are covered per VMDK, per VM
- [ ] (feature) Read throughput and write throughput are covered per VMDK, per VM
- [ ] (feature) The same full text+chart coverage is produced for physical devices whose names match `naa.*`
- [ ] (feature) The same full text+chart coverage is produced for NVMe devices (`nvme*` / `vmhba*` NVMe adapters)
- [ ] (feature) Outputs are written to a per-run directory laid out as `<vm>/<vmdk>/<category>.{png,txt}` (and `devices/<device>/<category>.*`) so a full-run result stays navigable
- [ ] (feature) A run-level summary index (Markdown or HTML) links every generated chart and stats block and tabulates min/max/average across all categories
- [ ] (feature) Chart rendering for a full run uses a bounded worker pool so a many-VMDK CSV completes without serialising every plot
- [ ] (feature) `--only`/`--exclude` filters restrict a full run to a subset of VMs, VMDKs, devices or categories
- [ ] (feature) A failure rendering one category is logged and skipped rather than aborting the whole run, and the run exits non-zero with a summary of what failed

## Phase 4 — VM CPU %RDY (lowest priority)

- [ ] (feature) Per-VM CPU `%RDY` series are extracted from the CSV with min, max and average in the text report
- [ ] (feature) A chart is generated per VM for `%RDY` using the same output layout and options as the VMDK charts
- [ ] (feature) `%RDY` is normalised per vCPU so values are comparable across differently sized VMs, and samples above a configurable threshold are flagged in the text output
- [ ] (feature) `%RDY` is included in the full-run command and in the run summary index

## Performance — CSV files up to 1 GB

- [ ] CSV files up to 1 GB are loaded without exhausting host memory — parse in chunks instead of reading the whole file into memory
- [ ] (feature) Only the columns needed for the requested categories are parsed, so a filtered run on a 1 GB CSV does not pay for every counter
- [ ] (refactor) The text and chart paths share one CSV load so a 1 GB file is parsed once per run rather than once per category
- [ ] (feature) A progress indicator reports parse progress for loads that take more than a few seconds
- [ ] Add a regression test that generates a ~1 GB CSV, runs a full extract, and asserts peak RSS stays under a fixed budget
- [ ] (feature) The container documents and enforces its memory/CPU limits so a 1 GB run fails with a clear message instead of being OOM-killed

## Container & packaging

- [ ] (refactor) The container entrypoint takes subcommands (`list`, `stats`, `chart`, `all`) instead of the single hardcoded VMDK-text path
- [ ] (feature) Input CSV directory and output directory are explicit bind-mount points, and generated files are owned by the invoking host uid/gid
- [ ] (feature) `Makefile` targets exist for each phase (`stats`, `chart`, `all`, `rdy`) taking `CSV=` and `OUT=` overrides
- [ ] (bug) Running the container without a mounted CSV fails with an actionable message instead of an empty result

## Housekeeping (left for humans)

- [ ] (docs) Document the category naming scheme, the per-run output layout and every CLI flag in `README.md`
- [ ] (docs) Add a worked example showing a full-run invocation and a sample of the generated summary index
- [ ] (chore) Pin the CSV-parsing and charting dependencies in the image and record the pinned versions
