use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# One publisher, two independently-configured subscribers: sub_a wants
# column DDL only, sub_b wants everything. Confirms subscribe-side
# filtering is genuinely per-subscriber, not a single global switch --
# the publish-side gate already lets both families through to the wire
# (both are in the same command_queue rows), so only the subscribe_rules
# on each subscriber decide what actually gets replayed there.

my $publisher = PostgreSQL::Test::Cluster->new('publisher');
$publisher->init(allows_streaming => 'logical');
$publisher->start;

my $sub_a = PostgreSQL::Test::Cluster->new('sub_a');
$sub_a->init;
$sub_a->start;

my $sub_b = PostgreSQL::Test::Cluster->new('sub_b');
$sub_b->init;
$sub_b->start;

for my $node ($publisher, $sub_a, $sub_b)
{
    $node->safe_psql('postgres', 'CREATE EXTENSION pg_ddl_repl;');
    $node->safe_psql('postgres', 'CREATE TABLE t_orders (id int, c1 int)');
}

$publisher->safe_psql('postgres', q(SELECT ddl_repl.publish_table('t_orders'::regclass)));
$publisher->safe_psql('postgres', 'CREATE PUBLICATION pub1 FOR TABLE t_orders');
$publisher->safe_psql('postgres', "SELECT ddl_repl.enable_for_publication('pub1')");

my $publisher_connstr = $publisher->connstr . ' dbname=postgres';
for my $pair ([$sub_a, 'sub_a'], [$sub_b, 'sub_b'])
{
    my ($sub, $subname) = @$pair;
    $sub->safe_psql('postgres',
        "CREATE SUBSCRIPTION $subname CONNECTION '$publisher_connstr' PUBLICATION pub1");
    $sub->wait_for_subscription_sync($publisher, $subname);
}

# sub_a: column family only.
$sub_a->safe_psql('postgres',
    q(INSERT INTO ddl_repl.subscribe_rules (source_name, schema_name, table_name, object_family, operation)
      VALUES ('publisher', 'public', 't_orders', 'column', 'add_column')));

# sub_b: everything (table + column + index).
$sub_b->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('publisher', 'public', 't_orders')));

$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ADD COLUMN amount numeric');
$publisher->safe_psql('postgres', 'CREATE INDEX idx_orders_c1 ON t_orders (c1)');
$publisher->wait_for_catchup('sub_a');
$publisher->wait_for_catchup('sub_b');

is($sub_a->safe_psql('postgres',
        q(SELECT count(*) FROM information_schema.columns WHERE table_name = 't_orders' AND column_name = 'amount')),
    '1',
    'sub_a (column-only) applied add_column');
is($sub_a->safe_psql('postgres', q(SELECT count(*) FROM pg_indexes WHERE indexname = 'idx_orders_c1')),
    '0',
    'sub_a (column-only) did NOT apply create_index -- its own subscribe_rules never granted it');

is($sub_b->safe_psql('postgres',
        q(SELECT count(*) FROM information_schema.columns WHERE table_name = 't_orders' AND column_name = 'amount')),
    '1',
    'sub_b (everything) applied add_column');
is($sub_b->safe_psql('postgres', q(SELECT count(*) FROM pg_indexes WHERE indexname = 'idx_orders_c1')),
    '1',
    'sub_b (everything) also applied create_index -- independent from sub_a');

$sub_b->stop;
$sub_a->stop;
$publisher->stop;
done_testing();
