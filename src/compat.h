#ifndef DDL_REPL_COMPAT_H
#define DDL_REPL_COMPAT_H

#include "fmgr.h"

/*
 * AT_AddColumnRecurse / AT_DropColumnRecurse were folded into plain
 * AT_AddColumn / AT_DropColumn in PG16 (confirmed absent from PG17/18
 * headers, present in PG15's). Centralize the version-dependent match here
 * so deparse_column.c doesn't need its own #if.
 */
#if PG_VERSION_NUM < 160000
#define DDL_REPL_IS_ADD_COLUMN(subtype) \
	((subtype) == AT_AddColumn || (subtype) == AT_AddColumnRecurse)
#define DDL_REPL_IS_DROP_COLUMN(subtype) \
	((subtype) == AT_DropColumn || (subtype) == AT_DropColumnRecurse)
#else
#define DDL_REPL_IS_ADD_COLUMN(subtype) ((subtype) == AT_AddColumn)
#define DDL_REPL_IS_DROP_COLUMN(subtype) ((subtype) == AT_DropColumn)
#endif

/* parseTypeString() took a missing_ok flag before PG16, a soft-error context since. */
#if PG_VERSION_NUM < 160000
#define DDL_REPL_PARSE_TYPE_STRING(str, typid, typmod) \
	parseTypeString((str), (typid), (typmod), false)
#else
#define DDL_REPL_PARSE_TYPE_STRING(str, typid, typmod) \
	((void) parseTypeString((str), (typid), (typmod), NULL))
#endif

#endif							/* DDL_REPL_COMPAT_H */
