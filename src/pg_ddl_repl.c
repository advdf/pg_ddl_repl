#include "postgres.h"
#include "executor/spi.h"
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
