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
$node->safe_psql('postgres', 'CREATE ROLE tbl_owner');
$node->safe_psql('postgres', 'CREATE TABLE t (id int, a int)');
$node->safe_psql('postgres', 'ALTER TABLE t OWNER TO tbl_owner');
$node->safe_psql('postgres', 'INSERT INTO t VALUES (1, 1)');
$node->safe_psql('postgres', 'CREATE SCHEMA priv');
$node->safe_psql('postgres', 'CREATE DOMAIN priv.secret AS int');
$node->safe_psql('postgres', 'CREATE TABLE other (b int)');
$node->safe_psql('postgres', 'CREATE INDEX other_b_idx ON other (b)');
$node->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('src', 'public', 't')));
$node->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('src', 'public', 'missing')));

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

my ($ret, $stderr) = replay(q({"schema_version": 1, "object_family": "column", "operation": "alter_column_type",
          "schema_name": "public", "table_name": "t", "column_name": "a", "type_name": "priv.secret"}));
isnt($ret, 0, 'a replayed command the table owner may not run is rejected');
like($stderr, qr/permission denied/, 'with a permission error, not run as superuser');
is($node->safe_psql('postgres',
        q(SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 'public.t'::regclass AND attname = 'a')),
    'integer', 'and the column is unchanged');

($ret, $stderr) = replay(q({"schema_version": 1, "object_family": "column", "operation": "alter_column_type",
          "schema_name": "public", "table_name": "t", "column_name": "a", "type_name": "bigint",
          "using_expr": "a + (CASE WHEN set_config('role', 'none', false) IS NOT NULL THEN 0 END)"}));
isnt($ret, 0, 'a replayed expression cannot switch back to the apply role');
like($stderr, qr/cannot set parameter "role"/, 'the role switch is refused by PostgreSQL');

($ret) = replay(q({"schema_version": 1, "object_family": "column", "operation": "add_column",
          "schema_name": "public", "table_name": "t", "column_name": "b", "type_name": "integer"}));
is($ret, 0, 'a command within the owner rights still applies');
is($node->safe_psql('postgres', q(SELECT current_user)), 'postgres', 'and the role is restored afterwards');

replay(q({"schema_version": 1, "object_family": "index", "operation": "drop_index",
          "schema_name": "public", "table_name": "missing", "index_name": "other_b_idx"}));
replay(q({"schema_version": 1, "object_family": "index", "operation": "drop_index",
          "schema_name": "public", "table_name": "t", "index_name": "other_b_idx"}));
is($node->safe_psql('postgres', q(SELECT to_regclass('public.other_b_idx') IS NOT NULL)),
    't', 'a replayed drop_index cannot reach an index of another table');

$node->stop;
done_testing();
