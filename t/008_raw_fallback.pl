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
    $node->safe_psql('postgres', 'CREATE TABLE t_orders (id int, amount numeric)');
}

$publisher->safe_psql('postgres', q(SELECT ddl_repl.publish_table('t_orders'::regclass)));
$publisher->safe_psql('postgres', 'CREATE PUBLICATION pub1 FOR TABLE t_orders');
$publisher->safe_psql('postgres', "SELECT ddl_repl.enable_for_publication('pub1')");

my $publisher_connstr = $publisher->connstr . ' dbname=postgres';
$subscriber->safe_psql('postgres',
    "CREATE SUBSCRIPTION sub1 CONNECTION '$publisher_connstr' PUBLICATION pub1");
$subscriber->wait_for_subscription_sync($publisher, 'sub1');

$subscriber->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('publisher', 'public', 't_orders')));

# --- without opt-in: captured for audit, never replayed ---
$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ALTER COLUMN amount SET DEFAULT 0');
$publisher->wait_for_catchup('sub1');

is($subscriber->safe_psql('postgres',
        q(SELECT column_default FROM information_schema.columns WHERE table_name = 't_orders' AND column_name = 'amount')),
    '',
    'alter_column_default is NOT replayed by default (raw fallback opt-in not enabled)');
is($subscriber->safe_psql('postgres',
        q(SELECT count(*) FROM ddl_repl.command_queue WHERE payload->>'operation' = 'alter_column_default' AND applied_at IS NOT NULL)),
    '0',
    'the unreplayed row stays unmarked as applied');

# --- with opt-in: the verbatim command text is replayed ---
$subscriber->safe_psql('postgres', q(SELECT ddl_repl.enable_raw_fallback('publisher', 'public', 't_orders')));
$publisher->safe_psql('postgres', 'ALTER TABLE t_orders ALTER COLUMN amount SET DEFAULT 42');
$publisher->wait_for_catchup('sub1');

is($subscriber->safe_psql('postgres',
        q(SELECT column_default FROM information_schema.columns WHERE table_name = 't_orders' AND column_name = 'amount')),
    '42',
    'alter_column_default IS replayed once the table opts in to raw fallback');

$subscriber->stop;
$publisher->stop;
done_testing();
