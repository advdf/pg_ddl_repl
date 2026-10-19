#include "postgres.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "catalog/index.h"
#include "access/htup_details.h"
#include "catalog/namespace.h"
#include "catalog/pg_constraint.h"
#include "utils/lsyscache.h"
#include "utils/syscache.h"
#include "catalog/pg_type.h"
#include "nodes/makefuncs.h"
#include "nodes/parsenodes.h"
#include "tcop/deparse_utility.h"
#include "lib/stringinfo.h"
#include "utils/builtins.h"

#include "compat.h"

/*
 * ddl_repl_deparse_extra(pg_ddl_command) -> zero or more rows of
 *   (operation text, table_oid oid, name text, new_name text, related_oid oid, detail text)
 */
PG_FUNCTION_INFO_V1(ddl_repl_deparse_extra);

static void
emit(Tuplestorestate *tupstore, AttInMetadata *attinmeta, const char *operation, Oid table_oid,
	 const char *name, const char *new_name, Oid related_oid, const char *detail)
{
	char	   *values[6];

	values[0] = (char *) operation;
	values[1] = OidIsValid(table_oid) ? psprintf("%u", table_oid) : NULL;
	values[2] = (char *) name;
	values[3] = (char *) new_name;
	values[4] = OidIsValid(related_oid) ? psprintf("%u", related_oid) : NULL;
	values[5] = (char *) detail;
	tuplestore_puttuple(tupstore, BuildTupleFromCStrings(attinmeta, values));
}

/* Resolved from oids, never names: capture runs with search_path pinned to pg_catalog. */
static Oid
constraint_relid(Oid constraint_oid)
{
	HeapTuple	tuple = SearchSysCache1(CONSTROID, ObjectIdGetDatum(constraint_oid));
	Oid			relid = InvalidOid;

	if (HeapTupleIsValid(tuple))
	{
		relid = ((Form_pg_constraint) GETSTRUCT(tuple))->conrelid;
		ReleaseSysCache(tuple);
	}
	return relid;
}

/* Which properties an ALTER CONSTRAINT changes: only those are replayed. */
static const char *
altered_aspects(Node *def)
{
#ifdef DDL_REPL_HAS_AT_ALTER_CONSTRAINT
	ATAlterConstraint *alter = castNode(ATAlterConstraint, def);
	StringInfoData aspects;

	initStringInfo(&aspects);
	if (alter->alterDeferrability)
		appendStringInfoString(&aspects, "deferrability,");
	if (alter->alterEnforceability)
		appendStringInfoString(&aspects, "enforceability,");
	if (alter->alterInheritability)
		appendStringInfoString(&aspects, "inheritability,");
	return aspects.data;
#else
	return "deferrability,";
#endif
}

/* Schema-affecting ALTER TABLE subcommands with no replay: reported so the divergence is visible. */
static const char *
unsupported_subcommand(AlterTableType subtype)
{
	switch (subtype)
	{
		case AT_AddIdentity:
		case AT_SetIdentity:
		case AT_DropIdentity:
			return "identity column change";
		case AT_DropExpression:
#if PG_VERSION_NUM >= 170000
		case AT_SetExpression:
#endif
			return "generated column expression change";
		case AT_AddInherit:
		case AT_DropInherit:
			return "inheritance change";
		case AT_AddOf:
		case AT_DropOf:
			return "typed table change";
		case AT_ReplicaIdentity:
			return "replica identity change";
		case AT_SetLogged:
		case AT_SetUnLogged:
			return "logged/unlogged change";
		case AT_DetachPartitionFinalize:
			return "DETACH PARTITION FINALIZE";
		default:
			return NULL;
	}
}

