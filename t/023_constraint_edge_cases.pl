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

my $pg18 = $publisher->safe_psql('postgres', q(SELECT current_setting('server_version_num')::int >= 180000));

for my $node ($publisher, $subscriber)
{
    $node->safe_psql('postgres', 'CREATE EXTENSION pg_ddl_repl;');
    $node->safe_psql('postgres', 'CREATE TABLE customers (id int PRIMARY KEY)');
    $node->safe_psql('postgres', 'CREATE TABLE t_orders (id int PRIMARY KEY, title text, qty int, customer_id int)');
    $node->safe_psql('postgres', 'CREATE TABLE parted (id int, a int) PARTITION BY RANGE (id)');
    $node->safe_psql('postgres', 'CREATE TABLE parted_1 PARTITION OF parted FOR VALUES FROM (0) TO (100)');
}

my @tables = ('customers', 't_orders', 'parted', 'parted_1');
for my $table (@tables)
{
    $publisher->safe_psql('postgres', qq(SELECT ddl_repl.publish_table('$table'::regclass)));
}
$publisher->safe_psql('postgres', 'CREATE PUBLICATION pub1 FOR TABLE t_orders, customers');
$publisher->safe_psql('postgres', "SELECT ddl_repl.enable_for_publication('pub1')");

my $publisher_connstr = $publisher->connstr . ' dbname=postgres';
$subscriber->safe_psql('postgres',
    "CREATE SUBSCRIPTION sub1 CONNECTION '$publisher_connstr' PUBLICATION pub1");
$subscriber->wait_for_subscription_sync($publisher, 'sub1');
for my $table (@tables)
{
    $subscriber->safe_psql('postgres', qq(SELECT ddl_repl.subscribe_table('publisher', 'public', '$table')));
}

sub constraints_of
{
    my ($node, $table) = @_;
    return $node->safe_psql('postgres', qq(
        SELECT coalesce(string_agg(conname || ' ' || pg_get_constraintdef(oid), E'\\n' ORDER BY conname), '')
        FROM pg_constraint WHERE conrelid = 'public.$table'::regclass AND contype <> 'n'));
}

sub indexes_of
{
    my ($node, $table) = @_;
    return $node->safe_psql('postgres', qq(
        SELECT string_agg(indexrelid::regclass::text, ',' ORDER BY indexrelid::regclass::text)
        FROM pg_index WHERE indrelid = 'public.$table'::regclass));
}

sub worker_up
{
    return $subscriber->safe_psql('postgres', 'SELECT pid IS NOT NULL FROM pg_stat_subscription');
}

# A constraint the subscriber already has must not stop apply.
$subscriber->safe_psql('postgres', 'ALTER TABLE t_orders ADD CONSTRAINT t_orders_qty_check CHECK (qty >= 0)');
$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ADD CONSTRAINT t_orders_qty_check CHECK (qty >= 0)');
$publisher->safe_psql('postgres', 'INSERT INTO t_orders (id) VALUES (1)');
$publisher->wait_for_catchup('sub1');
is($subscriber->safe_psql('postgres', 'SELECT count(*) FROM t_orders'), '1',
    'an ADD CONSTRAINT already present on the subscriber is skipped');

# USING INDEX: the existing index becomes the constraint, no second index.
$publisher->safe_psql('postgres', 'CREATE UNIQUE INDEX t_orders_title_idx ON t_orders (title)');
$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ADD CONSTRAINT t_orders_title_key UNIQUE USING INDEX t_orders_title_idx');
$publisher->wait_for_catchup('sub1');
is(indexes_of($subscriber, 't_orders'), indexes_of($publisher, 't_orders'),
    'ADD CONSTRAINT USING INDEX reuses the index on the subscriber');
is(constraints_of($subscriber, 't_orders'), constraints_of($publisher, 't_orders'),
    'and creates the same constraint');

# NOT NULL goes through set_not_null / drop_not_null only.
$publisher->safe_psql('postgres', q(UPDATE t_orders SET title = 'x', qty = 0));
$publisher->safe_psql('postgres', q(
    UPDATE ddl_repl.publish_rules SET enabled = false
    WHERE relid = 't_orders'::regclass AND operation = 'drop_not_null'));
