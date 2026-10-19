# pg_ddl_repl

DDL replication on top of PostgreSQL's **native** logical replication.

Native logical replication (`pgoutput`, publication/subscription) only replicates DML. `ALTER TABLE`, `CREATE INDEX`, and friends are entirely the DBA's job to keep in sync by hand. `pg_ddl_repl` closes that gap:

- **Transparent capture.** DDL is typed normally (`ALTER TABLE ...`, `CREATE INDEX ...`). No wrapper function to call, unlike `pglogical.replicate_ddl_command()`.
- **Granular, per-table filtering.** Choose which DDL replicates by table and by family (`table` / `column` / `index`) and by operation (e.g. replicate `add_column` but not `alter_column_default`).
- **Rides native logical replication for transport.** No custom protocol, no second apply worker to run — just an ordinary table added to your existing publication.

## Requirements

PostgreSQL **15, 16, 17, or 18**. Earlier versions are not supported (11–14 dropped deliberately — see the architecture note below).

## Why not pglogical / logical_ddl?

- **pglogical**: DDL replication is manual-only (`pglogical.replicate_ddl_command()`), and it caps at one apply worker per subscription — no parallelism.
- **[logical_ddl](https://github.com/samedyildirim/logical_ddl)**: closest prior art, same transparent-capture idea, but only covers 5 `ALTER TABLE` sub-cases (no `CREATE`/`DROP INDEX`, no `sql_drop` handling), and its `cmd_list text[]` filter model has no room for an index dimension.

`pg_ddl_repl` is a clean rewrite reusing the capture/transport *pattern* (event triggers + a table that rides the publication), not the code, with default-deny filtering across all three families from the start.

## Install

```sh
make
make install
```

Then in each database that will publish or subscribe:

```sql
CREATE EXTENSION pg_ddl_repl;
```

### Publisher side

```sql
-- Add the shadow queue table to whatever publication your tables are already on.
SELECT ddl_repl.enable_for_publication('my_publication');

-- Enable everything (table/column/index DDL) for one table:
SELECT ddl_repl.publish_table('orders'::regclass);

-- Or be selective -- one row per (table, family, operation):
INSERT INTO ddl_repl.publish_rules (relid, object_family, operation)
VALUES ('orders'::regclass, 'index', 'create_index');

-- CREATE TABLE itself can't be gated per-relid (the oid doesn't exist yet
-- when the statement runs) -- use a database-wide wildcard rule instead:
INSERT INTO ddl_repl.publish_rules (object_family, operation)
VALUES ('table', 'create_table');
```

### Subscriber side

```sql
-- Enable everything from a given publisher, for one table:
SELECT ddl_repl.subscribe_table('my_publisher_source_name', 'public', 'orders');
```

`my_publisher_source_name` defaults to the publisher's `cluster_name` GUC (falling back to its database name if unset) — override explicitly with the `ddl_repl.source_name` GUC if that's ambiguous in your topology. It is superuser-only (`SUSET`): set it in `postgresql.conf` / `ALTER SYSTEM`, or from a superuser session. Before PostgreSQL 17, `ALTER SYSTEM` only accepts it after `LOAD 'pg_ddl_repl'` in the same session.

## Filtering model

Everything is **default-deny**: a captured command is published (and, independently, applied on each subscriber) only if an `enabled` row matches. A table-specific row always wins over a database-wide wildcard (`relid`/`schema_name`+`table_name` `NULL`) for the same family+operation, so a table can override a general "yes" with an explicit "no", or vice versa.

- `ddl_repl.publish_rules` is keyed by `relid` (oid) — evaluated locally on the publisher, where that oid is meaningful.
- `ddl_repl.subscribe_rules` is keyed by `(source_name, schema_name, table_name)` — **not** oid. Publisher and subscriber are independently initialized clusters; the "same" logical table generally has a *different* oid on each side. Names are the only identifier logical replication itself already relies on being consistent (it already requires matching table names/structures for DML).

Operations per family:

| family | operations |
|---|---|
| `table` | `create_table`, `rename_table`, `drop_table`, `attach_partition`, `detach_partition`, `unsupported` |
| `column` | `add_column` (with its default, generated expression and `NOT NULL`), `drop_column`, `rename_column`, `alter_column_type` (with `USING`), `alter_column_default`, `set_not_null`, `drop_not_null` |
| `index` | `create_index`, `drop_index`, `rename_index` |
| `constraint` | `add_constraint` (primary key, unique, check, foreign key, exclusion, `ONLY`, `USING INDEX`), `drop_constraint`, `rename_constraint`, `validate_constraint`, `alter_constraint` (deferrability; on PostgreSQL 18 also enforceability and inheritability) |

`unsupported` reports schema changes that have no replay (identity and generated-expression changes, inheritance, typed tables, replica identity, logged/unlogged, `SET SCHEMA`, non-immutable (e.g. `now()`, `nextval()`) or identity column defaults, in which case the column's `NOT NULL` is not replicated either): the subscriber logs a warning and leaves the row with `applied_at` NULL instead of diverging silently. On PostgreSQL 18 a named `NOT NULL` constraint keeps its name and `NOT VALID` on the subscriber.

## Known v1 limitations

- **`create_table` is audit-only, never replayed.** The structured deparse doesn't capture a column list (see `src/deparse_table.c`). The DBA is expected to pre-create tables on subscribers before subscribing, same as native logical replication already requires for DML.
- **`alter_column_default` is audit-only unless a table opts in.** The new default expression isn't deparsed structurally (would require core's general expression deparser, out of scope for v1). Opt in with `ddl_repl.enable_raw_fallback(source_name, schema, table)` to replay the captured text instead — a single `ALTER ... SET/DROP DEFAULT` statement rebuilt from the catalogs at capture time (fully table-qualified, never the client's verbatim input). Still off by default because every object the default expression names must exist on the subscriber (names are schema-qualified at capture).
- **Constraints replicate by default, so what they reference must exist on the subscriber.** A `CHECK` calling a function or a foreign key referencing a table missing there stops apply. A replayed `ADD CONSTRAINT` whose name already exists on the table is skipped; a primary key named differently on the subscriber is refused with an explicit error. `NOT NULL` always travels as `set_not_null` / `drop_not_null`.
- **Drops are replayed without `CASCADE`.** Dependents dropped on the publisher (foreign keys, checks) are captured and replayed first; a dependent that exists only on the subscriber, or that sits on a table whose drops are not published, stops apply instead of being dropped silently.
- **The install script is not versioned yet.** Changes still go into `pg_ddl_repl--1.0.sql` in place; versioned upgrade scripts start with the first production install.
- **Topology is simple 1 publisher → N subscribers.** Loop prevention keys off `session_replication_role = 'replica'` (how apply workers always run, and superuser-only — no unprivileged role can set it to sneak DDL past capture); true bidirectional replication, where each side both publishes and subscribes the same tables, would need more than that.
- **No automated crash/restart idempotency test.** The apply path guards with `IF EXISTS`/`IF NOT EXISTS` and a `(source_name, id)` primary key, but this hasn't been exercised under an actual subscriber crash-and-replay in CI.

## Architecture, in one paragraph

Two event triggers capture DDL: `ddl_command_end` for creates/alters (deparsed structurally via the internal `CollectedCommand` API — the same one behind `pg_event_trigger_ddl_commands()`), and `sql_drop` for drops (by `ddl_command_end` time the object is already gone, so drops are only observable there). Each captured command becomes a JSONB row in `ddl_repl.command_queue`, a completely ordinary table added to a normal publication — transport rides native logical replication, no custom protocol. On the subscriber, an `AFTER INSERT` trigger marked `ENABLE REPLICA TRIGGER` (fires only during replica apply, never on a direct/local insert) reconstructs and re-executes the DDL inside the apply worker's own transaction — free ordering relative to DML replicated in the same transaction, and no second-transaction lock to deadlock against.

## Testing

TAP tests via `PostgreSQL::Test::Cluster` (`t/*.pl`) — the only realistic way to assert "DDL replicated" vs. "DDL was correctly filtered out" across a real publisher/subscriber pair. Requires a PostgreSQL build with `--enable-tap-tests` (most distro packages don't ship this; building from source is the reliable path):

```sh
make installcheck
```

No local PostgreSQL source build handy? The CI image (also used by GitHub Actions, see `.github/workflows/ci.yml`) builds one from source and runs the suite:

```sh
docker build -f ci/Dockerfile --build-arg PG_VERSION=17.5 -t pg_ddl_repl-ci .
docker run --rm pg_ddl_repl-ci
```

`t/030_ddl_fuzz.pl` is a differential test: it runs seeded random sequences of supported DDL (and DML) on a publisher and, after each batch, requires the subscriber's tables to match (columns, defaults, `NOT NULL`, constraints, indexes, rows) with apply still running. A failure prints the seed and the statements; widen or replay a run with `DDL_FUZZ_SEEDS="9 10 11" DDL_FUZZ_STEPS=80`.

Covers: table/column/index capture and replay, filtering (publish- and subscribe-side, default-deny, wildcard-vs-specific precedence), the opt-in raw-text fallback, multi-subscriber fan-out with independent filter sets, and same-transaction DDL+DML ordering.
