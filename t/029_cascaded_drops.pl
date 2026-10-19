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

my @tables = ('u', 'pa', 'pa_1', 'pa_2', 'pu', 'pu_1', 'fx', 'pd', 'pd_1');
for my $node ($publisher, $subscriber)
{
    $node->safe_psql('postgres', q(
        CREATE EXTENSION pg_ddl_repl;
        CREATE TABLE beat (id serial PRIMARY KEY);
        CREATE TABLE u (id int, e text CONSTRAINT u_e_key UNIQUE, f int);
        CREATE INDEX u_f_idx ON u (f);
        CREATE TABLE pa (id int, a int) PARTITION BY RANGE (id);
        CREATE TABLE pa_1 PARTITION OF pa FOR VALUES FROM (0) TO (100);
        CREATE TABLE pa_2 PARTITION OF pa FOR VALUES FROM (100) TO (200);
        CREATE INDEX pa_a_idx ON pa (a);
        CREATE TABLE pu (id int, a int, CONSTRAINT pu_uq UNIQUE (id, a)) PARTITION BY RANGE (id);
        CREATE TABLE pu_1 PARTITION OF pu FOR VALUES FROM (0) TO (100);
        CREATE FUNCTION f(int) RETURNS int IMMUTABLE LANGUAGE sql AS 'SELECT $1 + 1';
        CREATE TABLE fx (id int, a int, CONSTRAINT fx_chk CHECK (f(a) > 0));
        CREATE INDEX fx_f_idx ON fx (f(a));
        CREATE TABLE pd (id int, a int) PARTITION BY RANGE (id);
        CREATE TABLE pd_1 PARTITION OF pd FOR VALUES FROM (0) TO (100);
    ));
}
for my $table (@tables)
{
    $publisher->safe_psql('postgres', qq(SELECT ddl_repl.publish_table('$table'::regclass)));
}

$publisher->safe_psql('postgres', 'CREATE PUBLICATION pub1 FOR TABLE beat');
$publisher->safe_psql('postgres', "SELECT ddl_repl.enable_for_publication('pub1')");
my $publisher_connstr = $publisher->connstr . ' dbname=postgres';
$subscriber->safe_psql('postgres',
    "CREATE SUBSCRIPTION sub1 CONNECTION '$publisher_connstr' PUBLICATION pub1");
$subscriber->wait_for_subscription_sync($publisher, 'sub1');
for my $table (@tables)
{
    $subscriber->safe_psql('postgres', qq(SELECT ddl_repl.subscribe_table('publisher', 'public', '$table')));
}

sub catchup
{
    $publisher->safe_psql('postgres', 'INSERT INTO beat DEFAULT VALUES');
    my $target = $publisher->safe_psql('postgres', 'SELECT pg_current_wal_lsn()');
    $publisher->poll_query_until('postgres',
        qq(SELECT confirmed_flush_lsn >= '$target' FROM pg_replication_slots WHERE slot_name = 'sub1'))
      or diag('apply did not catch up');
}

sub indexes_of
{
    my ($node, $prefix) = @_;
    return $node->safe_psql('postgres', qq(
        SELECT coalesce(string_agg(x.relname, ',' ORDER BY x.relname), '')
        FROM pg_index i JOIN pg_class x ON x.oid = i.indexrelid JOIN pg_class c ON c.oid = i.indrelid
        WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE '$prefix%'));
}

sub unapplied
{
    my ($node, $prefix) = @_;
    return $node->safe_psql('postgres', qq(
        SELECT coalesce(string_agg(payload->>'operation' || ' ' || coalesce(payload->>'index_name', payload->>'table_name'),
                                   ',' ORDER BY id), '')
        FROM ddl_repl.command_queue
        WHERE applied_at IS NULL AND (payload->>'table_name' LIKE '$prefix%' OR payload->>'index_name' LIKE '$prefix%')));
}

my @cases = (
    ['u',  'ALTER TABLE u DROP CONSTRAINT u_e_key; DROP TABLE u', 'a unique constraint then its table'],
    ['pa', 'DROP INDEX pa_a_idx',                                  'a partitioned index'],
    ['pu', 'ALTER TABLE pu DROP CONSTRAINT pu_uq',                 'a unique constraint of a partitioned table'],
    ['fx', 'DROP FUNCTION f(int) CASCADE',                         'a function with a check and an expression index on it'],
    ['pd', 'DROP TABLE pd',                                        'a partitioned table with a partitioned index'],
);
for my $case (@cases)
{
    my ($prefix, $ddl, $label) = @$case;
    $publisher->safe_psql('postgres', $ddl);
    catchup();
    is(indexes_of($subscriber, $prefix), indexes_of($publisher, $prefix), "dropping $label: indexes match");
    is(unapplied($subscriber, $prefix), '', "dropping $label: every queued row is applied");
}
is($subscriber->safe_psql('postgres', 'SELECT pid IS NOT NULL FROM pg_stat_subscription'), 't', 'apply still running');

$subscriber->stop;
$publisher->stop;
done_testing();
