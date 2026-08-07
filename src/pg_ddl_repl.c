#include "postgres.h"
#include "fmgr.h"
#include "utils/guc.h"

#include "compat.h"

PG_MODULE_MAGIC;

/*
 * Set (transaction-locally) by the apply-side trigger while it replays a
 * captured command, and checked by the capture-side event triggers to
 * short-circuit -- otherwise a subscriber re-executing DDL would recapture
 * and re-queue it, looping forever in any bidirectional/cascading setup.
 */
static bool ddl_repl_applying = false;

void
_PG_init(void)
{
	DefineCustomBoolVariable("ddl_repl.applying",
							  "Set while the apply trigger is replaying a captured DDL command; skips capture to prevent replication loops.",
							  NULL,
							  &ddl_repl_applying,
							  false,
							  PGC_USERSET,
							  0,
							  NULL, NULL, NULL);
}
