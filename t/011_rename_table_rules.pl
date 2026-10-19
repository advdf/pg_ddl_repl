use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $publisher = PostgreSQL::Test::Cluster->new('publisher');
$publisher->init(allows_streaming => 'logical');
$publisher->start;

my $subscriber = PostgreSQL::Test::Cluster->new('subscriber');
$subscriber->init;
$subscriber->start;

for my $node ($publisher, $subscriber)
{
    $node->safe_psql('postgres', 'CREATE EXTENSION pg_ddl_repl;');
    $node->safe_psql('postgres', 'CREATE TABLE t_orders (id int PRIMARY KEY, label text)');
}

$publisher->safe_psql('postgres', q(SELECT ddl_repl.publish_table('t_orders'::regclass)));
$publisher->safe_psql('postgres', 'CREATE INDEX t_orders_label_idx ON t_orders (label)');
$publisher->safe_psql('postgres', 'CREATE INDEX t_orders_id_label_idx ON t_orders (id, label)');

$publisher->safe_psql('postgres', 'CREATE PUBLICATION pub1 FOR TABLE t_orders');
$publisher->safe_psql('postgres', "SELECT ddl_repl.enable_for_publication('pub1')");

my $publisher_connstr = $publisher->connstr . ' dbname=postgres';
$subscriber->safe_psql('postgres',
    "CREATE SUBSCRIPTION sub1 CONNECTION '$publisher_connstr' PUBLICATION pub1");
$subscriber->wait_for_subscription_sync($publisher, 'sub1');

$subscriber->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('publisher', 'public', 't_orders')));
$subscriber->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('other_source', 'public', 't_orders')));
$subscriber->safe_psql('postgres', 'CREATE INDEX t_orders_label_idx ON t_orders (label)');

$publisher->safe_psql('postgres', 'ALTER TABLE t_orders RENAME TO t_orders_v2');
$publisher->wait_for_catchup('sub1');
is($subscriber->safe_psql('postgres', q(SELECT to_regclass('public.t_orders_v2') IS NOT NULL)),
    't', 'rename_table replicated to subscriber');

is($subscriber->safe_psql('postgres',
        q(SELECT count(*) FROM ddl_repl.subscribe_rules WHERE table_name = 't_orders')),
    '0', 'no subscribe rule left on the old table name');
is($subscriber->safe_psql('postgres',
        q(SELECT count(*) FROM ddl_repl.subscribe_rules WHERE source_name = 'other_source' AND table_name = 't_orders_v2')),
    '10', 'rules of other sources on the same table follow the rename too');

$publisher->safe_psql('postgres', 'ALTER TABLE t_orders_v2 ADD COLUMN amount int');
$publisher->safe_psql('postgres', q(INSERT INTO t_orders_v2 VALUES (1, 'a', 42)));
$publisher->wait_for_catchup('sub1');
is($subscriber->safe_psql('postgres', 'SELECT amount FROM t_orders_v2 WHERE id = 1'),
    '42', 'add_column after rename replicated, and the row using it applied');

$publisher->safe_psql('postgres', 'DROP INDEX t_orders_label_idx');
$publisher->wait_for_catchup('sub1');
is($subscriber->safe_psql('postgres', q(SELECT to_regclass('public.t_orders_label_idx') IS NULL)),
    't', 'drop_index on a renamed table replicated to subscriber');

$publisher->safe_psql('postgres', 'DROP TABLE t_orders_v2');
is($publisher->safe_psql('postgres',
        q(SELECT payload->>'table_name' FROM ddl_repl.command_queue WHERE payload->>'operation' = 'drop_index' AND payload->>'index_name' = 't_orders_id_label_idx')),
    't_orders_v2', 'drop_index cascaded from a DROP TABLE after a rename carries the new table name');

$subscriber->stop;
$publisher->stop;
done_testing();
