-- pg_ddl_repl: DDL replication over native PostgreSQL logical replication.
\echo Use "CREATE EXTENSION pg_ddl_repl;" to load this file. \quit

CREATE SCHEMA ddl_repl;

-- Shadow queue table: rides an ordinary publication like any other table,
-- so transport reuses native logical replication (no custom protocol).
--
-- PRIMARY KEY is (id, source_name), not id alone: id comes from a per-node
-- bigserial, so two independent nodes both capturing their own local DDL
-- will legitimately produce the same id value. A subscriber that also runs
-- its own DDL locally (e.g. pre-creating a table before subscribing to it)
-- captures into this same table -- without source_name in the key, that
-- collides with a same-numbered row later copied in from the publisher.
CREATE TABLE ddl_repl.command_queue (
    id bigserial NOT NULL,
    source_name text NOT NULL,
    payload jsonb NOT NULL,
    captured_at timestamptz NOT NULL DEFAULT now(),
    applied_at timestamptz,
    PRIMARY KEY (id, source_name)
);

-- Table-family structured deparse (CREATE TABLE, ALTER TABLE ... RENAME TO).
-- Returns zero rows for any command outside that scope.
CREATE FUNCTION ddl_repl.deparse_table(pg_ddl_command)
RETURNS TABLE (
    operation text,
    table_name text,
    table_oid oid,
    new_name text
)
LANGUAGE c
AS 'MODULE_PATHNAME', 'ddl_repl_deparse_table';

-- Column-family structured deparse (ADD/RENAME COLUMN, ALTER COLUMN TYPE,
-- ALTER COLUMN SET/DROP DEFAULT). DROP COLUMN is excluded on purpose --
-- captured from sql_drop instead, see capture_sql_drop below.
CREATE FUNCTION ddl_repl.deparse_column(pg_ddl_command)
RETURNS TABLE (
    operation text,
    table_name text,
    column_name text,
    new_name text,
    type_name text,
    table_oid oid,
    using_expr text
)
LANGUAGE c
AS 'MODULE_PATHNAME', 'ddl_repl_deparse_column';

-- Index-family structured deparse (CREATE INDEX only -- DROP INDEX is
-- captured from sql_drop, see capture_sql_drop below).
CREATE FUNCTION ddl_repl.deparse_index(pg_ddl_command)
RETURNS TABLE (
    operation text,
    table_name text,
    index_oid oid
)
LANGUAGE c
AS 'MODULE_PATHNAME', 'ddl_repl_deparse_index';

-- Constraint-family structured deparse (ALTER TABLE ... ADD CONSTRAINT); DROP CONSTRAINT comes from sql_drop.
CREATE FUNCTION ddl_repl.deparse_constraint(pg_ddl_command)
RETURNS TABLE (
    operation text,
    table_name text,
    table_oid oid,
    constraint_oid oid,
    index_oid oid,
    constraint_name text,
    is_only boolean
)
LANGUAGE c
AS 'MODULE_PATHNAME', 'ddl_repl_deparse_constraint';

-- Renames, VALIDATE / ALTER CONSTRAINT, ATTACH / DETACH PARTITION, and schema changes with no replay.
CREATE FUNCTION ddl_repl.deparse_extra(pg_ddl_command)
RETURNS TABLE (
    operation text,
    table_oid oid,
    name text,
    new_name text,
    related_oid oid,
    detail text
)
LANGUAGE c
AS 'MODULE_PATHNAME', 'ddl_repl_deparse_extra';

CREATE FUNCTION ddl_repl.default_is_mutable(p_relid oid, p_attnum int2)
RETURNS boolean
LANGUAGE c STRICT STABLE
AS 'MODULE_PATHNAME', 'ddl_repl_default_is_mutable';

-- Apply-side checks on queue text before it is executed: each raises unless the text is the one expected statement.
CREATE FUNCTION ddl_repl.canonical_type(type_name text)
RETURNS text
LANGUAGE c STRICT STABLE
AS 'MODULE_PATHNAME', 'ddl_repl_canonical_type';

CREATE FUNCTION ddl_repl.checked_index_def(index_def text, schema_name text, table_name text, index_name text)
RETURNS text
LANGUAGE c STRICT IMMUTABLE
AS 'MODULE_PATHNAME', 'ddl_repl_checked_index_def';

CREATE FUNCTION ddl_repl.checked_alter_default(ddl_text text, schema_name text, table_name text, column_name text)
RETURNS text
LANGUAGE c STRICT IMMUTABLE
AS 'MODULE_PATHNAME', 'ddl_repl_checked_alter_default';

CREATE FUNCTION ddl_repl.checked_add_constraint(ddl_text text, schema_name text, table_name text, constraint_name text)
RETURNS text
LANGUAGE c STRICT IMMUTABLE
AS 'MODULE_PATHNAME', 'ddl_repl_checked_add_constraint';

CREATE FUNCTION ddl_repl.checked_alter_type(ddl_text text, schema_name text, table_name text, column_name text)
RETURNS text
LANGUAGE c STRICT IMMUTABLE
AS 'MODULE_PATHNAME', 'ddl_repl_checked_alter_type';

CREATE FUNCTION ddl_repl.checked_add_column(ddl_text text, schema_name text, table_name text, column_name text)
RETURNS text
LANGUAGE c STRICT IMMUTABLE
AS 'MODULE_PATHNAME', 'ddl_repl_checked_add_column';

CREATE FUNCTION ddl_repl.checked_attach_partition(ddl_text text, schema_name text, table_name text, partition_name text)
RETURNS text
LANGUAGE c STRICT IMMUTABLE
AS 'MODULE_PATHNAME', 'ddl_repl_checked_attach_partition';

CREATE FUNCTION ddl_repl.execute_as(sql text, role oid)
RETURNS void
LANGUAGE c STRICT
AS 'MODULE_PATHNAME', 'ddl_repl_execute_as';
REVOKE ALL ON FUNCTION ddl_repl.execute_as(text, oid) FROM PUBLIC;

-- By the time DROP INDEX fires sql_drop, pg_index no longer has the row --
-- confirmed empirically (indrelid lookup by indexrelid returns NULL at that
-- point) -- so the owning table's oid can't be resolved from catalogs at
-- drop time. This tiny table is our own record, populated when CREATE
-- INDEX is captured (while the index still exists) and consulted instead.
CREATE TABLE ddl_repl.index_table_map (
    index_oid oid PRIMARY KEY,
    table_oid oid NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    index_name text
);

-- Same need for constraints: their kind and owner are gone from the catalogs by sql_drop time.
CREATE TABLE ddl_repl.constraint_map (
    constraint_oid oid PRIMARY KEY,
    contype "char" NOT NULL,
    column_name text,
    is_local boolean NOT NULL
);

