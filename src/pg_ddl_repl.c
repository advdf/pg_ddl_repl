#include "postgres.h"
#include "fmgr.h"

PG_MODULE_MAGIC;

/*
 * No GUCs and no _PG_init here: loop prevention keys off the built-in
 * session_replication_role GUC (checked by the capture event triggers in
 * pg_ddl_repl--1.0.sql), which apply workers always run under and which,
 * being SUSET, cannot be set by unprivileged roles to exempt their own DDL
 * from capture -- unlike the custom USERSET ddl_repl.applying variable this
 * module used to define.
 */
