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
    $node->safe_psql('postgres', 'CREATE TABLE customers (id int PRIMARY KEY)');
    $node->safe_psql('postgres', 'CREATE TABLE t_orders (id int, title text, qty int, customer_id int)');
    $node->safe_psql('postgres', 'CREATE TABLE scratch (id int PRIMARY KEY, label text UNIQUE)');
}

for my $table ('t_orders', 'scratch')
{
    $publisher->safe_psql('postgres', qq(SELECT ddl_repl.publish_table('$table'::regclass)));
}
$publisher->safe_psql('postgres', 'CREATE PUBLICATION pub1 FOR TABLE t_orders, customers');
$publisher->safe_psql('postgres', "SELECT ddl_repl.enable_for_publication('pub1')");

my $publisher_connstr = $publisher->connstr . ' dbname=postgres';
$subscriber->safe_psql('postgres',
    "CREATE SUBSCRIPTION sub1 CONNECTION '$publisher_connstr' PUBLICATION pub1");
$subscriber->wait_for_subscription_sync($publisher, 'sub1');
for my $table ('t_orders', 'scratch')
{
    $subscriber->safe_psql('postgres', qq(SELECT ddl_repl.subscribe_table('publisher', 'public', '$table')));
}

sub constraints_of
{
    my ($node, $table) = @_;
    return $node->safe_psql('postgres', qq(
        SELECT string_agg(conname || ' ' || pg_get_constraintdef(oid), E'\\n' ORDER BY conname)
        FROM pg_constraint WHERE conrelid = 'public.$table'::regclass AND contype <> 'n'));
}

sub not_null_of
{
    my ($node, $column) = @_;
    return $node->safe_psql('postgres', qq(
        SELECT attnotnull FROM pg_attribute WHERE attrelid = 'public.t_orders'::regclass AND attname = '$column'));
}

$publisher->safe_psql('postgres', q(
    ALTER TABLE t_orders ADD CONSTRAINT t_orders_pkey PRIMARY KEY (id);
    ALTER TABLE t_orders ADD CONSTRAINT t_orders_title_key UNIQUE (title);
    ALTER TABLE t_orders ADD CONSTRAINT t_orders_qty_check CHECK (qty >= 0);
    ALTER TABLE t_orders ADD CONSTRAINT t_orders_customer_fkey FOREIGN KEY (customer_id) REFERENCES customers (id);
));
$publisher->wait_for_catchup('sub1');
is(constraints_of($subscriber, 't_orders'), constraints_of($publisher, 't_orders'),
    'ADD CONSTRAINT (primary key, unique, check, foreign key) replicated');

$publisher->safe_psql('postgres', 'ALTER TABLE t_orders DROP CONSTRAINT t_orders_qty_check');
$publisher->wait_for_catchup('sub1');
is(constraints_of($subscriber, 't_orders'), constraints_of($publisher, 't_orders'),
    'DROP CONSTRAINT replicated');

$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ALTER COLUMN title SET NOT NULL');
$publisher->wait_for_catchup('sub1');
is(not_null_of($subscriber, 'title'), 't', 'SET NOT NULL replicated');

$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ALTER COLUMN title DROP NOT NULL');
$publisher->wait_for_catchup('sub1');
is(not_null_of($subscriber, 'title'), 'f', 'DROP NOT NULL replicated');

# Changing a column type rebuilds its constraints internally: they must not be dropped on the subscriber.
$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ALTER COLUMN id TYPE bigint');
$publisher->wait_for_catchup('sub1');
is(constraints_of($subscriber, 't_orders'), constraints_of($publisher, 't_orders'),
    'constraints rebuilt by a type change are kept');

# The change that broke replication in the first dev test: the subscriber kept the old key.
$publisher->safe_psql('postgres', q(
    ALTER TABLE t_orders DROP CONSTRAINT t_orders_title_key;
    ALTER TABLE t_orders DROP CONSTRAINT t_orders_pkey;
    ALTER TABLE t_orders ADD CONSTRAINT t_orders_pkey PRIMARY KEY (id, title);
));
$publisher->safe_psql('postgres', q(
    INSERT INTO customers VALUES (7);
    INSERT INTO t_orders VALUES (1, 'a', 1, 7), (1, 'z', 2, 7);
));
$publisher->wait_for_catchup('sub1');
is(constraints_of($subscriber, 't_orders'), constraints_of($publisher, 't_orders'),
    'a primary key change replicated');
is($subscriber->safe_psql('postgres', 'SELECT count(*) FROM t_orders WHERE id = 1'),
    '2', 'and rows only the new key accepts apply');

$publisher->safe_psql('postgres', 'DROP TABLE scratch');
$publisher->safe_psql('postgres', 'INSERT INTO customers VALUES (8)');
$publisher->wait_for_catchup('sub1');
is($subscriber->safe_psql('postgres', 'SELECT count(*) FROM customers'),
    '2', 'a DROP TABLE with constraints does not stop apply');
is($subscriber->safe_psql('postgres', q(SELECT to_regclass('public.scratch') IS NULL)),
    't', 'and the table is dropped');

$subscriber->stop;
$publisher->stop;
done_testing();
