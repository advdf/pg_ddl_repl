use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Simulates queue rows arriving through a subscription: the apply trigger
# only fires under session_replication_role = replica.
my $node = PostgreSQL::Test::Cluster->new('subscriber');
$node->init;
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_ddl_repl;');
$node->safe_psql('postgres', 'CREATE TABLE t (id int PRIMARY KEY, a int)');
$node->safe_psql('postgres', 'CREATE TABLE other (b int)');
$node->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('src', 'public', 't')));
$node->safe_psql('postgres', q(SELECT ddl_repl.enable_raw_fallback('src', 'public', 't')));

my $next_id = 1;

sub replay
{
    my ($payload) = @_;
    my $id = $next_id++;
    my ($ret, $stdout, $stderr) = $node->psql('postgres', qq(
        SET session_replication_role = replica;
        INSERT INTO ddl_repl.command_queue (id, source_name, payload)
        VALUES ($id, 'src', \$p\$$payload\$p\$::jsonb);
    ));
    return ($ret, $stderr);
}

sub rejected
{
    my ($payload, $error, $label) = @_;
    my ($ret, $stderr) = replay($payload);
    isnt($ret, 0, "$label: apply raised");
    like($stderr, $error, "$label: with the expected error");
}

sub exists_rel
{
    my ($name) = @_;
    return $node->safe_psql('postgres', qq(SELECT to_regclass('public.$name') IS NOT NULL));
}

rejected(q({"schema_version": 1, "object_family": "column", "operation": "alter_column_type",
          "schema_name": "public", "table_name": "t", "column_name": "a",
          "type_name": "bigint; CREATE TABLE pwned_type (x int)"}),
    qr/syntax error|invalid type name/, 'type_name with a second statement');
is(exists_rel('pwned_type'), 'f', 'type_name cannot smuggle a second statement');

rejected(q({"schema_version": 1, "object_family": "index", "operation": "create_index",
          "schema_name": "public", "table_name": "t", "index_name": "t_a_idx",
          "index_def": "CREATE INDEX t_a_idx ON public.t USING btree (a); CREATE TABLE pwned_index (x int)"}),
    qr/replicated command must be a single statement/, 'index_def with a second statement');
is(exists_rel('pwned_index'), 'f', 'index_def cannot smuggle a second statement');
is(exists_rel('t_a_idx'), 'f', 'a rejected index_def creates nothing');

rejected(q({"schema_version": 1, "object_family": "index", "operation": "create_index",
          "schema_name": "public", "table_name": "t", "index_name": "other_b_idx",
          "index_def": "CREATE INDEX other_b_idx ON public.other USING btree (b)"}),
    qr/replicated command does not target table "public"\."t"/, 'index_def on another table');
is(exists_rel('other_b_idx'), 'f', 'index_def cannot target a table other than the payload one');

rejected(q({"schema_version": 1, "object_family": "column", "operation": "alter_column_default",
          "schema_name": "public", "table_name": "t", "column_name": "a",
          "ddl_text": "ALTER TABLE IF EXISTS public.t ALTER COLUMN a SET DEFAULT 1; CREATE TABLE pwned_default (x int)"}),
    qr/replicated command must be a single statement/, 'ddl_text with a second statement');
is(exists_rel('pwned_default'), 'f', 'raw-fallback ddl_text cannot smuggle a second statement');

rejected(q({"schema_version": 1, "object_family": "column", "operation": "alter_column_type",
          "schema_name": "public", "table_name": "t", "column_name": "a",
          "type_name": "bigint", "using_expr": "a::bigint; CREATE TABLE pwned_using (x int)"}),
    qr/replicated command must be a single statement/, 'using_expr with a second statement');
is(exists_rel('pwned_using'), 'f', 'using_expr cannot smuggle a second statement');

rejected(q({"schema_version": 1, "object_family": "constraint", "operation": "add_constraint",
          "schema_name": "public", "table_name": "t", "constraint_name": "t_a_check",
          "constraint_def": "CHECK (a > 0); CREATE TABLE pwned_constraint (x int)"}),
    qr/replicated command must be a single statement/, 'constraint_def with a second statement');
is(exists_rel('pwned_constraint'), 'f', 'constraint_def cannot smuggle a second statement');

my ($ok_ret) = replay(q({"schema_version": 1, "object_family": "column", "operation": "alter_column_type",
          "schema_name": "public", "table_name": "t", "column_name": "a",
          "type_name": "numeric(12,4)"}));
is($ok_ret, 0, 'a valid type_name is accepted');
is($node->safe_psql('postgres',
        q(SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 'public.t'::regclass AND attname = 'a')),
    'numeric(12,4)', 'a valid type_name still applies, typmod included');

$node->stop;
done_testing();
