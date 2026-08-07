use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_ddl_repl;');

# create_table can't be gated per-relid -- the table doesn't have an oid
# yet when the DDL runs -- so it needs a database-wide wildcard rule
# (relid NULL). Rename/drop of *this* table are then covered per-relid via
# publish_table() once the oid exists.
$node->safe_psql('postgres',
    q(INSERT INTO ddl_repl.publish_rules (object_family, operation) VALUES ('table', 'create_table')));
$node->safe_psql('postgres', 'CREATE TABLE t_orders (id int)');
$node->safe_psql('postgres', q(SELECT ddl_repl.publish_table('t_orders'::regclass)));
$node->safe_psql('postgres', 'ALTER TABLE t_orders RENAME TO t_orders_renamed');
$node->safe_psql('postgres', 'DROP TABLE t_orders_renamed');

my $rows = $node->safe_psql('postgres',
    "SELECT payload->>'operation', payload->>'table_name', payload->>'new_name' "
    . "FROM ddl_repl.command_queue ORDER BY id");

is($rows,
    "create_table|t_orders|\n"
    . "rename_table|t_orders|t_orders_renamed\n"
    . "drop_table|t_orders_renamed|",
    'create/rename/drop table are captured in order with correct fields');

my $count = $node->safe_psql('postgres',
    "SELECT count(*) FROM ddl_repl.command_queue WHERE payload->>'object_family' <> 'table'");
is($count, '0', 'no non-table rows leaked in for these commands');

$node->stop;
done_testing();
