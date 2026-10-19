#include "postgres.h"
#include "executor/spi.h"
#include "access/htup_details.h"
#include "catalog/pg_attrdef.h"
#include "nodes/readfuncs.h"
#include "optimizer/optimizer.h"
#include "utils/fmgroids.h"
#include "utils/rel.h"
#include "access/genam.h"
#include "access/table.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "utils/guc.h"

PG_MODULE_MAGIC;

/* SUSET, like session_replication_role for loop prevention: the source name routes captured DDL on subscribers,
 * so ordinary roles must not be able to choose it. */
static char *source_name_override = NULL;

void		_PG_init(void);

void
_PG_init(void)
{
	DefineCustomStringVariable("ddl_repl.source_name",
							   "Source name recorded with captured DDL, instead of cluster_name.",
							   NULL,
							   &source_name_override,
							   NULL,
							   PGC_SUSET,
							   0,
							   NULL, NULL, NULL);
	MarkGUCPrefixReserved("ddl_repl");
}

PG_FUNCTION_INFO_V1(ddl_repl_source_name_override);

Datum
ddl_repl_source_name_override(PG_FUNCTION_ARGS)
{
	if (source_name_override == NULL || source_name_override[0] == '\0')
		PG_RETURN_NULL();
	PG_RETURN_TEXT_P(cstring_to_text(source_name_override));
}

/* Same switch as logical replication's SwitchToUntrustedUser: a restricted operation cannot change role back. */
PG_FUNCTION_INFO_V1(ddl_repl_execute_as);

Datum
ddl_repl_execute_as(PG_FUNCTION_ARGS)
{
	char	   *sql = text_to_cstring(PG_GETARG_TEXT_PP(0));
	Oid			role = PG_GETARG_OID(1);
	Oid			save_userid;
	int			save_sec_context;
	int			save_nestlevel;

	GetUserIdAndSecContext(&save_userid, &save_sec_context);
	SetUserIdAndSecContext(role, save_sec_context | SECURITY_LOCAL_USERID_CHANGE | SECURITY_RESTRICTED_OPERATION);
	save_nestlevel = NewGUCNestLevel();

	SPI_connect();
	if (SPI_execute(sql, false, 0) < 0)
		elog(ERROR, "pg_ddl_repl: could not execute replicated command");
	SPI_finish();

	AtEOXact_GUC(false, save_nestlevel);
	SetUserIdAndSecContext(save_userid, save_sec_context);
	PG_RETURN_VOID();
}

/* A non-immutable default (now, nextval, random) gives each node different values: not replicable. */
PG_FUNCTION_INFO_V1(ddl_repl_default_is_mutable);

Datum
ddl_repl_default_is_mutable(PG_FUNCTION_ARGS)
{
	Oid			relid = PG_GETARG_OID(0);
	int16		attnum = PG_GETARG_INT16(1);
	Relation	attrdef = table_open(AttrDefaultRelationId, AccessShareLock);
	ScanKeyData keys[2];
	SysScanDesc scan;
	HeapTuple	tuple;
	bool		mutable_default = false;

	ScanKeyInit(&keys[0], Anum_pg_attrdef_adrelid, BTEqualStrategyNumber, F_OIDEQ, ObjectIdGetDatum(relid));
	ScanKeyInit(&keys[1], Anum_pg_attrdef_adnum, BTEqualStrategyNumber, F_INT2EQ, Int16GetDatum(attnum));
	scan = systable_beginscan(attrdef, AttrDefaultIndexId, true, NULL, 2, keys);
	if (HeapTupleIsValid(tuple = systable_getnext(scan)))
	{
		bool		isnull;
		Datum		adbin = heap_getattr(tuple, Anum_pg_attrdef_adbin, RelationGetDescr(attrdef), &isnull);

		if (!isnull)
			mutable_default = contain_mutable_functions(stringToNode(TextDatumGetCString(adbin)));
	}
	systable_endscan(scan);
	table_close(attrdef, AccessShareLock);
	PG_RETURN_BOOL(mutable_default);
}
