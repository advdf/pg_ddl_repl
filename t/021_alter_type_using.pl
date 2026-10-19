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
    $node->safe_psql('postgres', 'CREATE TABLE t_orders (id int PRIMARY KEY, status text, qty text)');
}

$publisher->safe_psql('postgres', q(SELECT ddl_repl.publish_table('t_orders'::regclass)));

$publisher->safe_psql('postgres', 'CREATE PUBLICATION pub1 FOR TABLE t_orders');
$publisher->safe_psql('postgres', "SELECT ddl_repl.enable_for_publication('pub1')");

my $publisher_connstr = $publisher->connstr . ' dbname=postgres';
$subscriber->safe_psql('postgres',
    "CREATE SUBSCRIPTION sub1 CONNECTION '$publisher_connstr' PUBLICATION pub1");
$subscriber->wait_for_subscription_sync($publisher, 'sub1');
$subscriber->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('publisher', 'public', 't_orders')));

$publisher->safe_psql('postgres', q(INSERT INTO t_orders VALUES (1, 'ok', '12')));
$publisher->wait_for_catchup('sub1');

$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ALTER COLUMN status TYPE mood USING status::mood');
$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ALTER COLUMN qty TYPE int USING qty::int * 2');
$publisher->safe_psql('postgres', q(INSERT INTO t_orders VALUES (2, 'ko', 5)));
$publisher->wait_for_catchup('sub1');

is($subscriber->safe_psql('postgres',
        q(SELECT string_agg(format_type(atttypid, atttypmod), ',' ORDER BY attnum) FROM pg_attribute
          WHERE attrelid = 't_orders'::regclass AND attname IN ('status', 'qty'))),
    'mood,integer', 'ALTER COLUMN TYPE with USING replicated');
is($subscriber->safe_psql('postgres', 'SELECT qty FROM t_orders WHERE id = 1'),
    '24', 'the USING expression itself was applied to existing rows');
is($subscriber->safe_psql('postgres', 'SELECT status FROM t_orders WHERE id = 2'),
    'ko', 'and later rows apply');

$subscriber->stop;
$publisher->stop;
done_testing();
