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
    $node->safe_psql('postgres', q(
        CREATE EXTENSION pg_ddl_repl;
        CREATE SCHEMA s2;
        CREATE TABLE beat (id serial PRIMARY KEY);
        CREATE TABLE q_parted (id int, a int) PARTITION BY RANGE (id);
        CREATE TABLE q_part1 PARTITION OF q_parted FOR VALUES FROM (0) TO (100);
        CREATE TABLE customers (id int PRIMARY KEY);
        CREATE TABLE orders (id int PRIMARY KEY, cid int);
        ALTER TABLE orders ADD CONSTRAINT orders_cid_fkey FOREIGN KEY (cid) REFERENCES customers (id);
        CREATE TABLE events (id int, a int) PARTITION BY RANGE (id);
        CREATE TABLE s2.events_2024 PARTITION OF events FOR VALUES FROM (0) TO (100);
        CREATE TABLE k (a int, b int);
        CREATE UNIQUE INDEX k_b_idx ON k (b);
    ));
}
$subscriber->safe_psql('postgres', 'ALTER TABLE k ADD CONSTRAINT k_key UNIQUE (a)');
for my $table ('q_part1', 'customers', 'orders', 'events', 'k')
{
    $publisher->safe_psql('postgres', qq(SELECT ddl_repl.publish_table('$table'::regclass)));
}

$publisher->safe_psql('postgres', 'CREATE PUBLICATION pub1 FOR TABLE beat');
$publisher->safe_psql('postgres', "SELECT ddl_repl.enable_for_publication('pub1')");
my $publisher_connstr = $publisher->connstr . ' dbname=postgres';
$subscriber->safe_psql('postgres',
    "CREATE SUBSCRIPTION sub1 CONNECTION '$publisher_connstr' PUBLICATION pub1");
$subscriber->wait_for_subscription_sync($publisher, 'sub1');

sub catchup
{
    $publisher->safe_psql('postgres', 'INSERT INTO beat DEFAULT VALUES');
    $publisher->wait_for_catchup('sub1');
}

sub constraints_of
{
    my ($node, $table) = @_;
    return $node->safe_psql('postgres', qq(
        SELECT coalesce(string_agg(conname || ' ' || pg_get_constraintdef(oid) || ' valid=' || convalidated, E'\\n'
                                   ORDER BY conname), '')
        FROM pg_constraint WHERE conrelid = '$table'::regclass));
}

for my $table ('q_part1', 'customers', 'orders', 'events', 'k')
{
    $subscriber->safe_psql('postgres', qq(SELECT ddl_repl.subscribe_table('publisher', 'public', '$table')));
}

# Partition published, parent not: the parent's DDL must still keep the partition's map right.
$publisher->safe_psql('postgres', 'ALTER TABLE q_parted ADD CONSTRAINT q_check CHECK (a > 0)');
$subscriber->safe_psql('postgres', 'ALTER TABLE q_parted ADD CONSTRAINT q_check CHECK (a > 0)');
$publisher->safe_psql('postgres', 'ALTER TABLE q_parted DROP CONSTRAINT q_check');
$publisher->safe_psql('postgres', 'INSERT INTO beat DEFAULT VALUES');
my $target = $publisher->safe_psql('postgres', 'SELECT pg_current_wal_lsn()');
$publisher->poll_query_until('postgres',
    qq(SELECT confirmed_flush_lsn >= '$target' FROM pg_replication_slots WHERE slot_name = 'sub1'))
  or diag('apply did not catch up');
is($subscriber->safe_psql('postgres', 'SELECT pid IS NOT NULL FROM pg_stat_subscription'), 't',
    'an inherited copy dropped through an unpublished parent does not stop apply');
is($publisher->safe_psql('postgres', q(
        SELECT count(*) FROM ddl_repl.command_queue
        WHERE payload->>'table_name' = 'q_part1' AND payload::text LIKE '%q_check%')),
    '0', 'and the inherited copy is known as inherited: nothing is queued for it');
$subscriber->safe_psql('postgres', 'ALTER TABLE q_parted DROP CONSTRAINT q_check');

# Renaming a foreign key must not touch the referenced table's index in the map.
$publisher->safe_psql('postgres', 'ALTER TABLE orders RENAME CONSTRAINT orders_cid_fkey TO fk_cust');
is($publisher->safe_psql('postgres', q(
        SELECT index_name FROM ddl_repl.index_table_map WHERE index_oid = 'customers_pkey'::regclass)),
    'customers_pkey', 'renaming a foreign key leaves the referenced index name alone');

# Detach of a partition in another schema.
$publisher->safe_psql('postgres', 'SET search_path = public, s2; ALTER TABLE events DETACH PARTITION events_2024');
catchup();
is($subscriber->safe_psql('postgres', q(SELECT count(*) FROM pg_inherits WHERE inhrelid = 's2.events_2024'::regclass)),
    '0', 'detaching a partition from another schema replicates');

# A stale same-name constraint of another kind is replaced, not taken as already applied.
$publisher->safe_psql('postgres', 'ALTER TABLE k ADD CONSTRAINT k_key PRIMARY KEY USING INDEX k_b_idx');
catchup();
is(constraints_of($subscriber, 'k'), constraints_of($publisher, 'k'),
    'a same-name constraint of another kind is replaced by the USING INDEX one');

# A dropped constraint the maps never recorded is reported, not guessed into a drop by name.
$publisher->safe_psql('postgres', q(
    ALTER TABLE orders ADD CONSTRAINT orders_cid_check CHECK (cid > 0);
    DELETE FROM ddl_repl.constraint_map WHERE constraint_oid =
        (SELECT oid FROM pg_constraint WHERE conname = 'orders_cid_check');
    ALTER TABLE orders DROP CONSTRAINT orders_cid_check;
));
is($publisher->safe_psql('postgres', q(
        SELECT payload->>'detail' FROM ddl_repl.command_queue
        WHERE payload->>'operation' = 'unsupported' ORDER BY id DESC LIMIT 1)),
    'drop of untracked constraint orders_cid_check', 'an untracked constraint drop is reported as unsupported');

# A table that existed, unpublished, before its rule was enabled.
for my $node ($publisher, $subscriber)
{
    $node->safe_psql('postgres', 'CREATE TABLE late (id int CONSTRAINT late_pk PRIMARY KEY)');
}
$publisher->safe_psql('postgres', q(
    INSERT INTO ddl_repl.publish_rules (relid, object_family, operation)
    VALUES ('late'::regclass, 'constraint', 'drop_constraint');
));
$subscriber->safe_psql('postgres', q(
    INSERT INTO ddl_repl.subscribe_rules (source_name, schema_name, table_name, object_family, operation)
    VALUES ('publisher', 'public', 'late', 'constraint', 'drop_constraint');
));
$publisher->safe_psql('postgres', 'ALTER TABLE late DROP CONSTRAINT late_pk');
catchup();
is(constraints_of($subscriber, 'late'), constraints_of($publisher, 'late'),
    'a constraint of a table published after its creation is dropped');

$subscriber->stop;
$publisher->stop;
done_testing();
