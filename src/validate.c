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

static void
check_alter_column(const char *sql, const char *schema, const char *table, const char *column,
				   AlterTableType subtype, const char *what)
{
	Node	   *stmt = single_statement(sql);
	AlterTableStmt *alter;
	AlterTableCmd *cmd;

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
	cmd = linitial_node(AlterTableCmd, alter->cmds);
	if (cmd->subtype != subtype || cmd->name == NULL || strcmp(cmd->name, column) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("pg_ddl_repl: replicated %s does not target column \"%s\"", what, column)));
}

PG_FUNCTION_INFO_V1(ddl_repl_checked_alter_default);

Datum
ddl_repl_checked_alter_default(PG_FUNCTION_ARGS)
{
	check_alter_column(text_to_cstring(PG_GETARG_TEXT_PP(0)), text_to_cstring(PG_GETARG_TEXT_PP(1)),
					   text_to_cstring(PG_GETARG_TEXT_PP(2)), text_to_cstring(PG_GETARG_TEXT_PP(3)),
					   AT_ColumnDefault, "default change");
	PG_RETURN_TEXT_P(PG_GETARG_TEXT_PP(0));
}

PG_FUNCTION_INFO_V1(ddl_repl_checked_alter_type);

Datum
ddl_repl_checked_alter_type(PG_FUNCTION_ARGS)
{
	check_alter_column(text_to_cstring(PG_GETARG_TEXT_PP(0)), text_to_cstring(PG_GETARG_TEXT_PP(1)),
					   text_to_cstring(PG_GETARG_TEXT_PP(2)), text_to_cstring(PG_GETARG_TEXT_PP(3)),
					   AT_AlterColumnType, "type change");
	PG_RETURN_TEXT_P(PG_GETARG_TEXT_PP(0));
}