CREATE FUNCTION ddl_repl.column_name(p_relid oid, p_attnum int2)
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT attname FROM pg_attribute WHERE attrelid = p_relid AND attnum = p_attnum
$$;

-- Rendered with the capture's search_path, so a subscriber-side comparison sees the same text.
CREATE FUNCTION ddl_repl.constraint_def(p_conoid oid)
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT pg_get_constraintdef(p_conoid)
$$;

-- A table and, when partitioned, all its partitions.
CREATE FUNCTION ddl_repl.relation_tree(p_relid oid)
RETURNS SETOF oid
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH RECURSIVE tree(relid) AS (
        SELECT p_relid
        UNION
        SELECT i.inhrelid FROM pg_inherits i JOIN tree ON i.inhparent = tree.relid
        JOIN pg_class pc ON pc.oid = tree.relid AND pc.relkind = 'p'
    )
    SELECT relid FROM tree
$$;

-- Records the constraints and indexes of a table and its partitions while their catalog rows exist.
CREATE FUNCTION ddl_repl.refresh_maps(p_relid oid)
RETURNS void
LANGUAGE sql
SET search_path = pg_catalog, pg_temp
AS $$
    INSERT INTO ddl_repl.constraint_map (constraint_oid, contype, column_name, is_local)
    SELECT c.oid, c.contype, a.attname, c.conislocal
    FROM pg_constraint c
    LEFT JOIN pg_attribute a ON c.contype = 'n' AND a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
    WHERE c.conrelid IN (SELECT ddl_repl.relation_tree(p_relid))
    ON CONFLICT (constraint_oid) DO UPDATE
        SET contype = EXCLUDED.contype, column_name = EXCLUDED.column_name, is_local = EXCLUDED.is_local
        WHERE (ddl_repl.constraint_map.contype, ddl_repl.constraint_map.column_name, ddl_repl.constraint_map.is_local)
              IS DISTINCT FROM (EXCLUDED.contype, EXCLUDED.column_name, EXCLUDED.is_local);

    -- index_name keeps the first recorded name: the one the subscriber built the index under.
    INSERT INTO ddl_repl.index_table_map (index_oid, table_oid, schema_name, table_name, index_name)
    SELECT i.indexrelid, c.oid, n.nspname, c.relname, x.relname
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indrelid AND c.oid IN (SELECT ddl_repl.relation_tree(p_relid))
    JOIN pg_class x ON x.oid = i.indexrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    ON CONFLICT (index_oid) DO UPDATE
        SET schema_name = EXCLUDED.schema_name, table_name = EXCLUDED.table_name,
            index_name = coalesce(ddl_repl.index_table_map.index_name, EXCLUDED.index_name)
        WHERE (ddl_repl.index_table_map.schema_name, ddl_repl.index_table_map.table_name,
               ddl_repl.index_table_map.index_name)
              IS DISTINCT FROM (EXCLUDED.schema_name, EXCLUDED.table_name,
                                coalesce(ddl_repl.index_table_map.index_name, EXCLUDED.index_name));
$$;

-- Everything the subscriber needs to rebuild an added column, read from the catalog after the DDL.
CREATE FUNCTION ddl_repl.column_spec(p_relid oid, p_column text)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'default_expr', CASE WHEN a.attgenerated = '' AND s.reason IS NULL THEN pg_get_expr(d.adbin, d.adrelid) END,
        'generated_expr', CASE WHEN a.attgenerated = 's' THEN pg_get_expr(d.adbin, d.adrelid) END,
        -- On PG18 an added NOT NULL also arrives as a not-null constraint, replayed as set_not_null.
        'not_null', a.attnotnull AND current_setting('server_version_num')::int < 180000 AND s.reason IS NULL,
        -- Without its default the subscriber's existing rows are NULL: NOT NULL cannot follow.
        'unsupported', s.reason || CASE WHEN s.reason IS NOT NULL AND a.attnotnull THEN ' (NOT NULL not replicated)' ELSE '' END)
    FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    CROSS JOIN LATERAL (SELECT CASE WHEN a.attidentity <> '' THEN 'identity column'
                                    WHEN a.attgenerated = 'v' THEN 'virtual generated column'
                                    WHEN d.adbin IS NOT NULL AND ddl_repl.default_is_mutable(p_relid, a.attnum)
                                         THEN 'non-immutable default' END AS reason) s
    WHERE a.attrelid = p_relid AND a.attname = p_column
$$;

-- Filtering, per (table, object family, operation), default-deny: a
-- command is published/applied only if an ENABLED row matches -- a
-- table-specific row (relid = the table's oid) always wins over a
-- database-wide wildcard row (relid IS NULL) for the same family+operation,
-- so a table can override a general "yes" with an explicit "no" (or the
-- reverse). DDL replication is higher blast-radius than DML, hence
-- default-deny rather than logical_ddl's default-allow.
CREATE TABLE ddl_repl.publish_rules (
    id bigserial PRIMARY KEY,
    relid oid,
    object_family text NOT NULL CHECK (object_family IN ('table', 'column', 'index', 'constraint')),
    operation text NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    UNIQUE NULLS NOT DISTINCT (relid, object_family, operation)
);

-- Tables that existed before their rule was enabled: record their constraints and indexes now.
CREATE FUNCTION ddl_repl.refresh_maps_for_rules()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM ddl_repl.refresh_maps(c.oid)
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p') AND c.relpersistence <> 't'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'ddl_repl') AND n.nspname NOT LIKE 'pg_toast%'
      AND EXISTS (SELECT 1 FROM new_rules r
                  WHERE r.enabled AND (r.relid = c.oid OR (r.relid IS NULL AND NOT c.relispartition)));
    RETURN NULL;
END
$$;

CREATE TRIGGER ddl_repl_publish_rules_inserted
    AFTER INSERT ON ddl_repl.publish_rules
    REFERENCING NEW TABLE AS new_rules
    FOR EACH STATEMENT EXECUTE FUNCTION ddl_repl.refresh_maps_for_rules();

CREATE TRIGGER ddl_repl_publish_rules_updated
    AFTER UPDATE ON ddl_repl.publish_rules
    REFERENCING NEW TABLE AS new_rules
    FOR EACH STATEMENT EXECUTE FUNCTION ddl_repl.refresh_maps_for_rules();

-- Keyed by (schema_name, table_name), not oid: publisher and subscriber are
-- independently-initialized clusters, so the "same" logical table generally
-- has a *different* oid on each side -- an oid captured on the publisher
-- (as in publish_rules) is meaningless on the subscriber. Names are the
-- only identifier logical replication itself relies on being the same on
-- both ends (it already requires matching table names/structures), so
-- that's what the subscribe-side filter keys on too.
CREATE TABLE ddl_repl.subscribe_rules (
    id bigserial PRIMARY KEY,
    source_name text NOT NULL,
    schema_name text,
    table_name text,
    object_family text NOT NULL CHECK (object_family IN ('table', 'column', 'index', 'constraint')),
    operation text NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    -- Opt-in: replay the catalog-rebuilt, schema-qualified ALTER ... SET/DROP DEFAULT for 'alter_column_default'.
    -- Off by default: every object the default expression names must exist on the subscriber.
    allow_raw_fallback boolean NOT NULL DEFAULT false,
    CHECK ((schema_name IS NULL) = (table_name IS NULL)),
    UNIQUE NULLS NOT DISTINCT (source_name, schema_name, table_name, object_family, operation)
);

-- Temporary tables are session-local: never replicated, whatever the rules say.
CREATE FUNCTION ddl_repl.is_published(p_relid oid, p_family text, p_operation text)
RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class WHERE oid = p_relid AND relpersistence = 't')
    AND coalesce(
        (SELECT enabled FROM ddl_repl.publish_rules
         WHERE object_family = p_family AND operation = p_operation
           AND (relid = p_relid OR relid IS NULL)
         ORDER BY relid IS NULL ASC
         LIMIT 1),
        false
    )
