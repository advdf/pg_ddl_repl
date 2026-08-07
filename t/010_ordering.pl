use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# A single publisher transaction mixing DDL (ADD COLUMN) and DML (INSERT
# into the new column) must apply on the subscriber in the same order --
# the whole point of firing the apply trigger inside the apply worker's own
# transaction (see ddl_repl.apply_command's comment) rather than a
# background worker. If ordering broke, the INSERT would try to land in a
# column that doesn't exist yet on the subscriber and replication would
# error out instead of just passing this test.

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

$publisher->safe_psql('postgres', <<'SQL');
BEGIN;
ALTER TABLE t_orders ADD COLUMN amount numeric;
INSERT INTO t_orders (id, amount) VALUES (1, 99.5);
COMMIT;
SQL
$publisher->wait_for_catchup('sub1');

is($subscriber->safe_psql('postgres',
        q(SELECT count(*) FROM information_schema.columns WHERE table_name = 't_orders' AND column_name = 'amount')),
    '1',
    'add_column applied on the subscriber');
is($subscriber->safe_psql('postgres', 'SELECT amount FROM t_orders WHERE id = 1'),
    '99.5',
    'the INSERT into the brand-new column landed correctly -- DDL and DML from the same transaction applied in order');

$subscriber->stop;
$publisher->stop;
done_testing();
