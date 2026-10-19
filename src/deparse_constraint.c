#include "postgres.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "catalog/dependency.h"
#include "catalog/pg_type.h"
#include "nodes/parsenodes.h"
#include "tcop/deparse_utility.h"
#include "utils/builtins.h"

#include "compat.h"

/*
 * ddl_repl_deparse_constraint(pg_ddl_command) -> zero or more rows of
 *   (operation text, table_name text, table_oid oid, constraint_oid oid, index_oid oid, constraint_name text,
 *    is_only boolean)
 */
PG_FUNCTION_INFO_V1(ddl_repl_deparse_constraint);

Datum
ddl_repl_deparse_constraint(PG_FUNCTION_ARGS)
{
	CollectedCommand *cmd = (CollectedCommand *) PG_GETARG_POINTER(0);
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	TupleDesc	tupdesc;
	Tuplestorestate *tupstore;
	MemoryContext oldcontext;
	AttInMetadata *attinmeta;
	ListCell   *cell;

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
	TupleDescInitEntry(tupdesc, (AttrNumber) 3, "table_oid", OIDOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 4, "constraint_oid", OIDOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 5, "index_oid", OIDOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 6, "constraint_name", TEXTOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 7, "is_only", BOOLOID, -1, 0);

	tupstore = tuplestore_begin_heap((rsinfo->allowedModes & SFRM_Materialize_Random) != 0, false, work_mem);
	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = tupstore;
	rsinfo->setDesc = tupdesc;

	MemoryContextSwitchTo(oldcontext);
	attinmeta = TupleDescGetAttInMetadata(tupdesc);

	if (cmd->type != SCT_AlterTable || !IsA(cmd->parsetree, AlterTableStmt))
		return (Datum) 0;

	foreach(cell, cmd->d.alterTable.subcmds)
	{
		CollectedATSubcmd *sub = lfirst(cell);
		AlterTableCmd *subcmd = castNode(AlterTableCmd, sub->parsetree);
		char	   *values[7] = {0};
		Oid			constraint_oid = sub->address.objectId;

		/* Constraints rebuilt by a column type change come back as AT_ReAdd*: only user-added ones are captured. */
		if (subcmd->subtype == AT_AddIndex && subcmd->def != NULL && IsA(subcmd->def, IndexStmt) &&
			castNode(IndexStmt, subcmd->def)->isconstraint)
			constraint_oid = get_index_constraint(sub->address.objectId);	/* PRIMARY KEY, UNIQUE, EXCLUDE */
		else if (!DDL_REPL_IS_ADD_CONSTRAINT(subcmd->subtype) && subcmd->subtype != AT_AddIndexConstraint)
			continue;
		if (!OidIsValid(constraint_oid))
			continue;

		values[0] = "add_constraint";
		values[1] = castNode(AlterTableStmt, cmd->parsetree)->relation->relname;
		values[2] = psprintf("%u", cmd->d.alterTable.objectId);
		values[3] = psprintf("%u", constraint_oid);
		/* USING INDEX: the existing index, whose original name the SQL side replays. */
		if (subcmd->subtype == AT_AddIndexConstraint && subcmd->def != NULL && IsA(subcmd->def, IndexStmt))
			values[4] = psprintf("%u", castNode(IndexStmt, subcmd->def)->indexOid);
		/* By name too: a type change in the same statement rebuilds the constraint under a new oid. */
		if (subcmd->def != NULL && IsA(subcmd->def, Constraint))
			values[5] = ((Constraint *) subcmd->def)->conname;
		else if (subcmd->def != NULL && IsA(subcmd->def, IndexStmt))
			values[5] = castNode(IndexStmt, subcmd->def)->idxname;
		values[6] = castNode(AlterTableStmt, cmd->parsetree)->relation->inh ? "f" : "t";
		tuplestore_puttuple(tupstore, BuildTupleFromCStrings(attinmeta, values));
	}

	return (Datum) 0;
}
