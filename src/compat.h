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
#define DDL_REPL_IS_ADD_CONSTRAINT(subtype) \
	((subtype) == AT_AddConstraint || (subtype) == AT_AddConstraintRecurse)
#else
#define DDL_REPL_IS_ADD_COLUMN(subtype) ((subtype) == AT_AddColumn)
#define DDL_REPL_IS_DROP_COLUMN(subtype) ((subtype) == AT_DropColumn)
#define DDL_REPL_IS_ADD_CONSTRAINT(subtype) ((subtype) == AT_AddConstraint)
#endif

/* parseTypeString() took a missing_ok flag before PG16, a soft-error context since. */
#if PG_VERSION_NUM < 160000
#define DDL_REPL_PARSE_TYPE_STRING(str, typid, typmod) \
	parseTypeString((str), (typid), (typmod), false)
#else
#define DDL_REPL_PARSE_TYPE_STRING(str, typid, typmod) \
	((void) parseTypeString((str), (typid), (typmod), NULL))
#endif

#if PG_VERSION_NUM < 160000
#define DDL_REPL_IS_VALIDATE_CONSTRAINT(subtype) \
	((subtype) == AT_ValidateConstraint || (subtype) == AT_ValidateConstraintRecurse)
#else
#define DDL_REPL_IS_VALIDATE_CONSTRAINT(subtype) ((subtype) == AT_ValidateConstraint)
#endif

/* PG18 stores NOT NULL as pg_constraint rows and gives ALTER CONSTRAINT its own node. */
#if PG_VERSION_NUM >= 180000
#define DDL_REPL_NOT_NULL_IS_CONSTRAINT 1
#define DDL_REPL_HAS_AT_ALTER_CONSTRAINT 1
#define DDL_REPL_ALTER_CONSTRAINT_NAME(def) (castNode(ATAlterConstraint, (def))->conname)
#else
#define DDL_REPL_ALTER_CONSTRAINT_NAME(def) (castNode(Constraint, (def))->conname)
#endif

#endif							/* DDL_REPL_COMPAT_H */