$$;

-- Single source of truth for subscribe-side rule matching: the winning rule
-- is the table-specific one when present, else the wildcard (the ORDER BY).
-- is_subscribed and allows_raw_fallback both read their answer off this one
-- row so the precedence logic cannot silently diverge between them.
CREATE FUNCTION ddl_repl.match_subscribe_rule(p_source_name text, p_schema text, p_table text, p_family text, p_operation text)
RETURNS ddl_repl.subscribe_rules
LANGUAGE sql STABLE AS $$
    SELECT r FROM ddl_repl.subscribe_rules r
    WHERE r.source_name = p_source_name
      AND r.object_family = p_family AND r.operation = p_operation
      AND ((r.schema_name = p_schema AND r.table_name = p_table)
           OR (r.schema_name IS NULL AND r.table_name IS NULL))
    ORDER BY (r.schema_name IS NULL) ASC
    LIMIT 1
$$;

CREATE FUNCTION ddl_repl.is_subscribed(p_source_name text, p_schema text, p_table text, p_family text, p_operation text)
RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT coalesce(
        (ddl_repl.match_subscribe_rule(p_source_name, p_schema, p_table, p_family, p_operation)).enabled,
        false
    )
$$;

CREATE FUNCTION ddl_repl.allows_raw_fallback(p_source_name text, p_schema text, p_table text, p_family text, p_operation text)
RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT coalesce(
        (ddl_repl.match_subscribe_rule(p_source_name, p_schema, p_table, p_family, p_operation)).allow_raw_fallback,
        false
    )
$$;

CREATE FUNCTION ddl_repl.enable_raw_fallback(p_source_name text, p_schema text, p_table text, p_operation text DEFAULT 'alter_column_default')
RETURNS void
LANGUAGE sql AS $$
    UPDATE ddl_repl.subscribe_rules SET allow_raw_fallback = true
    WHERE source_name = p_source_name AND schema_name = p_schema AND table_name = p_table
      AND object_family = 'column' AND operation = p_operation
$$;

CREATE FUNCTION ddl_repl.known_operations()
RETURNS TABLE (object_family text, operation text)
LANGUAGE sql IMMUTABLE AS $$
    VALUES
        ('table', 'create_table'),
        ('table', 'rename_table'),
        ('table', 'drop_table'),
        ('column', 'add_column'),
        ('column', 'drop_column'),
        ('column', 'rename_column'),
        ('column', 'alter_column_type'),
        ('column', 'alter_column_default'),
        ('index', 'create_index'),
        ('column', 'set_not_null'),
        ('column', 'drop_not_null'),
        ('index', 'drop_index'),
        ('constraint', 'add_constraint'),
        ('constraint', 'drop_constraint'),
        ('constraint', 'rename_constraint'),
        ('constraint', 'validate_constraint'),
        ('constraint', 'alter_constraint'),
        ('index', 'rename_index'),
        ('table', 'attach_partition'),
        ('table', 'detach_partition'),
        ('table', 'unsupported')
$$;

-- Convenience: enable every known operation for one
-- table (publish side) or one (source, table) pair (subscribe side).
CREATE FUNCTION ddl_repl.publish_table(p_relid oid)
RETURNS void
LANGUAGE sql AS $$
    INSERT INTO ddl_repl.publish_rules (relid, object_family, operation)
    SELECT p_relid, object_family, operation FROM ddl_repl.known_operations()
    ON CONFLICT (relid, object_family, operation) DO UPDATE SET enabled = true
$$;

CREATE FUNCTION ddl_repl.subscribe_table(p_source_name text, p_schema text, p_table text)
RETURNS void
LANGUAGE sql AS $$
    INSERT INTO ddl_repl.subscribe_rules (source_name, schema_name, table_name, object_family, operation)
    SELECT p_source_name, p_schema, p_table, object_family, operation FROM ddl_repl.known_operations()
    ON CONFLICT (source_name, schema_name, table_name, object_family, operation) DO UPDATE SET enabled = true
$$;

-- ddl_repl.source_name is a SUSET parameter defined by the library: only the server config or a superuser can set it.
CREATE FUNCTION ddl_repl.source_name_override()
RETURNS text
LANGUAGE c STABLE
AS 'MODULE_PATHNAME', 'ddl_repl_source_name_override';

CREATE FUNCTION ddl_repl.source_name()
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT coalesce(
        ddl_repl.source_name_override(),
        nullif(current_setting('cluster_name', true), ''),
        current_database()
    )
$$;

-- Rebuild a single, self-contained, fully table-qualified ALTER ... SET/DROP
-- DEFAULT statement from the catalogs. By ddl_command_end time the new
-- default is already committed to pg_attrdef, so the expression can be read
-- back with pg_get_expr (no adbin row left = it was a DROP DEFAULT). Never
-- current_query(): that is the client's whole command string, which may
-- batch unrelated statements or sibling ALTER TABLE subcommands the
-- per-operation filter never approved -- replaying it verbatim on the
-- subscriber would execute them all.
CREATE FUNCTION ddl_repl.build_alter_default_sql(p_relid oid, p_column text)
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN d.adbin IS NOT NULL THEN
        format('ALTER TABLE IF EXISTS %I.%I ALTER COLUMN %I SET DEFAULT %s',
               n.nspname, c.relname, a.attname, pg_get_expr(d.adbin, d.adrelid))
    ELSE
        format('ALTER TABLE IF EXISTS %I.%I ALTER COLUMN %I DROP DEFAULT',
               n.nspname, c.relname, a.attname)
    END
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attname = p_column
    LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
    WHERE c.oid = p_relid
