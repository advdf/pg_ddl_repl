use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_ddl_repl;');
$node->safe_psql('postgres', 'CREATE TABLE t_orders (id int)');
$node->safe_psql('postgres', q(SELECT ddl_repl.publish_table('t_orders'::regclass)));

$node->safe_psql('postgres', 'ALTER TABLE t_orders ADD COLUMN amount numeric(10,2)');
$node->safe_psql('postgres', 'ALTER TABLE t_orders RENAME COLUMN amount TO total_amount');
$node->safe_psql('postgres', 'ALTER TABLE t_orders ALTER COLUMN total_amount TYPE numeric(12,4)');
$node->safe_psql('postgres', 'ALTER TABLE t_orders ALTER COLUMN total_amount SET DEFAULT 0');
$node->safe_psql('postgres', 'ALTER TABLE t_orders DROP COLUMN total_amount');

my $rows = $node->safe_psql('postgres',
    "SELECT payload->>'operation', payload->>'column_name', payload->>'new_name', payload->>'type_name' "
    . "FROM ddl_repl.command_queue WHERE payload->>'object_family' = 'column' ORDER BY id");

is($rows,
    "add_column|amount||numeric(10,2)\n"
    . "rename_column|amount|total_amount|\n"
    . "alter_column_type|total_amount||numeric(12,4)\n"
    . "alter_column_default|total_amount||\n"
    . "drop_column|total_amount||",
    'add/rename/alter-type/alter-default/drop column are all captured with correct fields');

is($node->safe_psql('postgres',
        q(SELECT payload->>'ddl_text' FROM ddl_repl.command_queue WHERE payload->>'operation' = 'alter_column_default')),
    'ALTER TABLE IF EXISTS public.t_orders ALTER COLUMN total_amount SET DEFAULT 0',
    'alter_column_default keeps a rebuilt, fully-qualified single statement as a fallback');

is($node->safe_psql('postgres',
        "SELECT count(*) FROM ddl_repl.command_queue WHERE payload->>'object_family' = 'table'"),
    '0',
    'no table-family row leaked in (CREATE TABLE itself predates the publish rule, and no column-drop double-capture)');

$node->stop;
done_testing();