$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ALTER COLUMN title SET NOT NULL');
$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ALTER COLUMN title DROP NOT NULL');
is($publisher->safe_psql('postgres', q(
        SELECT count(*) FROM ddl_repl.command_queue WHERE payload->>'operation' IN ('drop_not_null', 'drop_constraint'))),
    '0', 'a disabled drop_not_null rule is not bypassed through drop_constraint');
SKIP:
{
    skip 'ADD CONSTRAINT ... NOT NULL needs PostgreSQL 18', 1 if $pg18 ne 't';
    $publisher->safe_psql('postgres', 'ALTER TABLE t_orders ADD CONSTRAINT t_orders_qty_nn NOT NULL qty');
    is($publisher->safe_psql('postgres', q(
            SELECT string_agg(payload->>'operation', ',') FROM ddl_repl.command_queue
            WHERE payload->>'column_name' = 'qty' OR payload->>'constraint_name' = 't_orders_qty_nn')),
        'set_not_null', 'an explicit NOT NULL constraint is captured as set_not_null');
}

# Partitioned table: the partition's inherited copy is dropped by the parent's replay.
$publisher->safe_psql('postgres', 'ALTER TABLE parted ADD CONSTRAINT parted_a_check CHECK (a > 0)');
$publisher->safe_psql('postgres', 'ALTER TABLE parted DROP CONSTRAINT parted_a_check');
$publisher->safe_psql('postgres', q(INSERT INTO t_orders (id, title, qty) VALUES (2, 'y', 0)));
$publisher->wait_for_catchup('sub1');
is(constraints_of($subscriber, 'parted_1'), '', 'a constraint dropped on a partitioned parent is gone from the partition');
is(worker_up(), 't', 'and apply keeps running');

# CASCADE drops on the publisher: the dependents are replicated before the drop itself.
$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ADD CONSTRAINT t_orders_customer_fkey FOREIGN KEY (customer_id) REFERENCES customers (id)');
$publisher->safe_psql('postgres', 'DROP TABLE customers CASCADE');
$publisher->safe_psql('postgres', 'ALTER TABLE t_orders DROP COLUMN qty CASCADE');
$publisher->safe_psql('postgres', q(INSERT INTO t_orders (id, title) VALUES (3, 'z')));
$publisher->wait_for_catchup('sub1');
is($subscriber->safe_psql('postgres', q(SELECT to_regclass('public.customers') IS NULL)), 't',
    'DROP TABLE ... CASCADE replicated');
is(constraints_of($subscriber, 't_orders'), constraints_of($publisher, 't_orders'),
    'with the dependent foreign key and check dropped too');
is($subscriber->safe_psql('postgres', 'SELECT count(*) FROM t_orders'), '3', 'and apply keeps running');

# The dependent of a cascaded constraint drop must be replayed first, even when it is on the same table.
for my $node ($publisher, $subscriber)
{
    $node->safe_psql('postgres', 'CREATE TABLE selfref (id int PRIMARY KEY, parent int)');
    $node->safe_psql('postgres', 'ALTER TABLE selfref ADD CONSTRAINT selfref_parent_fkey FOREIGN KEY (parent) REFERENCES selfref (id)');
}
$publisher->safe_psql('postgres', q(SELECT ddl_repl.publish_table('selfref'::regclass)));
$subscriber->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('publisher', 'public', 'selfref')));
$publisher->safe_psql('postgres', 'ALTER TABLE selfref DROP CONSTRAINT selfref_pkey CASCADE');
$publisher->safe_psql('postgres', q(INSERT INTO t_orders (id, title) VALUES (4, 'w')));
$publisher->wait_for_catchup('sub1');
is(constraints_of($subscriber, 'selfref'), '', 'DROP CONSTRAINT ... CASCADE with a same-table dependent replicated');

$subscriber->stop;
$publisher->stop;
done_testing();