$$;

CREATE FUNCTION ddl_repl.queue_unsupported(p_source text, p_schema text, p_table text, p_table_oid oid, p_detail text)
RETURNS void
LANGUAGE sql
SET search_path = pg_catalog, pg_temp
AS $$
    INSERT INTO ddl_repl.command_queue (source_name, payload)
    SELECT p_source, jsonb_build_object(
        'schema_version', 1, 'object_family', 'table', 'operation', 'unsupported',
        'schema_name', p_schema, 'table_name', p_table, 'table_oid', p_table_oid, 'detail', p_detail)
    WHERE ddl_repl.is_published(p_table_oid, 'table', 'unsupported')
$$;

-- Event triggers fire for every role: run as the extension owner, so ordinary roles need no rights on ddl_repl.
CREATE FUNCTION ddl_repl.capture_ddl_command_end()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    obj record;
    line record;
    v_source text := ddl_repl.source_name();
    v_no_not_null text[];
BEGIN
    -- Loop-prevention: logical replication apply workers run with
    -- session_replication_role = 'replica' (the same fact ENABLE REPLICA
    -- TRIGGER relies on), so DDL being replayed from a subscription is
    -- recognizable here and skipped -- otherwise a subscriber re-executing
    -- DDL would recapture and re-queue it, looping forever in any
    -- bidirectional/cascading setup. session_replication_role is
    -- superuser-only (SUSET); a custom USERSET GUC here would let any role
    -- silently exempt its own DDL from capture and replication.
    IF current_setting('session_replication_role') = 'replica' THEN
        RETURN;
    END IF;

    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        FOR line IN SELECT * FROM ddl_repl.deparse_table(obj.command)
        LOOP
            IF ddl_repl.is_published(line.table_oid, 'table', line.operation) THEN
                INSERT INTO ddl_repl.command_queue (source_name, payload)
                VALUES (
                    v_source,
                    jsonb_build_object(
                        'schema_version', 1,
                        'object_family', 'table',
                        'operation', line.operation,
                        'schema_name', obj.schema_name,
                        'table_name', line.table_name,
                        'table_oid', line.table_oid,
                        'new_name', line.new_name
                    )
                );
            END IF;

            IF line.operation = 'rename_table' THEN
                UPDATE ddl_repl.index_table_map SET table_name = line.new_name WHERE table_oid = line.table_oid;
            END IF;
        END LOOP;

        v_no_not_null := '{}';
        FOR line IN SELECT * FROM ddl_repl.deparse_column(obj.command)
        LOOP
          DECLARE
            v_spec jsonb := CASE WHEN line.operation = 'add_column'
                                 THEN ddl_repl.column_spec(line.table_oid, line.column_name) ELSE '{}'::jsonb END;
          BEGIN
            IF v_spec->>'unsupported' IS NOT NULL THEN
                v_no_not_null := v_no_not_null || line.column_name;
            END IF;
            IF ddl_repl.is_published(line.table_oid, 'column', line.operation) THEN
                INSERT INTO ddl_repl.command_queue (source_name, payload)
                VALUES (
                    v_source,
                    v_spec
                    || jsonb_build_object(
                        'schema_version', 1,
                        'object_family', 'column',
                        'operation', line.operation,
                        'schema_name', obj.schema_name,
                        'table_name', line.table_name,
                        'table_oid', line.table_oid,
                        'column_name', line.column_name,
                        'new_name', line.new_name,
                        'type_name', line.type_name,
                        'using_expr', line.using_expr,
                        -- Only 'alter_column_default' relies on this: the new
                        -- default expression isn't deparsed structurally (see
                        -- deparse_column.c), so a single rebuilt statement is
                        -- kept as an opt-in raw-replay fallback.
                        'ddl_text', CASE WHEN line.operation = 'alter_column_default'
                                         THEN ddl_repl.build_alter_default_sql(line.table_oid, line.column_name) END
                    )
                );
                IF v_spec->>'unsupported' IS NOT NULL THEN
                    PERFORM ddl_repl.queue_unsupported(v_source, obj.schema_name, line.table_name, line.table_oid,
                                                       format('column %s: %s', line.column_name, v_spec->>'unsupported'));
                END IF;
            END IF;
          END;
        END LOOP;

        FOR line IN SELECT * FROM ddl_repl.deparse_index(obj.command)
        LOOP
            DECLARE
                v_table_oid oid := (SELECT indrelid FROM pg_index WHERE indexrelid = line.index_oid);
            BEGIN
                IF ddl_repl.is_published(v_table_oid, 'index', line.operation) THEN
                    INSERT INTO ddl_repl.command_queue (source_name, payload)
                    VALUES (
                        v_source,
                        jsonb_build_object(
                            'schema_version', 1,
                            'object_family', 'index',
                            'operation', line.operation,
                            'schema_name', obj.schema_name,
                            'table_name', line.table_name,
                            'table_oid', v_table_oid,
                            'index_name', (SELECT relname FROM pg_class WHERE oid = line.index_oid),
                            -- Full CREATE INDEX text from the OID, not
                            -- hand-walked from the parse tree -- see
                            -- deparse_index.c.
                            -- A valid partitioned index was built on every partition: replay it without ONLY.
                            'index_def', CASE WHEN (SELECT c.relkind = 'I' AND i.indisvalid FROM pg_class c
                                                    JOIN pg_index i ON i.indexrelid = c.oid WHERE c.oid = line.index_oid)
                                              THEN replace(pg_get_indexdef(line.index_oid), ' ON ONLY ', ' ON ')
                                              ELSE pg_get_indexdef(line.index_oid) END
                        )
                    );
                END IF;
            END;
        END LOOP;

        FOR line IN SELECT * FROM ddl_repl.deparse_constraint(obj.command)
        LOOP
            DECLARE
                c pg_constraint;
                v_index_name text;
                v_column text;
                v_def text;
            BEGIN
                SELECT * INTO c FROM pg_constraint WHERE oid = line.constraint_oid;
                IF NOT FOUND THEN
                    SELECT * INTO c FROM pg_constraint WHERE conrelid = line.table_oid AND conname = line.constraint_name;
                END IF;
                IF c.oid IS NULL THEN
                    CONTINUE;
                END IF;

                -- NOT NULL is one family only: set_not_null, whatever the catalog stores it as.
                IF c.contype = 'n' THEN
                    v_column := ddl_repl.column_name(c.conrelid, c.conkey[1]);
                    IF ddl_repl.is_published(line.table_oid, 'column', 'set_not_null') AND v_column <> ALL (v_no_not_null) THEN
                        -- Named so a PG18 subscriber keeps the name, for later VALIDATE / RENAME / ALTER CONSTRAINT.
                        INSERT INTO ddl_repl.command_queue (source_name, payload)
                        VALUES (v_source, jsonb_build_object(
                            'schema_version', 1, 'object_family', 'column', 'operation', 'set_not_null',
                            'schema_name', obj.schema_name, 'table_name', line.table_name, 'table_oid', line.table_oid,
                            'column_name', v_column,
                            'constraint_name', c.conname, 'not_valid', NOT c.convalidated, 'no_inherit', c.connoinherit));
                    END IF;
                ELSIF ddl_repl.is_published(line.table_oid, 'constraint', line.operation) THEN
                    -- USING INDEX renamed the index on this node: the subscriber still has it under the old name.
                    IF line.index_oid IS NOT NULL THEN
                        SELECT index_name INTO v_index_name FROM ddl_repl.index_table_map WHERE index_oid = line.index_oid;
                    END IF;
                    v_def := ddl_repl.constraint_def(c.oid);
                    INSERT INTO ddl_repl.command_queue (source_name, payload)
                    VALUES (v_source, jsonb_build_object(
                        'schema_version', 1, 'object_family', 'constraint', 'operation', line.operation,
                        'schema_name', obj.schema_name, 'table_name', line.table_name, 'table_oid', line.table_oid,
                        'constraint_name', c.conname,
                        'contype', c.contype,
                        'only', line.is_only,
                        'compare_def', CASE WHEN v_index_name IS NOT NULL THEN v_def END,
                        'constraint_def', CASE WHEN v_index_name IS NULL THEN v_def
                            ELSE CASE c.contype WHEN 'p' THEN 'PRIMARY KEY' ELSE 'UNIQUE' END
                                 || ' USING INDEX ' || quote_ident(v_index_name)
                                 || CASE WHEN c.condeferrable THEN ' DEFERRABLE' ELSE '' END
                                 || CASE WHEN c.condeferred THEN ' INITIALLY DEFERRED' ELSE '' END
                            END));
                    UPDATE ddl_repl.index_table_map SET index_name = c.conname WHERE index_oid = line.index_oid;
                END IF;
            END;
        END LOOP;

        FOR line IN SELECT * FROM ddl_repl.deparse_extra(obj.command)
        LOOP
            DECLARE
                v_family text := CASE WHEN line.operation IN ('rename_constraint', 'validate_constraint', 'alter_constraint')
                                      THEN 'constraint'
                                      WHEN line.operation = 'rename_index' THEN 'index' ELSE 'table' END;
                v_schema text;
                v_table text;
                v_payload jsonb;
            BEGIN
                CONTINUE WHEN line.table_oid IS NULL OR NOT ddl_repl.is_published(line.table_oid, v_family, line.operation);
                SELECT n.nspname, c.relname INTO v_schema, v_table
                FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = line.table_oid;
                v_payload := jsonb_build_object(
                    'schema_version', 1, 'object_family', v_family, 'operation', line.operation,
                    'schema_name', v_schema, 'table_name', v_table, 'table_oid', line.table_oid, 'new_name', line.new_name, 'detail', line.detail);
                IF line.operation IN ('rename_constraint', 'validate_constraint', 'alter_constraint') THEN
                    v_payload := v_payload || jsonb_build_object('constraint_name', line.name);
                    IF line.operation = 'alter_constraint' THEN
                        v_payload := v_payload || (SELECT jsonb_build_object(
                                                       'deferrable', condeferrable, 'deferred', condeferred,
                                                       'enforced', to_jsonb(k) -> 'conenforced', 'no_inherit', connoinherit)
                                                   FROM pg_constraint k WHERE conrelid = line.table_oid AND conname = line.name);
                    ELSIF line.operation = 'rename_constraint' THEN
                        UPDATE ddl_repl.index_table_map m SET index_name = line.new_name
                        FROM pg_constraint k WHERE k.conrelid = line.table_oid AND k.conname = line.new_name
                                               AND m.index_oid = k.conindid AND k.contype IN ('p', 'u', 'x');
                    END IF;
                ELSIF line.operation = 'rename_index' THEN
                    v_payload := v_payload || jsonb_build_object('index_name', line.name);
                    UPDATE ddl_repl.index_table_map SET index_name = line.new_name WHERE index_oid = line.related_oid;
                ELSIF line.operation IN ('attach_partition', 'detach_partition') THEN
                    -- PG15 DETACH without address and the partition not in the parent's schema: a unique name match.
                    IF line.related_oid IS NULL THEN
                        SELECT min(c.oid) INTO line.related_oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                        WHERE c.relname = line.name AND c.relkind IN ('r', 'p') AND NOT c.relispartition
                          AND (line.detail IS NULL OR n.nspname = line.detail)
                        HAVING count(*) = 1;
                    END IF;
                    v_payload := v_payload || (
                        SELECT jsonb_build_object('partition_schema', n.nspname, 'partition_name', c.relname,
                                                  'partition_bound', pg_get_expr(c.relpartbound, c.oid))
                        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = line.related_oid);
                    -- A detached partition's constraints become local: the parent's refresh no longer reaches it.
                    IF line.operation = 'detach_partition' THEN
                        PERFORM ddl_repl.refresh_maps(line.related_oid);
                    END IF;
                END IF;
                -- A payload that cannot be built is reported, never inserted as NULL: capture must not fail the DDL.
                IF v_payload IS NULL THEN
                    v_payload := jsonb_build_object(
                        'schema_version', 1, 'object_family', 'table', 'operation', 'unsupported',
                        'schema_name', v_schema, 'table_name', v_table, 'table_oid', line.table_oid,
                        'detail', format('%s of %s could not be captured', line.operation, line.name));
                END IF;
                INSERT INTO ddl_repl.command_queue (source_name, payload) VALUES (v_source, v_payload);
            END;
        END LOOP;

        -- Maps are only consulted for published tables; refresh them for those alone.
        DECLARE
            v_relid oid := CASE WHEN obj.object_type IN ('table', 'table column') THEN obj.objid
                                WHEN obj.object_type = 'index'
                                     THEN (SELECT indrelid FROM pg_index WHERE indexrelid = obj.objid) END;
        BEGIN
            IF v_relid IS NOT NULL AND EXISTS (
                   SELECT 1 FROM ddl_repl.publish_rules r
                   WHERE r.enabled AND (r.relid IS NULL OR r.relid IN (SELECT ddl_repl.relation_tree(v_relid)))) THEN
                PERFORM ddl_repl.refresh_maps(v_relid);
            END IF;
        END;
    END LOOP;