Datum
ddl_repl_deparse_extra(PG_FUNCTION_ARGS)
{
	CollectedCommand *cmd = (CollectedCommand *) PG_GETARG_POINTER(0);
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	TupleDesc	tupdesc;
	Tuplestorestate *tupstore;
	MemoryContext oldcontext;
	AttInMetadata *attinmeta;

	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in context that cannot accept a set")));
	if (!(rsinfo->allowedModes & SFRM_Materialize))
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("materialize mode required, but it is not allowed in this context")));

	oldcontext = MemoryContextSwitchTo(rsinfo->econtext->ecxt_per_query_memory);

	tupdesc = CreateTemplateTupleDesc(6);
	TupleDescInitEntry(tupdesc, (AttrNumber) 1, "operation", TEXTOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 2, "table_oid", OIDOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 3, "name", TEXTOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 4, "new_name", TEXTOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 5, "related_oid", OIDOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber) 6, "detail", TEXTOID, -1, 0);

	tupstore = tuplestore_begin_heap((rsinfo->allowedModes & SFRM_Materialize_Random) != 0, false, work_mem);
	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = tupstore;
	rsinfo->setDesc = tupdesc;

	MemoryContextSwitchTo(oldcontext);
	attinmeta = TupleDescGetAttInMetadata(tupdesc);

	if (cmd->type == SCT_Simple && IsA(cmd->parsetree, RenameStmt))
	{
		RenameStmt *stmt = castNode(RenameStmt, cmd->parsetree);

		if (stmt->renameType == OBJECT_TABCONSTRAINT)
			emit(tupstore, attinmeta, "rename_constraint", constraint_relid(cmd->d.simple.address.objectId),
				 stmt->subname, stmt->newname, InvalidOid, NULL);
		else if (stmt->renameType == OBJECT_INDEX)
			emit(tupstore, attinmeta, "rename_index", IndexGetRelation(cmd->d.simple.address.objectId, false),
				 stmt->relation->relname, stmt->newname, cmd->d.simple.address.objectId, NULL);
	}
	else if (cmd->type == SCT_Simple && IsA(cmd->parsetree, AlterObjectSchemaStmt))
	{
		AlterObjectSchemaStmt *stmt = castNode(AlterObjectSchemaStmt, cmd->parsetree);

		if (stmt->objectType == OBJECT_TABLE)
			emit(tupstore, attinmeta, "unsupported", cmd->d.simple.address.objectId, NULL, NULL, InvalidOid,
				 "SET SCHEMA");
	}
	else if (cmd->type == SCT_AlterTable && IsA(cmd->parsetree, AlterTableStmt))
	{
		Oid			table_oid = cmd->d.alterTable.objectId;
		ListCell   *cell;

		foreach(cell, cmd->d.alterTable.subcmds)
		{
			CollectedATSubcmd *sub = lfirst(cell);
			AlterTableCmd *subcmd = castNode(AlterTableCmd, sub->parsetree);
			const char *unsupported = unsupported_subcommand(subcmd->subtype);

			if (DDL_REPL_IS_VALIDATE_CONSTRAINT(subcmd->subtype))
				emit(tupstore, attinmeta, "validate_constraint", table_oid, subcmd->name, NULL, InvalidOid, NULL);
			else if (subcmd->subtype == AT_AlterConstraint)
				emit(tupstore, attinmeta, "alter_constraint", table_oid,
					 DDL_REPL_ALTER_CONSTRAINT_NAME(subcmd->def), NULL, InvalidOid, altered_aspects(subcmd->def));
			else if (subcmd->subtype == AT_AttachPartition || subcmd->subtype == AT_DetachPartition)
			{
				PartitionCmd *pc = castNode(PartitionCmd, subcmd->def);
				Oid			partition_oid = sub->address.objectId;

				/* PG15 reports no address for DETACH: qualify the name explicitly, never via the pinned search_path. */
				if (!OidIsValid(partition_oid))
					partition_oid = RangeVarGetRelid(makeRangeVar(pc->name->schemaname ? pc->name->schemaname
																  : get_namespace_name(get_rel_namespace(table_oid)),
																  pc->name->relname, -1),
													 NoLock, true);
				emit(tupstore, attinmeta,
					 subcmd->subtype == AT_AttachPartition ? "attach_partition" : "detach_partition",
					 table_oid, pc->name->relname, NULL, partition_oid,
					 OidIsValid(partition_oid) ? NULL : pc->name->schemaname);
			}
			else if (unsupported != NULL)
				emit(tupstore, attinmeta, "unsupported", table_oid, NULL, NULL, InvalidOid, unsupported);
		}
	}

	return (Datum) 0;
}
