# Project Plan — `pywidget` service

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

## API

- [ ] (feature) Add cursor-based pagination to `GET /widgets` with `limit` and `cursor` query params
- [ ] (feature) Support `PATCH /widgets/{id}` for partial updates
- [ ] (bug) `GET /widgets/{id}` returns 500 instead of 404 when the id is a well-formed UUID that does not exist
- [x] (feature) Add `GET /healthz` liveness endpoint (#128)

## Core / data layer

- [ ] (refactor) Extract the SQLAlchemy session handling in `pywidget/db.py` into a context-manager dependency
- [ ] (bug) `WidgetRepository.bulk_insert` silently drops rows when the batch exceeds 1000 items
- [ ] (feature) Add an optimistic-locking `version` column to `Widget` and bump it on every update

## CLI

- [ ] (feature) `pywidget export --format {json,csv}` writes all widgets to stdout
- [ ] (refactor) Replace the hand-rolled arg parsing in `pywidget/cli.py` with `argparse` subcommands

## Performance

- [ ] `list_widgets` issues an N+1 query per widget for its tags — load tags in a single query

## Housekeeping (left for humans)

- [ ] (docs) Document the pagination contract in `README.md`
- [ ] (chore) Bump `httpx` to 0.28 and clear the resulting deprecation warnings
