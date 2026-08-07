use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_ddl_repl;');
$node->safe_psql('postgres', 'CREATE TABLE t_orders (id int, c1 int)');
$node->safe_psql('postgres', q(SELECT ddl_repl.publish_table('t_orders'::regclass)));
$node->safe_psql('postgres', 'CREATE UNIQUE INDEX idx_orders_c1 ON t_orders (c1)');
$node->safe_psql('postgres', 'DROP INDEX idx_orders_c1');

my $rows = $node->safe_psql('postgres',
    "SELECT payload->>'operation', payload->>'index_name', payload->>'table_name' "
    . "FROM ddl_repl.command_queue WHERE payload->>'object_family' = 'index' ORDER BY id");

is($rows,
    "create_index|idx_orders_c1|t_orders\n"
    . "drop_index|idx_orders_c1|t_orders",
    'create/drop index are captured with correct fields, drop_index resolving table_name via index_table_map');

is($node->safe_psql('postgres',
        q(SELECT payload->>'index_def' FROM ddl_repl.command_queue WHERE payload->>'operation' = 'create_index')),
    'CREATE UNIQUE INDEX idx_orders_c1 ON public.t_orders USING btree (c1)',
    'create_index carries the full pg_get_indexdef() text');

$node->stop;
done_testing();
