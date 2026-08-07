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
    $node->safe_psql('postgres', 'CREATE TABLE t_orders (id int)');
}

$publisher->safe_psql('postgres', q(SELECT ddl_repl.publish_table('t_orders'::regclass)));

$publisher->safe_psql('postgres', 'CREATE PUBLICATION pub1 FOR TABLE t_orders');
$publisher->safe_psql('postgres', "SELECT ddl_repl.enable_for_publication('pub1')");

my $publisher_connstr = $publisher->connstr . ' dbname=postgres';
$subscriber->safe_psql('postgres',
    "CREATE SUBSCRIPTION sub1 CONNECTION '$publisher_connstr' PUBLICATION pub1");
$subscriber->wait_for_subscription_sync($publisher, 'sub1');

$subscriber->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('publisher', 'public', 't_orders')));

$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ADD COLUMN amount numeric(10,2)');
$publisher->wait_for_catchup('sub1');
is($subscriber->safe_psql('postgres',
        q(SELECT data_type FROM information_schema.columns WHERE table_name = 't_orders' AND column_name = 'amount')),
    'numeric',
    'add_column replicated to subscriber');

$publisher->safe_psql('postgres', 'ALTER TABLE t_orders RENAME COLUMN amount TO total_amount');
$publisher->wait_for_catchup('sub1');
is($subscriber->safe_psql('postgres',
        q(SELECT column_name FROM information_schema.columns WHERE table_name = 't_orders' AND column_name = 'total_amount')),
    'total_amount',
    'rename_column replicated to subscriber');

$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ALTER COLUMN total_amount TYPE numeric(12,4)');
$publisher->wait_for_catchup('sub1');
is($subscriber->safe_psql('postgres',
        q(SELECT numeric_scale FROM information_schema.columns WHERE table_name = 't_orders' AND column_name = 'total_amount')),
    '4',
    'alter_column_type replicated to subscriber');

$publisher->safe_psql('postgres', 'ALTER TABLE t_orders DROP COLUMN total_amount');
$publisher->wait_for_catchup('sub1');
is($subscriber->safe_psql('postgres',
        q(SELECT count(*) FROM information_schema.columns WHERE table_name = 't_orders' AND column_name = 'total_amount')),
    '0',
    'drop_column replicated to subscriber');

$subscriber->stop;
$publisher->stop;
done_testing();
