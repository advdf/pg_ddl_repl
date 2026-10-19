#include "postgres.h"
#include "fmgr.h"
#include "nodes/parsenodes.h"
#include "parser/parser.h"
#include "parser/parse_type.h"
#include "utils/builtins.h"

#include "compat.h"

/* Queue text replayed with EXECUTE on the subscriber must be one statement of the expected kind. */
static Node *
single_statement(const char *sql)
{
	List	   *stmts = raw_parser(sql, RAW_PARSE_DEFAULT);

	if (list_length(stmts) != 1)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("pg_ddl_repl: replicated command must be a single statement")));
	return linitial_node(RawStmt, stmts)->stmt;
}

static void
check_relation(const RangeVar *rel, const char *schema, const char *table)
{
	if (rel == NULL || rel->catalogname != NULL || rel->schemaname == NULL ||
		strcmp(rel->schemaname, schema) != 0 || strcmp(rel->relname, table) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("pg_ddl_repl: replicated command does not target table \"%s\".\"%s\"",
						schema, table)));
}

PG_FUNCTION_INFO_V1(ddl_repl_canonical_type);

Datum
ddl_repl_canonical_type(PG_FUNCTION_ARGS)
{
	char	   *type_name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	Oid			typid;
	int32		typmod;

	DDL_REPL_PARSE_TYPE_STRING(type_name, &typid, &typmod);
	PG_RETURN_TEXT_P(cstring_to_text(format_type_with_typemod(typid, typmod)));
}

PG_FUNCTION_INFO_V1(ddl_repl_checked_index_def);

Datum
ddl_repl_checked_index_def(PG_FUNCTION_ARGS)
{
	char	   *index_def = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char	   *schema = text_to_cstring(PG_GETARG_TEXT_PP(1));
	char	   *table = text_to_cstring(PG_GETARG_TEXT_PP(2));
	char	   *index = text_to_cstring(PG_GETARG_TEXT_PP(3));
	Node	   *stmt = single_statement(index_def);
	IndexStmt  *idx;

	if (!IsA(stmt, IndexStmt))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("pg_ddl_repl: replicated index definition is not a CREATE INDEX")));
	idx = (IndexStmt *) stmt;
	check_relation(idx->relation, schema, table);
	if (idx->idxname == NULL || strcmp(idx->idxname, index) != 0 || idx->concurrent)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("pg_ddl_repl: replicated index definition does not create index \"%s\"", index)));

	PG_RETURN_TEXT_P(PG_GETARG_TEXT_PP(0));
}

/* The one ALTER TABLE subcommand of a replicated statement, on the expected table. */
static AlterTableCmd *
single_alter_table_cmd(const char *sql, const char *schema, const char *table, const char *what)
{
	Node	   *stmt = single_statement(sql);
	AlterTableStmt *alter;

	if (!IsA(stmt, AlterTableStmt) || ((AlterTableStmt *) stmt)->objtype != OBJECT_TABLE)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("pg_ddl_repl: replicated %s is not an ALTER TABLE", what)));
	alter = (AlterTableStmt *) stmt;
	check_relation(alter->relation, schema, table);

	if (list_length(alter->cmds) != 1)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("pg_ddl_repl: replicated %s must have a single subcommand", what)));
	return linitial_node(AlterTableCmd, alter->cmds);
}

static void
check_subcommand(const AlterTableCmd *cmd, AlterTableType subtype, const char *name, const char *expected,
				 const char *what)
{
	if (cmd->subtype != subtype || name == NULL || strcmp(name, expected) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("pg_ddl_repl: replicated %s does not target \"%s\"", what, expected)));
}

PG_FUNCTION_INFO_V1(ddl_repl_checked_add_constraint);

