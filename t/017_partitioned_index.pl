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
    $node->safe_psql('postgres', 'CREATE TABLE parted (id int, a int) PARTITION BY RANGE (id)');
    $node->safe_psql('postgres', 'CREATE TABLE parted_1 PARTITION OF parted FOR VALUES FROM (0) TO (100)');
    $node->safe_psql('postgres', 'CREATE TABLE parted_2 PARTITION OF parted FOR VALUES FROM (100) TO (200)');
}

$publisher->safe_psql('postgres', q(SELECT ddl_repl.publish_table('parted'::regclass)));

$publisher->safe_psql('postgres', 'CREATE PUBLICATION pub1 FOR TABLE parted');
$publisher->safe_psql('postgres', "SELECT ddl_repl.enable_for_publication('pub1')");

my $publisher_connstr = $publisher->connstr . ' dbname=postgres';
$subscriber->safe_psql('postgres',
    "CREATE SUBSCRIPTION sub1 CONNECTION '$publisher_connstr' PUBLICATION pub1");
$subscriber->wait_for_subscription_sync($publisher, 'sub1');
$subscriber->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('publisher', 'public', 'parted')));

$publisher->safe_psql('postgres', 'CREATE INDEX parted_a_idx ON parted (a)');
$publisher->wait_for_catchup('sub1');
is($subscriber->safe_psql('postgres',
        q(SELECT indisvalid FROM pg_index WHERE indexrelid = 'public.parted_a_idx'::regclass)),
    't', 'an index on a partitioned table is valid on the subscriber');
is($subscriber->safe_psql('postgres',
        q(SELECT count(*) FROM pg_inherits i JOIN pg_index x ON x.indexrelid = i.inhrelid
          WHERE i.inhparent = 'public.parted_a_idx'::regclass)),
    '2', 'and built on every partition');

$subscriber->stop;
$publisher->stop;
done_testing();