END
$$;

CREATE EVENT TRIGGER ddl_repl_capture_ddl_command_end
    ON ddl_command_end
    EXECUTE FUNCTION ddl_repl.capture_ddl_command_end();

-- DROP TABLE is only observable via sql_drop (by ddl_command_end time the
-- object is already gone) -- captured directly in SQL, no C deparse needed
-- since pg_event_trigger_dropped_objects() is already fully structured.
CREATE FUNCTION ddl_repl.capture_sql_drop()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    obj record;
    v_source text := ddl_repl.source_name();
BEGIN
    -- Same loop-prevention as capture_ddl_command_end: skip while a
    -- subscription apply worker (session_replication_role = 'replica') is
    -- replaying a command.
    IF current_setting('session_replication_role') = 'replica' THEN
        RETURN;
    END IF;

    -- Replayed drops have no CASCADE: constraints go first, in reverse report order (dependents come after the
    -- object they depend on), so each replayed drop finds its dependents already gone.
    FOR obj IN
        SELECT d.* FROM pg_event_trigger_dropped_objects() WITH ORDINALITY AS d
        WHERE d.object_type IN ('table', 'table column', 'index', 'table constraint') AND NOT d.is_temporary
        ORDER BY d.object_type = 'table constraint' DESC,
                 CASE WHEN d.object_type = 'table constraint' THEN -d.ordinality ELSE d.ordinality END
    LOOP
        IF obj.object_type = 'table' THEN
            IF ddl_repl.is_published(obj.objid, 'table', 'drop_table') THEN
                INSERT INTO ddl_repl.command_queue (source_name, payload)
                VALUES (
                    v_source,
                    jsonb_build_object(
                        'schema_version', 1,
                        'object_family', 'table',
                        'operation', 'drop_table',
                        'schema_name', obj.schema_name,
                        'table_name', obj.object_name,
                        'table_oid', obj.objid
                    )
                );
            END IF;
        ELSIF obj.object_type = 'index' THEN
            DECLARE
                v_map ddl_repl.index_table_map;
            BEGIN
                SELECT * INTO v_map FROM ddl_repl.index_table_map WHERE index_oid = obj.objid;

                IF ddl_repl.is_published(v_map.table_oid, 'index', 'drop_index') THEN
                    INSERT INTO ddl_repl.command_queue (source_name, payload)
                    VALUES (
                        v_source,
                        jsonb_build_object(
                            'schema_version', 1,
                            'object_family', 'index',
                            'operation', 'drop_index',
                            'schema_name', obj.schema_name,
                            'table_name', v_map.table_name,
                            'table_oid', v_map.table_oid,
                            'index_name', obj.object_name
                        )
                    );
                END IF;

                DELETE FROM ddl_repl.index_table_map WHERE index_oid = obj.objid;
            END;
        ELSIF obj.object_type = 'table constraint' THEN
            DECLARE
                v_table_oid oid := to_regclass(format('%I.%I', obj.address_names[1], obj.address_names[2]));
                v_map ddl_repl.constraint_map;
            BEGIN
                DELETE FROM ddl_repl.constraint_map WHERE constraint_oid = obj.objid RETURNING * INTO v_map;

                -- Skipped: the whole table was dropped (drop_table covers it), the constraint was rebuilt
                -- under the same name (column type change), or it is a partition's inherited copy.
                IF v_table_oid IS NULL
                   OR EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = v_table_oid AND conname = obj.address_names[3])
                   OR v_map.is_local IS FALSE THEN
                    NULL;
                ELSIF v_map IS NULL THEN
                    PERFORM ddl_repl.queue_unsupported(v_source, obj.address_names[1], obj.address_names[2], v_table_oid,
                                                       format('drop of untracked constraint %s', obj.address_names[3]));
                ELSIF v_map.contype = 'n' THEN
                    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = v_table_oid AND attname = v_map.column_name
                                                          AND NOT attisdropped)
                       AND ddl_repl.is_published(v_table_oid, 'column', 'drop_not_null') THEN
                        INSERT INTO ddl_repl.command_queue (source_name, payload)
                        VALUES (v_source, jsonb_build_object(
                            'schema_version', 1, 'object_family', 'column', 'operation', 'drop_not_null',
                            'schema_name', obj.address_names[1], 'table_name', obj.address_names[2],
                            'table_oid', v_table_oid, 'column_name', v_map.column_name));
                    END IF;
                ELSIF ddl_repl.is_published(v_table_oid, 'constraint', 'drop_constraint') THEN
                    INSERT INTO ddl_repl.command_queue (source_name, payload)
                    VALUES (v_source, jsonb_build_object(
                        'schema_version', 1, 'object_family', 'constraint', 'operation', 'drop_constraint',
                        'schema_name', obj.address_names[1], 'table_name', obj.address_names[2],
                        'table_oid', v_table_oid, 'constraint_name', obj.address_names[3]));
                END IF;
            END;
        ELSE
            -- object_name/schema_name are NULL for dropped columns; the
            -- qualified path only comes through address_names, confirmed
            -- empirically ({schema, table, column}) since it isn't documented
            -- field-by-field.
            IF ddl_repl.is_published(obj.objid, 'column', 'drop_column') THEN
                INSERT INTO ddl_repl.command_queue (source_name, payload)
                VALUES (
                    v_source,
                    jsonb_build_object(
                        'schema_version', 1,
                        'object_family', 'column',
                        'operation', 'drop_column',
                        'schema_name', obj.address_names[1],
                        'table_name', obj.address_names[2],
                        'column_name', obj.address_names[3],
                        'table_oid', obj.objid
                    )
                );
            END IF;
        END IF;
    END LOOP;
