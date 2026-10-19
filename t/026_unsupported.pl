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
    $node->safe_psql('postgres', 'CREATE UNLOGGED TABLE t (id int PRIMARY KEY)');
    $node->safe_psql('postgres', 'CREATE TABLE beat (id serial PRIMARY KEY)');
}

$publisher->safe_psql('postgres', q(SELECT ddl_repl.publish_table('t'::regclass)));
$publisher->safe_psql('postgres', 'CREATE PUBLICATION pub1 FOR TABLE beat');
$publisher->safe_psql('postgres', "SELECT ddl_repl.enable_for_publication('pub1')");

my $publisher_connstr = $publisher->connstr . ' dbname=postgres';
$subscriber->safe_psql('postgres',
    "CREATE SUBSCRIPTION sub1 CONNECTION '$publisher_connstr' PUBLICATION pub1");
$subscriber->wait_for_subscription_sync($publisher, 'sub1');
$subscriber->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('publisher', 'public', 't')));

# The subscriber's copy has rows: a NOT NULL replayed without its default would stop apply.
for my $node ($publisher, $subscriber)
{
    $node->safe_psql('postgres', 'INSERT INTO t VALUES (1), (2)');
}
$publisher->safe_psql('postgres', 'ALTER TABLE t ADD COLUMN ident int GENERATED ALWAYS AS IDENTITY');
$publisher->safe_psql('postgres', 'ALTER TABLE t ADD COLUMN created timestamptz NOT NULL DEFAULT now()');
$publisher->safe_psql('postgres', 'ALTER TABLE t SET LOGGED');
$publisher->safe_psql('postgres', 'INSERT INTO beat DEFAULT VALUES');
$publisher->wait_for_catchup('sub1');

is($publisher->safe_psql('postgres', q(
        SELECT string_agg(payload->>'detail', ', ' ORDER BY id) FROM ddl_repl.command_queue
        WHERE payload->>'operation' = 'unsupported')),
    'column ident: identity column (NOT NULL not replicated), column created: non-immutable default (NOT NULL not replicated), logged/unlogged change',
    'schema changes with no replay are queued as unsupported');
is($subscriber->safe_psql('postgres', q(
        SELECT count(*) FROM ddl_repl.command_queue WHERE payload->>'operation' = 'unsupported' AND applied_at IS NULL)),
    '3', 'and left unapplied on the subscriber');
like(slurp_file($subscriber->logfile), qr/WARNING:  pg_ddl_repl: unsupported DDL from publisher on public\.t: logged\/unlogged change/,
    'with a warning in the subscriber log');
is($subscriber->safe_psql('postgres', q(SELECT atthasdef FROM pg_attribute WHERE attrelid = 't'::regclass AND attname = 'created')),
    'f', 'the column with a non-immutable default still replicates, without its default');
is($subscriber->safe_psql('postgres', 'SELECT pid IS NOT NULL FROM pg_stat_subscription'), 't', 'and apply keeps running');

$subscriber->stop;
$publisher->stop;
done_testing();
