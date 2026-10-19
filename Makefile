MODULE_big = pg_ddl_repl
OBJS = src/pg_ddl_repl.o src/deparse_table.o src/deparse_column.o src/deparse_index.o src/deparse_constraint.o src/deparse_extra.o src/validate.o

EXTENSION = pg_ddl_repl
DATA = pg_ddl_repl--1.0.sql
PGFILEDESC = "pg_ddl_repl - transparent DDL replication over native logical replication"

TAP_TESTS = 1

PG_CPPFLAGS = -I$(srcdir)/src

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
