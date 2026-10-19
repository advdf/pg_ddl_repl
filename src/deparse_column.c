#include "postgres.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "catalog/pg_attribute.h"
#include "catalog/pg_type.h"
#include "nodes/parsenodes.h"
#include "tcop/deparse_utility.h"
#include "utils/builtins.h"
#include "utils/ruleutils.h"
#include "utils/syscache.h"

#include "compat.h"

/*
 * ddl_repl_deparse_column(pg_ddl_command) -> zero or one row of
 *   (operation text, table_name text, table_oid oid, column_name text,
 *    new_name text, type_name text)
 *
 * Handles the column-family commands: ALTER TABLE ADD/ALTER TYPE column
 * (SCT_AlterTable subcommands) and ALTER TABLE ... RENAME COLUMN
 * (SCT_Simple/RenameStmt -- structurally identical to a table rename, but
 * grouped here because that's the family a DBA filters it by).
 *
 * DROP COLUMN is deliberately NOT handled here: by ddl_command_end time
 * there is nothing left to introspect about a dropped column, so it is
 * captured from the sql_drop event trigger instead (see
 * ddl_repl.capture_sql_drop in the SQL script). AT_DropColumn subcommands
 * are skipped below to avoid double-capture.
 *
 * ALTER TABLE ... SET/DROP DEFAULT is captured (operation
 * 'alter_column_default') but the new default expression itself is not
 * deparsed -- reusing core's general expression deparser is out of scope
 * for v1. The caller falls back to the verbatim command text for that case.
 */
PG_FUNCTION_INFO_V1(ddl_repl_deparse_column);

static char *
get_column_name(AlterTableCmd *subcmd)
{
	if (subcmd->name != NULL)
		return subcmd->name;

	if (subcmd->def != NULL && IsA(subcmd->def, ColumnDef))
		return castNode(ColumnDef, subcmd->def)->colname;

	return NULL;
}

/* USING is kept by parse analysis as the transformed expression; render it like pg_get_expr does. */
static char *
get_using_expr(AlterTableCmd *subcmd, const char *relname, Oid relid)
{
	ColumnDef  *def = (subcmd->def != NULL && IsA(subcmd->def, ColumnDef))
		? castNode(ColumnDef, subcmd->def) : NULL;

	if (def == NULL || def->cooked_default == NULL)
		return NULL;
	return deparse_expression(def->cooked_default,
							  deparse_context_for(relname, relid),
							  false, false);
}

/* Read back from the catalog: the statement's type name depends on the caller's search_path, the column's type does not. */
static char *
get_type_name(Oid relid, const char *column)
{
	HeapTuple	tup;
	Form_pg_attribute att;
	char	   *type_name;

	if (column == NULL)
		return NULL;

	tup = SearchSysCacheAttName(relid, column);
	if (!HeapTupleIsValid(tup))
		return NULL;
	att = (Form_pg_attribute) GETSTRUCT(tup);
	type_name = format_type_extended(att->atttypid, att->atttypmod, FORMAT_TYPE_TYPEMOD_GIVEN);
	ReleaseSysCache(tup);

	return type_name;
}

Datum
ddl_repl_deparse_column(PG_FUNCTION_ARGS)
{
	CollectedCommand *cmd = (CollectedCommand *) PG_GETARG_POINTER(0);
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	TupleDesc	tupdesc;
	Tuplestorestate *tupstore;
	MemoryContext oldcontext;
	AttInMetadata *attinmeta;
	bool		randomAccess;
	char	   *values[7] = {0};
	bool		matched = false;

	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in context that cannot accept a set")));
	if (!(rsinfo->allowedModes & SFRM_Materialize))
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("materialize mode required, but it is not allowed in this context")));

	oldcontext = MemoryContextSwitchTo(rsinfo->econtext->ecxt_per_query_memory);

	tupdesc = CreateTemplateTupleDesc(7);
	TupleDescInitEntry(tupdesc, (AttrNumber) 1, "operation", TEXTOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 2, "table_name", TEXTOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 3, "column_name", TEXTOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 4, "new_name", TEXTOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 5, "type_name", TEXTOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 6, "table_oid", OIDOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 7, "using_expr", TEXTOID, -1, 0);

	randomAccess = (rsinfo->allowedModes & SFRM_Materialize_Random) != 0;
	tupstore = tuplestore_begin_heap(randomAccess, false, work_mem);
	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = tupstore;
	rsinfo->setDesc = tupdesc;

	MemoryContextSwitchTo(oldcontext);
	attinmeta = TupleDescGetAttInMetadata(tupdesc);


	if (cmd->type == SCT_Simple && IsA(cmd->parsetree, RenameStmt))
	{
		RenameStmt *stmt = castNode(RenameStmt, cmd->parsetree);

		if (stmt->renameType == OBJECT_COLUMN)
		{
			values[0] = "rename_column";
			values[1] = stmt->relation->relname;
			values[2] = stmt->subname;
			values[3] = stmt->newname;
			values[4] = NULL;
			/* Columns address as (RelationRelationId, table oid, attnum). */
			values[5] = psprintf("%u", cmd->d.simple.address.objectId);
			matched = true;
		}
	}
	else if (cmd->type == SCT_AlterTable && IsA(cmd->parsetree, AlterTableStmt))
	{
		AlterTableStmt *atstmt = castNode(AlterTableStmt, cmd->parsetree);
		ListCell   *cell;

		foreach(cell, cmd->d.alterTable.subcmds)
		{
			CollectedATSubcmd *sub = lfirst(cell);
			AlterTableCmd *subcmd = castNode(AlterTableCmd, sub->parsetree);

			for (int i = 0; i < lengthof(values); i++)
				values[i] = NULL;
			values[1] = atstmt->relation->relname;
			values[2] = get_column_name(subcmd);
			values[5] = psprintf("%u", cmd->d.alterTable.objectId);

			if (DDL_REPL_IS_ADD_COLUMN(subcmd->subtype))
			{
				values[0] = "add_column";
				values[4] = get_type_name(cmd->d.alterTable.objectId, values[2]);
				matched = true;
			}
			else if (DDL_REPL_IS_DROP_COLUMN(subcmd->subtype))
			{
				/* handled via sql_drop instead -- skip here */
				continue;
			}
			else if (subcmd->subtype == AT_AlterColumnType)
			{
				values[0] = "alter_column_type";
				values[4] = get_type_name(cmd->d.alterTable.objectId, values[2]);
				values[6] = get_using_expr(subcmd, atstmt->relation->relname, cmd->d.alterTable.objectId);
				matched = true;
			}
			else if (subcmd->subtype == AT_ColumnDefault)
			{
				values[0] = "alter_column_default";
				matched = true;
			}
			else
				continue;

			{
				HeapTuple	tuple = BuildTupleFromCStrings(attinmeta, values);

				tuplestore_puttuple(tupstore, tuple);
			}
		}

		return (Datum) 0;
	}

	if (matched)
	{
		HeapTuple	tuple = BuildTupleFromCStrings(attinmeta, values);

		tuplestore_puttuple(tupstore, tuple);
	}

	return (Datum) 0;
}
