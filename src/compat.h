#ifndef DDL_REPL_COMPAT_H
#define DDL_REPL_COMPAT_H

#include "fmgr.h"

/*
 * PG16 centralized the _PG_init prototype in fmgr.h. On PG15 no such
 * declaration exists anywhere in core, so our definition trips
 * -Wmissing-prototypes unless we declare it ourselves.
 */
#if PG_VERSION_NUM < 160000
extern PGDLLEXPORT void _PG_init(void);
#endif

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

#endif							/* DDL_REPL_COMPAT_H */
