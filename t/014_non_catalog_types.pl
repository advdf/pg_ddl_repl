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
    $node->safe_psql('postgres', q(CREATE TYPE public.mood AS ENUM ('ok', 'ko')));
    $node->safe_psql('postgres', 'CREATE DOMAIN public.qty AS int CHECK (VALUE >= 0)');
    $node->safe_psql('postgres', 'CREATE TABLE t_orders (id int PRIMARY KEY)');
}

$publisher->safe_psql('postgres', q(SELECT ddl_repl.publish_table('t_orders'::regclass)));
$publisher->safe_psql('postgres', 'CREATE PUBLICATION pub1 FOR TABLE t_orders');
$publisher->safe_psql('postgres', "SELECT ddl_repl.enable_for_publication('pub1')");

my $publisher_connstr = $publisher->connstr . ' dbname=postgres';
$subscriber->safe_psql('postgres',
    "CREATE SUBSCRIPTION sub1 CONNECTION '$publisher_connstr' PUBLICATION pub1");
$subscriber->wait_for_subscription_sync($publisher, 'sub1');
$subscriber->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('publisher', 'public', 't_orders')));

$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ADD COLUMN status mood');
$publisher->safe_psql('postgres', q(INSERT INTO t_orders VALUES (1, 'ok')));
$publisher->wait_for_catchup('sub1');
is($subscriber->safe_psql('postgres',
        q(SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 't_orders'::regclass AND attname = 'status')),
    'mood', 'add_column with a type outside pg_catalog replicated');
is($subscriber->safe_psql('postgres', 'SELECT status FROM t_orders WHERE id = 1'),
    'ok', 'and the row using it applied');

$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ADD COLUMN amount int');
$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ALTER COLUMN amount TYPE qty');
$publisher->wait_for_catchup('sub1');
is($subscriber->safe_psql('postgres',
        q(SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 't_orders'::regclass AND attname = 'amount')),
    'qty', 'alter_column_type to a type outside pg_catalog replicated');

$subscriber->stop;
$publisher->stop;
done_testing();
