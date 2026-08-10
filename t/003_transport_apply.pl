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
}

# create_table can't be gated per-relid (no oid exists yet when it runs), so
# it needs a database-wide wildcard rule on the publish side, set up before
# the table is created. Rename/drop of *this* table are then covered
# per-relid via publish_table() once the oid exists -- oid is stable across
# rename, so one call covers both.
$publisher->safe_psql('postgres',
    q(INSERT INTO ddl_repl.publish_rules (object_family, operation) VALUES ('table', 'create_table')));
$publisher->safe_psql('postgres', 'CREATE TABLE t_orders (id int)');
$publisher->safe_psql('postgres', q(SELECT ddl_repl.publish_table('t_orders'::regclass)));

$subscriber->safe_psql('postgres', 'CREATE TABLE t_orders (id int)');

$publisher->safe_psql('postgres', 'CREATE PUBLICATION pub1 FOR TABLE t_orders');
$publisher->safe_psql('postgres', "SELECT ddl_repl.enable_for_publication('pub1')");

my $publisher_connstr = $publisher->connstr . ' dbname=postgres';
$subscriber->safe_psql('postgres',
    "CREATE SUBSCRIPTION sub1 CONNECTION '$publisher_connstr' PUBLICATION pub1");
$subscriber->wait_for_subscription_sync($publisher, 'sub1');

# Subscribe side is keyed by (schema, table) name, not oid -- the two
# clusters were initialized independently, so the "same" logical table
# generally has a *different* oid on each side.
$subscriber->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('publisher', 'public', 't_orders')));

# --- rename ---
$publisher->safe_psql('postgres', 'ALTER TABLE t_orders RENAME TO t_orders_v2');
$publisher->wait_for_catchup('sub1');

is($subscriber->safe_psql('postgres', "SELECT to_regclass('t_orders_v2')::text"),
    't_orders_v2',
    'rename_table replicated to subscriber');
is($subscriber->safe_psql('postgres', "SELECT to_regclass('t_orders')::text IS NULL"),
    't',
    'old table name no longer exists on subscriber after rename');

# The rename changed the table's captured name going forward -- drop_table's
# payload will carry the *new* name ('t_orders_v2'), so a subscribe rule
# keyed on the old name won't match it. A known consequence of name-based
# subscribe-side keying (oid isn't portable across independently
# initialized clusters, see subscribe_rules' comment) -- add the matching rule.
$subscriber->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('publisher', 'public', 't_orders_v2')));

# --- drop ---
$publisher->safe_psql('postgres', 'DROP TABLE t_orders_v2');
$publisher->wait_for_catchup('sub1');

is($subscriber->safe_psql('postgres', "SELECT to_regclass('t_orders_v2')::text IS NULL"),
    't',
    'drop_table replicated to subscriber');

# --- loop prevention: replaying DDL on the subscriber must not re-queue it there ---
# The subscriber's own local CREATE TABLE t_orders was never captured at all
# (no publish rule on the subscriber -- it only has subscribe_rules), so
# source='subscriber' should have zero rows. If the loop-prevention check
# (session_replication_role = 'replica' during apply) had failed to suppress
# the subscriber's own event triggers while replaying the rename/drop, this
# would be nonzero instead.
is($subscriber->safe_psql('postgres',
        q(SELECT count(*) FROM ddl_repl.command_queue WHERE source_name = 'subscriber')),
    '0',
    q(subscriber's own event triggers did not recapture the replayed DDL));

# The publisher-sourced rows on the subscriber: 1 copied in by the initial
# table sync (the publisher's pre-existing CREATE TABLE capture) + rename +
# drop streamed afterwards = 3, all replayed (create_table is a deliberate
# no-op in v1, so it alone would leave applied_at NULL -- but rename/drop
# are not, so 2 of the 3 get stamped).
is($subscriber->safe_psql('postgres',
        q(SELECT count(*) FROM ddl_repl.command_queue WHERE source_name = 'publisher')),
    '3',
    'subscriber received the pre-existing create_table row plus the rename and drop');
is($subscriber->safe_psql('postgres',
        q(SELECT count(*) FROM ddl_repl.command_queue WHERE source_name = 'publisher' AND applied_at IS NOT NULL)),
    '2',
    'apply trigger replayed rename and drop on the subscriber (create_table is a no-op in v1)');

# --- applied_at is never stamped on the publisher's own local insert ---
$publisher->wait_for_catchup('sub1');
is($publisher->safe_psql('postgres',
        "SELECT count(*) FROM ddl_repl.command_queue WHERE applied_at IS NOT NULL"),
    '0',
    q(applied_at stays NULL on the publisher's own rows -- only a subscriber's apply trigger stamps it));

# --- purge: publisher-side deletes replicate and clean the subscriber's copy too ---
is($publisher->safe_psql('postgres', q(SELECT ddl_repl.purge_queue('0 seconds'))),
    '3',
    'purge_queue reports the publisher rows it deleted');
$publisher->wait_for_catchup('sub1');
is($subscriber->safe_psql('postgres',
        q(SELECT count(*) FROM ddl_repl.command_queue WHERE source_name = 'publisher')),
    '0',
    q(the purge DELETEs rode the publication and emptied the subscriber's copy));

$subscriber->stop;
$publisher->stop;
done_testing();
