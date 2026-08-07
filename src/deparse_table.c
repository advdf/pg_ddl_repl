#include "postgres.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "catalog/pg_type.h"
#include "nodes/parsenodes.h"
#include "tcop/deparse_utility.h"
#include "utils/builtins.h"

/*
 * ddl_repl_deparse_table(pg_ddl_command) -> zero or one row of
 *   (operation text, schema_name text, table_name text, table_oid oid,
 *    new_name text)
 *
 * Handles the table-family SCT_Simple commands: CREATE TABLE and
 * ALTER TABLE ... RENAME TO. Anything else yields an empty set, so the
 * caller (the ddl_command_end PL/pgSQL event trigger) can try this
 * function alongside the column/index deparse modules without needing to
 * know in advance which family a given command belongs to.
 */
PG_FUNCTION_INFO_V1(ddl_repl_deparse_table);

Datum
ddl_repl_deparse_table(PG_FUNCTION_ARGS)
{
	CollectedCommand *cmd = (CollectedCommand *) PG_GETARG_POINTER(0);
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	TupleDesc	tupdesc;
	Tuplestorestate *tupstore;
	MemoryContext oldcontext;
	AttInMetadata *attinmeta;
	bool		randomAccess;
	char	   *values[4];
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

	tupdesc = CreateTemplateTupleDesc(4);
	TupleDescInitEntry(tupdesc, (AttrNumber) 1, "operation", TEXTOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 2, "table_name", TEXTOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 3, "table_oid", OIDOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 4, "new_name", TEXTOID, -1, 0);

	randomAccess = (rsinfo->allowedModes & SFRM_Materialize_Random) != 0;
	tupstore = tuplestore_begin_heap(randomAccess, false, work_mem);
	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = tupstore;
	rsinfo->setDesc = tupdesc;

	MemoryContextSwitchTo(oldcontext);
	attinmeta = TupleDescGetAttInMetadata(tupdesc);

	memset(values, 0, sizeof(values));

	if (cmd->type == SCT_Simple)
	{
		Node	   *parsetree = cmd->parsetree;

		if (IsA(parsetree, CreateStmt))
		{
			CreateStmt *stmt = castNode(CreateStmt, parsetree);

			values[0] = "create_table";
			values[1] = stmt->relation->relname;
			values[2] = psprintf("%u", cmd->d.simple.address.objectId);
			values[3] = NULL;
			matched = true;
		}
		else if (IsA(parsetree, RenameStmt))
		{
			RenameStmt *stmt = castNode(RenameStmt, parsetree);

			if (stmt->renameType == OBJECT_TABLE)
			{
				values[0] = "rename_table";
				values[1] = stmt->relation->relname;
				values[2] = psprintf("%u", cmd->d.simple.address.objectId);
				values[3] = stmt->newname;
				matched = true;
			}
		}
	}

	if (matched)
	{
		HeapTuple	tuple = BuildTupleFromCStrings(attinmeta, values);

		tuplestore_puttuple(tupstore, tuple);
	}

	return (Datum) 0;
}
