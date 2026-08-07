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
    table_oid oid
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

-- By the time DROP INDEX fires sql_drop, pg_index no longer has the row --
-- confirmed empirically (indrelid lookup by indexrelid returns NULL at that
-- point) -- so the owning table's oid can't be resolved from catalogs at
-- drop time. This tiny table is our own record, populated when CREATE
-- INDEX is captured (while the index still exists) and consulted instead.
CREATE TABLE ddl_repl.index_table_map (
    index_oid oid PRIMARY KEY,
    table_oid oid NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL
);

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
    object_family text NOT NULL CHECK (object_family IN ('table', 'column', 'index')),
    operation text NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    UNIQUE NULLS NOT DISTINCT (relid, object_family, operation)
);

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
    object_family text NOT NULL CHECK (object_family IN ('table', 'column', 'index')),
    operation text NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    -- Opt-in only: replay the captured command text for operations without
    -- a structured deparse (currently just 'alter_column_default') instead
    -- of leaving them as an audit-only, unapplied row. The text is a single
    -- statement rebuilt from the catalogs at capture time (see
    -- build_alter_default_sql), never the client's verbatim input. Still
    -- off by default -- names inside the default expression are rendered
    -- relative to the publisher's search_path and may resolve differently
    -- on the subscriber.
    allow_raw_fallback boolean NOT NULL DEFAULT false,
    CHECK ((schema_name IS NULL) = (table_name IS NULL)),
    UNIQUE NULLS NOT DISTINCT (source_name, schema_name, table_name, object_family, operation)
);

CREATE FUNCTION ddl_repl.is_published(p_relid oid, p_family text, p_operation text)
RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT coalesce(
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

-- Convenience: enable every known operation, across all 3 families, for one
-- table (publish side) or one (source, table) pair (subscribe side).
CREATE FUNCTION ddl_repl.publish_table(p_relid oid)
RETURNS void
LANGUAGE sql AS $$
    INSERT INTO ddl_repl.publish_rules (relid, object_family, operation)
    VALUES
        (p_relid, 'table', 'create_table'),
        (p_relid, 'table', 'rename_table'),
        (p_relid, 'table', 'drop_table'),
        (p_relid, 'column', 'add_column'),
        (p_relid, 'column', 'drop_column'),
        (p_relid, 'column', 'rename_column'),
        (p_relid, 'column', 'alter_column_type'),
        (p_relid, 'column', 'alter_column_default'),
        (p_relid, 'index', 'create_index'),
        (p_relid, 'index', 'drop_index')
    ON CONFLICT (relid, object_family, operation) DO UPDATE SET enabled = true
$$;

CREATE FUNCTION ddl_repl.subscribe_table(p_source_name text, p_schema text, p_table text)
RETURNS void
LANGUAGE sql AS $$
    INSERT INTO ddl_repl.subscribe_rules (source_name, schema_name, table_name, object_family, operation)
    VALUES
        (p_source_name, p_schema, p_table, 'table', 'create_table'),
        (p_source_name, p_schema, p_table, 'table', 'rename_table'),
        (p_source_name, p_schema, p_table, 'table', 'drop_table'),
        (p_source_name, p_schema, p_table, 'column', 'add_column'),
        (p_source_name, p_schema, p_table, 'column', 'drop_column'),
        (p_source_name, p_schema, p_table, 'column', 'rename_column'),
        (p_source_name, p_schema, p_table, 'column', 'alter_column_type'),
        (p_source_name, p_schema, p_table, 'column', 'alter_column_default'),
        (p_source_name, p_schema, p_table, 'index', 'create_index'),
        (p_source_name, p_schema, p_table, 'index', 'drop_index')
    ON CONFLICT (source_name, schema_name, table_name, object_family, operation) DO UPDATE SET enabled = true
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

CREATE FUNCTION ddl_repl.capture_ddl_command_end()
RETURNS event_trigger
LANGUAGE plpgsql
AS $$
DECLARE
    obj record;
    line record;
    v_source text := coalesce(
        current_setting('ddl_repl.source_name', true),
        nullif(current_setting('cluster_name', true), ''),
        current_database()
    );
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
        END LOOP;

        FOR line IN SELECT * FROM ddl_repl.deparse_column(obj.command)
        LOOP
            IF ddl_repl.is_published(line.table_oid, 'column', line.operation) THEN
                INSERT INTO ddl_repl.command_queue (source_name, payload)
                VALUES (
                    v_source,
                    jsonb_build_object(
                        'schema_version', 1,
                        'object_family', 'column',
                        'operation', line.operation,
                        'schema_name', obj.schema_name,
                        'table_name', line.table_name,
                        'table_oid', line.table_oid,
                        'column_name', line.column_name,
                        'new_name', line.new_name,
                        'type_name', line.type_name,
                        -- Only 'alter_column_default' relies on this: the new
                        -- default expression isn't deparsed structurally (see
                        -- deparse_column.c), so a single rebuilt statement is
                        -- kept as an opt-in raw-replay fallback.
                        'ddl_text', CASE WHEN line.operation = 'alter_column_default'
                                         THEN ddl_repl.build_alter_default_sql(line.table_oid, line.column_name) END
                    )
                );
            END IF;
        END LOOP;

        FOR line IN SELECT * FROM ddl_repl.deparse_index(obj.command)
        LOOP
            DECLARE
                v_table_oid oid := (SELECT indrelid FROM pg_index WHERE indexrelid = line.index_oid);
            BEGIN
                IF ddl_repl.is_published(v_table_oid, 'index', line.operation) THEN
                    INSERT INTO ddl_repl.index_table_map (index_oid, table_oid, schema_name, table_name)
                    VALUES (line.index_oid, v_table_oid, obj.schema_name, line.table_name)
                    ON CONFLICT (index_oid) DO NOTHING;

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
                            'index_def', pg_get_indexdef(line.index_oid)
                        )
                    );
                END IF;
            END;
        END LOOP;
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
AS $$
DECLARE
    obj record;
    v_source text := coalesce(
        current_setting('ddl_repl.source_name', true),
        nullif(current_setting('cluster_name', true), ''),
        current_database()
    );