END
$$;

CREATE EVENT TRIGGER ddl_repl_capture_sql_drop
    ON sql_drop
    EXECUTE FUNCTION ddl_repl.capture_sql_drop();

-- Manual step: the extension can't guess which publication a DBA wants the
-- shadow queue table riding on at CREATE EXTENSION time.
CREATE FUNCTION ddl_repl.enable_for_publication(pubname text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_setting('wal_level') <> 'logical' THEN
        RAISE EXCEPTION 'wal_level must be ''logical'' for DDL replication, got %', current_setting('wal_level');
    END IF;

    EXECUTE format('ALTER PUBLICATION %I ADD TABLE ddl_repl.command_queue', pubname);
END
$$;

-- Apply side: fires inside the apply worker's own transaction as each
-- command_queue row lands via the normal logical replication apply path,
-- so ordering relative to any DML replicated in the same transaction is
-- free and there is no second-transaction lock to deadlock against.
CREATE FUNCTION ddl_repl.apply_command()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_family text := NEW.payload->>'object_family';
    v_op text := NEW.payload->>'operation';
    v_schema text := NEW.payload->>'schema_name';
    v_table text := NEW.payload->>'table_name';
    v_column text := NEW.payload->>'column_name';
    v_new_name text := NEW.payload->>'new_name';
    v_type text := NEW.payload->>'type_name';
    v_index text := NEW.payload->>'index_name';
    v_index_def text := NEW.payload->>'index_def';
    v_sql text;
    v_owner oid;
    v_other_pk text;
    v_redefine_sql text;
    v_existing_def text;
    v_relid oid := to_regclass(quote_ident(v_schema) || '.' || quote_ident(v_table));
BEGIN
    IF v_family NOT IN ('table', 'column', 'index', 'constraint') THEN
        RETURN NEW;
    END IF;

    IF NOT ddl_repl.is_subscribed(NEW.source_name, v_schema, v_table, v_family, v_op) THEN
        RETURN NEW;
    END IF;

    CASE v_op
        WHEN 'rename_table' THEN
            v_sql := format('ALTER TABLE IF EXISTS %I.%I RENAME TO %I', v_schema, v_table, v_new_name);
            -- Rules are keyed by name and describe this node's table, so every source's rules follow the rename;
            -- a rule already set on the new name wins.
            DELETE FROM ddl_repl.subscribe_rules o
            WHERE o.schema_name = v_schema AND o.table_name = v_table
              AND EXISTS (SELECT 1 FROM ddl_repl.subscribe_rules n
                          WHERE n.source_name = o.source_name AND n.schema_name = o.schema_name
                            AND n.table_name = v_new_name
                            AND n.object_family = o.object_family AND n.operation = o.operation);
            UPDATE ddl_repl.subscribe_rules SET table_name = v_new_name
            WHERE schema_name = v_schema AND table_name = v_table;
            UPDATE ddl_repl.index_table_map SET table_name = v_new_name
            WHERE schema_name = v_schema AND table_name = v_table;
        WHEN 'drop_table' THEN
            v_sql := format('DROP TABLE IF EXISTS %I.%I', v_schema, v_table);
        WHEN 'create_table' THEN
            -- Structured deparse doesn't carry a column list yet (see
            -- deparse_table.c) -- logged for audit, not replayed in v1.
            v_sql := NULL;
        WHEN 'add_column' THEN
            v_sql := ddl_repl.checked_add_column(
                format('ALTER TABLE IF EXISTS %I.%I ADD COLUMN IF NOT EXISTS %I %s%s%s%s',
                       v_schema, v_table, v_column, ddl_repl.canonical_type(v_type),
                       CASE WHEN NEW.payload->>'default_expr' IS NOT NULL
                            THEN ' DEFAULT ' || (NEW.payload->>'default_expr') ELSE '' END,
                       CASE WHEN NEW.payload->>'generated_expr' IS NOT NULL
                            THEN ' GENERATED ALWAYS AS (' || (NEW.payload->>'generated_expr') || ') STORED' ELSE '' END,
                       CASE WHEN (NEW.payload->>'not_null')::boolean THEN ' NOT NULL' ELSE '' END),
                v_schema, v_table, v_column);
        WHEN 'drop_column' THEN
            v_sql := format('ALTER TABLE IF EXISTS %I.%I DROP COLUMN IF EXISTS %I',
                             v_schema, v_table, v_column);
        WHEN 'rename_column' THEN
            v_sql := format('ALTER TABLE IF EXISTS %I.%I RENAME COLUMN %I TO %I',
                             v_schema, v_table, v_column, v_new_name);
        WHEN 'alter_column_type' THEN
            v_sql := format('ALTER TABLE IF EXISTS %I.%I ALTER COLUMN %I TYPE %s',
                             v_schema, v_table, v_column, ddl_repl.canonical_type(v_type));
            IF NEW.payload->>'using_expr' IS NOT NULL THEN
                v_sql := ddl_repl.checked_alter_type(v_sql || ' USING ' || (NEW.payload->>'using_expr'),
                                                     v_schema, v_table, v_column);
            END IF;
        WHEN 'alter_column_default' THEN
            -- The default expression isn't deparsed structurally (see
            -- deparse_column.c) -- logged for audit, not replayed unless
            -- this table has opted in to raw-text fallback (see
            -- ddl_repl.enable_raw_fallback).
            IF ddl_repl.allows_raw_fallback(NEW.source_name, v_schema, v_table, v_family, v_op) THEN
                v_sql := ddl_repl.checked_alter_default(NEW.payload->>'ddl_text', v_schema, v_table, v_column);
            ELSE
                v_sql := NULL;
            END IF;
        WHEN 'create_index' THEN
            -- v_index_def is pg_get_indexdef()'s own output (e.g. "CREATE
            -- [UNIQUE] INDEX name ON ..."), already schema-qualified and
            -- complete (columns, opclasses, WHERE clause, INCLUDE, storage
            -- params) -- inject IF NOT EXISTS for idempotency since
            -- pg_get_indexdef() never includes it.
            v_sql := ddl_repl.checked_index_def(
                regexp_replace(v_index_def, '^(CREATE (UNIQUE )?INDEX )', '\1IF NOT EXISTS '),
                v_schema, v_table, v_index);
        WHEN 'rename_constraint' THEN
            v_sql := format('ALTER TABLE IF EXISTS %I.%I RENAME CONSTRAINT %I TO %I',
                            v_schema, v_table, NEW.payload->>'constraint_name', v_new_name);
        WHEN 'validate_constraint' THEN
            v_sql := format('ALTER TABLE IF EXISTS %I.%I VALIDATE CONSTRAINT %I',
                            v_schema, v_table, NEW.payload->>'constraint_name');
        WHEN 'alter_constraint' THEN
            -- Only the properties the publisher changed; identifiers and keywords only, nothing from payload text.
            SELECT string_agg(format('ALTER TABLE IF EXISTS %I.%I ALTER CONSTRAINT %I %s', v_schema, v_table,
                                     NEW.payload->>'constraint_name', clause), '; ')
            INTO v_sql
            FROM (VALUES
                ('deferrability', CASE WHEN (NEW.payload->>'deferrable')::boolean THEN 'DEFERRABLE' ELSE 'NOT DEFERRABLE' END
                                  || CASE WHEN (NEW.payload->>'deferred')::boolean THEN ' INITIALLY DEFERRED'
                                          ELSE ' INITIALLY IMMEDIATE' END),
                ('enforceability', CASE WHEN (NEW.payload->>'enforced')::boolean THEN 'ENFORCED' ELSE 'NOT ENFORCED' END),
                ('inheritability', CASE WHEN (NEW.payload->>'no_inherit')::boolean THEN 'NO INHERIT' ELSE 'INHERIT' END)
            ) a(aspect, clause)
            WHERE position(aspect || ',' IN NEW.payload->>'detail') > 0;
        WHEN 'rename_index' THEN
            v_sql := format('ALTER INDEX IF EXISTS %I.%I RENAME TO %I', v_schema, v_index, v_new_name);
        WHEN 'attach_partition' THEN
            v_sql := ddl_repl.checked_attach_partition(
                format('ALTER TABLE IF EXISTS %I.%I ATTACH PARTITION %I.%I %s', v_schema, v_table,
                       NEW.payload->>'partition_schema', NEW.payload->>'partition_name', NEW.payload->>'partition_bound'),
                v_schema, v_table, NEW.payload->>'partition_name');
        WHEN 'detach_partition' THEN
            v_sql := format('ALTER TABLE IF EXISTS %I.%I DETACH PARTITION %I.%I', v_schema, v_table,
                            NEW.payload->>'partition_schema', NEW.payload->>'partition_name');
        WHEN 'unsupported' THEN
            -- Left unapplied (applied_at NULL) and logged: the divergence is visible instead of silent.
            RAISE WARNING 'pg_ddl_repl: unsupported DDL from % on %.%: %',
                NEW.source_name, v_schema, v_table, NEW.payload->>'detail';
            RETURN NEW;
        WHEN 'drop_index' THEN
            v_sql := format('DROP INDEX IF EXISTS %I.%I', v_schema, v_index);
        WHEN 'set_not_null' THEN
            IF NEW.payload->>'constraint_name' IS NOT NULL AND current_setting('server_version_num')::int >= 180000
               AND NOT EXISTS (SELECT 1 FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
                               WHERE c.conrelid = v_relid AND c.contype = 'n' AND a.attname = v_column) THEN
                v_sql := format('ALTER TABLE IF EXISTS %I.%I ADD CONSTRAINT %I NOT NULL %I%s%s', v_schema, v_table,
                                NEW.payload->>'constraint_name', v_column,
                                CASE WHEN (NEW.payload->>'no_inherit')::boolean THEN ' NO INHERIT' ELSE '' END,
                                CASE WHEN (NEW.payload->>'not_valid')::boolean THEN ' NOT VALID' ELSE '' END);
            ELSE
                v_sql := format('ALTER TABLE IF EXISTS %I.%I ALTER COLUMN %I SET NOT NULL', v_schema, v_table, v_column);
            END IF;
        WHEN 'drop_not_null' THEN
            v_sql := format('ALTER TABLE IF EXISTS %I.%I ALTER COLUMN %I DROP NOT NULL', v_schema, v_table, v_column);
        WHEN 'add_constraint' THEN
            -- Same name: identical definition is a no-op, a different one is a redefinition (drop, then add).
            SELECT ddl_repl.constraint_def(oid) INTO v_existing_def
            FROM pg_constraint WHERE conrelid = v_relid AND conname = NEW.payload->>'constraint_name';
            IF v_existing_def IS NOT NULL THEN
                IF v_existing_def = coalesce(NEW.payload->>'compare_def', NEW.payload->>'constraint_def') THEN
                    UPDATE ddl_repl.command_queue SET applied_at = now()
                    WHERE id = NEW.id AND source_name = NEW.source_name;
                    RETURN NEW;
                END IF;
                v_redefine_sql := format('ALTER TABLE %I.%I DROP CONSTRAINT %I', v_schema, v_table,
                                         NEW.payload->>'constraint_name');
            END IF;
            SELECT conname INTO v_other_pk FROM pg_constraint WHERE conrelid = v_relid AND contype = 'p';
            IF v_other_pk IS NOT NULL AND v_other_pk <> NEW.payload->>'constraint_name'
               AND NEW.payload->>'contype' = 'p' THEN
                RAISE EXCEPTION 'pg_ddl_repl: table %.% already has primary key "%"; the replicated primary key is "%"',
                    v_schema, v_table, v_other_pk, NEW.payload->>'constraint_name';
            END IF;
            v_sql := ddl_repl.checked_add_constraint(
                format('ALTER TABLE IF EXISTS %s%I.%I ADD CONSTRAINT %I %s',
                       CASE WHEN (NEW.payload->>'only')::boolean THEN 'ONLY ' ELSE '' END, v_schema, v_table,
                       NEW.payload->>'constraint_name', NEW.payload->>'constraint_def'),
                v_schema, v_table, NEW.payload->>'constraint_name');
        WHEN 'drop_constraint' THEN
            -- No CASCADE: the publisher's dependents arrive as their own rows; a subscriber-only one stops apply.
            v_sql := format('ALTER TABLE IF EXISTS %I.%I DROP CONSTRAINT IF EXISTS %I',
                            v_schema, v_table, NEW.payload->>'constraint_name');
        ELSE
            v_sql := NULL;
    END CASE;

    IF v_sql IS NOT NULL THEN
        -- No loop-prevention flag to set here: this trigger only ever fires
        -- under session_replication_role = 'replica' (ENABLE REPLICA
        -- TRIGGER), which is exactly what the capture triggers check.
        -- Run as the table owner, like logical replication applies DML: a replayed row can do no more than the owner.
        -- No owner resolved (table gone, or an index of another table): skip rather than run as the apply role.
        SELECT c.relowner INTO v_owner
        FROM pg_class c
        WHERE c.oid = v_relid AND c.relkind IN ('r', 'p')
          AND (v_op <> 'drop_index' OR EXISTS (
                SELECT 1 FROM pg_index i JOIN pg_class x ON x.oid = i.indexrelid
                WHERE i.indrelid = c.oid AND x.relname = v_index AND x.relnamespace = c.relnamespace));
        IF v_owner IS NULL THEN
            -- A drop whose object an earlier replayed drop (table, partition parent, constraint) already removed.
            IF (v_op IN ('drop_table', 'drop_column', 'drop_constraint') AND v_relid IS NULL)
               OR (v_op = 'drop_index' AND to_regclass(quote_ident(v_schema) || '.' || quote_ident(v_index)) IS NULL) THEN
                UPDATE ddl_repl.command_queue SET applied_at = now()
                WHERE id = NEW.id AND source_name = NEW.source_name;
            END IF;
            RETURN NEW;
        END IF;
        IF v_redefine_sql IS NOT NULL THEN
            PERFORM ddl_repl.execute_as(v_redefine_sql, v_owner);
        END IF;
        PERFORM ddl_repl.execute_as(v_sql, v_owner);

        UPDATE ddl_repl.command_queue
            SET applied_at = now()
            WHERE id = NEW.id AND source_name = NEW.source_name;
    END IF;

    RETURN NEW;
END
$$;

CREATE TRIGGER ddl_repl_apply_command
    AFTER INSERT ON ddl_repl.command_queue
    FOR EACH ROW
    EXECUTE FUNCTION ddl_repl.apply_command();

-- Fire only during logical replication apply (session_replication_role =
-- replica), never on a direct/local insert -- this is what keeps the
-- publisher's own capture-side insert from re-applying its own command,
-- with no separate publisher/subscriber role flag needed.
ALTER TABLE ddl_repl.command_queue ENABLE REPLICA TRIGGER ddl_repl_apply_command;
