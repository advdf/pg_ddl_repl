#include "postgres.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "catalog/pg_type.h"
#include "nodes/parsenodes.h"
#include "tcop/deparse_utility.h"
#include "utils/builtins.h"

/*
 * ddl_repl_deparse_index(pg_ddl_command) -> zero or one row of
 *   (operation text, table_name text, index_oid oid)
 *
 * Handles CREATE INDEX only (SCT_Simple/IndexStmt) -- a plain top-level
 * statement, structurally independent of the ALTER TABLE subcommand
 * machinery in deparse_column.c. DROP INDEX is captured from sql_drop
 * instead (object_type = 'index' already gives a direct, fully-structured
 * object_name -- no C-level introspection needed there).
 *
 * The full index definition text (columns, opclasses, WHERE clause for
 * partial indexes, INCLUDE columns, storage params...) is deliberately not
 * reconstructed here from the parse tree -- core's own pg_get_indexdef()
 * already produces a complete, correct CREATE INDEX statement from the
 * index_oid, which is far more robust than hand-walking IndexStmt's many
 * optional fields. The SQL wrapper calls it directly.
 */
PG_FUNCTION_INFO_V1(ddl_repl_deparse_index);

Datum
ddl_repl_deparse_index(PG_FUNCTION_ARGS)
{
	CollectedCommand *cmd = (CollectedCommand *) PG_GETARG_POINTER(0);
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	TupleDesc	tupdesc;
	Tuplestorestate *tupstore;
	MemoryContext oldcontext;
	AttInMetadata *attinmeta;
	bool		randomAccess;
	char	   *values[3] = {0};
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

	tupdesc = CreateTemplateTupleDesc(3);
	TupleDescInitEntry(tupdesc, (AttrNumber) 1, "operation", TEXTOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 2, "table_name", TEXTOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 3, "index_oid", OIDOID, -1, 0);

	randomAccess = (rsinfo->allowedModes & SFRM_Materialize_Random) != 0;
	tupstore = tuplestore_begin_heap(randomAccess, false, work_mem);
	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = tupstore;
	rsinfo->setDesc = tupdesc;

	MemoryContextSwitchTo(oldcontext);
	attinmeta = TupleDescGetAttInMetadata(tupdesc);


	if (cmd->type == SCT_Simple && IsA(cmd->parsetree, IndexStmt))
	{
		IndexStmt  *stmt = castNode(IndexStmt, cmd->parsetree);

		values[0] = "create_index";
		values[1] = stmt->relation->relname;
		values[2] = psprintf("%u", cmd->d.simple.address.objectId);
		matched = true;
	}

	if (matched)
	{
		HeapTuple	tuple = BuildTupleFromCStrings(attinmeta, values);

		tuplestore_puttuple(tupstore, tuple);
	}

	return (Datum) 0;
}