BEGIN
    -- Same loop-prevention as capture_ddl_command_end: skip while a
    -- subscription apply worker (session_replication_role = 'replica') is
    -- replaying a command.
    IF current_setting('session_replication_role') = 'replica' THEN
        RETURN;
    END IF;

    FOR obj IN
        SELECT * FROM pg_event_trigger_dropped_objects()
        WHERE object_type IN ('table', 'table column', 'index')
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
    v_old_path text;
BEGIN
    IF v_family NOT IN ('table', 'column', 'index') THEN
        RETURN NEW;
    END IF;

    IF NOT ddl_repl.is_subscribed(NEW.source_name, v_schema, v_table, v_family, v_op) THEN
        RETURN NEW;
    END IF;

    CASE v_op
        WHEN 'rename_table' THEN
            v_sql := format('ALTER TABLE IF EXISTS %I.%I RENAME TO %I', v_schema, v_table, v_new_name);
        WHEN 'drop_table' THEN
            v_sql := format('DROP TABLE IF EXISTS %I.%I', v_schema, v_table);
        WHEN 'create_table' THEN
            -- Structured deparse doesn't carry a column list yet (see
            -- deparse_table.c) -- logged for audit, not replayed in v1.
            v_sql := NULL;
        WHEN 'add_column' THEN
            v_sql := format('ALTER TABLE IF EXISTS %I.%I ADD COLUMN IF NOT EXISTS %I %s',
                             v_schema, v_table, v_column, v_type);
        WHEN 'drop_column' THEN
            v_sql := format('ALTER TABLE IF EXISTS %I.%I DROP COLUMN IF EXISTS %I',
                             v_schema, v_table, v_column);
        WHEN 'rename_column' THEN
            v_sql := format('ALTER TABLE IF EXISTS %I.%I RENAME COLUMN %I TO %I',
                             v_schema, v_table, v_column, v_new_name);
        WHEN 'alter_column_type' THEN
            v_sql := format('ALTER TABLE IF EXISTS %I.%I ALTER COLUMN %I TYPE %s',
                             v_schema, v_table, v_column, v_type);
        WHEN 'alter_column_default' THEN
            -- The default expression isn't deparsed structurally (see
            -- deparse_column.c) -- logged for audit, not replayed unless
            -- this table has opted in to raw-text fallback (see
            -- ddl_repl.enable_raw_fallback).
            IF ddl_repl.allows_raw_fallback(NEW.source_name, v_schema, v_table, v_family, v_op) THEN
                v_sql := NEW.payload->>'ddl_text';
                -- ddl_text fully qualifies the table (see
                -- build_alter_default_sql), but names *inside* the default
                -- expression are rendered by pg_get_expr relative to the
                -- publisher's search_path -- approximate that here with the
                -- table's schema (quoted: it may need it), and restore the
                -- previous path after EXECUTE so it can't leak into later
                -- rows applied in this same transaction.
                v_old_path := current_setting('search_path');
                PERFORM set_config('search_path', quote_ident(v_schema), true);
            ELSE
                v_sql := NULL;
            END IF;
        WHEN 'create_index' THEN
            -- v_index_def is pg_get_indexdef()'s own output (e.g. "CREATE
            -- [UNIQUE] INDEX name ON ..."), already schema-qualified and
            -- complete (columns, opclasses, WHERE clause, INCLUDE, storage
            -- params) -- inject IF NOT EXISTS for idempotency since
            -- pg_get_indexdef() never includes it.
            v_sql := regexp_replace(v_index_def, '^(CREATE (UNIQUE )?INDEX )', '\1IF NOT EXISTS ');
        WHEN 'drop_index' THEN
            v_sql := format('DROP INDEX IF EXISTS %I.%I', v_schema, v_index);
        ELSE
            v_sql := NULL;
    END CASE;

    IF v_sql IS NOT NULL THEN
        -- No loop-prevention flag to set here: this trigger only ever fires
        -- under session_replication_role = 'replica' (ENABLE REPLICA
        -- TRIGGER), which is exactly what the capture triggers check.
        EXECUTE v_sql;

        IF v_old_path IS NOT NULL THEN
            PERFORM set_config('search_path', v_old_path, true);
        END IF;

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