Datum
ddl_repl_checked_add_constraint(PG_FUNCTION_ARGS)
{
	char	   *constraint = text_to_cstring(PG_GETARG_TEXT_PP(3));
	AlterTableCmd *cmd = single_alter_table_cmd(text_to_cstring(PG_GETARG_TEXT_PP(0)),
												text_to_cstring(PG_GETARG_TEXT_PP(1)),
												text_to_cstring(PG_GETARG_TEXT_PP(2)), "constraint");
	const char *name = (cmd->def != NULL && IsA(cmd->def, Constraint)) ? ((Constraint *) cmd->def)->conname : NULL;

	check_subcommand(cmd, AT_AddConstraint, name, constraint, "constraint");
	PG_RETURN_TEXT_P(PG_GETARG_TEXT_PP(0));
}

PG_FUNCTION_INFO_V1(ddl_repl_checked_alter_default);

Datum
ddl_repl_checked_alter_default(PG_FUNCTION_ARGS)
{
	char	   *column = text_to_cstring(PG_GETARG_TEXT_PP(3));
	AlterTableCmd *cmd = single_alter_table_cmd(text_to_cstring(PG_GETARG_TEXT_PP(0)),
												text_to_cstring(PG_GETARG_TEXT_PP(1)),
												text_to_cstring(PG_GETARG_TEXT_PP(2)), "default change");

	check_subcommand(cmd, AT_ColumnDefault, cmd->name, column, "default change");
	PG_RETURN_TEXT_P(PG_GETARG_TEXT_PP(0));
}

PG_FUNCTION_INFO_V1(ddl_repl_checked_alter_type);

Datum
ddl_repl_checked_alter_type(PG_FUNCTION_ARGS)
{
	char	   *column = text_to_cstring(PG_GETARG_TEXT_PP(3));
	AlterTableCmd *cmd = single_alter_table_cmd(text_to_cstring(PG_GETARG_TEXT_PP(0)),
												text_to_cstring(PG_GETARG_TEXT_PP(1)),
												text_to_cstring(PG_GETARG_TEXT_PP(2)), "type change");

	check_subcommand(cmd, AT_AlterColumnType, cmd->name, column, "type change");
	PG_RETURN_TEXT_P(PG_GETARG_TEXT_PP(0));
}

PG_FUNCTION_INFO_V1(ddl_repl_checked_add_column);

Datum
ddl_repl_checked_add_column(PG_FUNCTION_ARGS)
{
	char	   *column = text_to_cstring(PG_GETARG_TEXT_PP(3));
	AlterTableCmd *cmd = single_alter_table_cmd(text_to_cstring(PG_GETARG_TEXT_PP(0)),
												text_to_cstring(PG_GETARG_TEXT_PP(1)),
												text_to_cstring(PG_GETARG_TEXT_PP(2)), "column addition");
	const char *name = (cmd->def != NULL && IsA(cmd->def, ColumnDef)) ? ((ColumnDef *) cmd->def)->colname : NULL;

	check_subcommand(cmd, AT_AddColumn, name, column, "column addition");
	PG_RETURN_TEXT_P(PG_GETARG_TEXT_PP(0));
}

PG_FUNCTION_INFO_V1(ddl_repl_checked_attach_partition);

Datum
ddl_repl_checked_attach_partition(PG_FUNCTION_ARGS)
{
	char	   *partition = text_to_cstring(PG_GETARG_TEXT_PP(3));
	AlterTableCmd *cmd = single_alter_table_cmd(text_to_cstring(PG_GETARG_TEXT_PP(0)),
												text_to_cstring(PG_GETARG_TEXT_PP(1)),
												text_to_cstring(PG_GETARG_TEXT_PP(2)), "partition attach");
	const char *name = (cmd->def != NULL && IsA(cmd->def, PartitionCmd)) ? ((PartitionCmd *) cmd->def)->name->relname : NULL;

	check_subcommand(cmd, AT_AttachPartition, name, partition, "partition attach");
	PG_RETURN_TEXT_P(PG_GETARG_TEXT_PP(0));
}
