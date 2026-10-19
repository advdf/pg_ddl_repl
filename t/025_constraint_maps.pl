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
    $node->safe_psql('postgres', 'CREATE TABLE r (id int PRIMARY KEY, title text NOT NULL, qty int)');
    $node->safe_psql('postgres', 'CREATE TABLE beat (id serial PRIMARY KEY)');
}

# r: per-table rules. w, w_parted: only wildcard rules (no relid), created after the extension.
$publisher->safe_psql('postgres', q(SELECT ddl_repl.publish_table('r'::regclass)));
$publisher->safe_psql('postgres', q(
    INSERT INTO ddl_repl.publish_rules (object_family, operation) VALUES
        ('constraint', 'add_constraint'), ('constraint', 'drop_constraint'), ('column', 'set_not_null');
));
$publisher->safe_psql('postgres', 'CREATE PUBLICATION pub1 FOR TABLE r, beat');
$publisher->safe_psql('postgres', "SELECT ddl_repl.enable_for_publication('pub1')");

my $publisher_connstr = $publisher->connstr . ' dbname=postgres';
$subscriber->safe_psql('postgres',
    "CREATE SUBSCRIPTION sub1 CONNECTION '$publisher_connstr' PUBLICATION pub1");
$subscriber->wait_for_subscription_sync($publisher, 'sub1');
$subscriber->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('publisher', 'public', 'r')));
$subscriber->safe_psql('postgres', q(
    INSERT INTO ddl_repl.subscribe_rules (source_name, object_family, operation) VALUES
        ('publisher', 'constraint', 'add_constraint'), ('publisher', 'constraint', 'drop_constraint'),
        ('publisher', 'column', 'set_not_null');
));

for my $node ($publisher, $subscriber)
{
    $node->safe_psql('postgres', q(
        CREATE TABLE w (id int, note text NOT NULL);
        CREATE UNIQUE INDEX w_id_idx ON w (id);
        CREATE TABLE w_parted (id int, a int) PARTITION BY RANGE (id);
        CREATE TABLE w_parted_1 PARTITION OF w_parted FOR VALUES FROM (0) TO (100);
    ));
}

sub constraints_of
{
    my ($node, $table) = @_;
    return $node->safe_psql('postgres', qq(
        SELECT coalesce(string_agg(conname || ' ' || pg_get_constraintdef(oid), E'\\n' ORDER BY conname), '')
        FROM pg_constraint WHERE conrelid = 'public.$table'::regclass AND contype <> 'n'));
}

sub catchup
{
    $publisher->safe_psql('postgres', 'INSERT INTO beat DEFAULT VALUES');
    $publisher->wait_for_catchup('sub1');
}

# A constraint redefined under the same name in one statement.
$publisher->safe_psql('postgres', 'ALTER TABLE r ADD CONSTRAINT r_qty_check CHECK (qty > 0)');
$publisher->safe_psql('postgres',
    'ALTER TABLE r DROP CONSTRAINT r_qty_check, ADD CONSTRAINT r_qty_check CHECK (qty > 10)');
catchup();
is(constraints_of($subscriber, 'r'), constraints_of($publisher, 'r'),
    'a constraint redefined under the same name replicates the new definition');

# A constraint added in the same statement as a type change of its column.
$publisher->safe_psql('postgres',
    'ALTER TABLE r ADD CONSTRAINT r_qty_max CHECK (qty < 1000), ALTER COLUMN qty TYPE bigint');
catchup();
is(constraints_of($subscriber, 'r'), constraints_of($publisher, 'r'),
    'a constraint added with a type change of its column replicates');

# One drop_not_null per DROP NOT NULL.
$publisher->safe_psql('postgres', 'ALTER TABLE r ALTER COLUMN qty SET NOT NULL');
$publisher->safe_psql('postgres', 'ALTER TABLE r ALTER COLUMN qty DROP NOT NULL');
is($publisher->safe_psql('postgres', q(
        SELECT count(*) FROM ddl_repl.command_queue
        WHERE payload->>'operation' = 'drop_not_null' AND payload->>'column_name' = 'qty')),
    '1', 'a DROP NOT NULL is queued once');

SKIP:
{
    skip 'NOT NULL constraints need PostgreSQL 18', 2 if $pg18 ne 't';

    # The map must follow a column rename.
    $publisher->safe_psql('postgres', 'ALTER TABLE r RENAME COLUMN title TO name');
    $publisher->safe_psql('postgres', 'ALTER TABLE r DROP CONSTRAINT r_title_not_null');
    catchup();
    is($subscriber->safe_psql('postgres',
            q(SELECT attnotnull FROM pg_attribute WHERE attrelid = 'r'::regclass AND attname = 'name')),
        'f', 'dropping the NOT NULL of a renamed column replicates');

    # Wildcard-published table: the NOT NULL drop stays under drop_not_null, which is not published.
    $publisher->safe_psql('postgres', 'ALTER TABLE w DROP CONSTRAINT w_note_not_null');
    is($publisher->safe_psql('postgres', q(
            SELECT count(*) FROM ddl_repl.command_queue WHERE payload->>'table_name' = 'w'
            AND payload->>'operation' IN ('drop_constraint', 'drop_not_null'))),
        '0', 'a NOT NULL drop on a wildcard-published table does not bypass drop_not_null');
}

# USING INDEX on an index whose creation was not captured.
$publisher->safe_psql('postgres', 'ALTER TABLE w ADD CONSTRAINT w_id_key UNIQUE USING INDEX w_id_idx');
catchup();
is($subscriber->safe_psql('postgres', q(SELECT string_agg(indexrelid::regclass::text, ',') FROM pg_index WHERE indrelid = 'w'::regclass)),
    $publisher->safe_psql('postgres', q(SELECT string_agg(indexrelid::regclass::text, ',') FROM pg_index WHERE indrelid = 'w'::regclass)),
    'USING INDEX reuses an index created outside capture');

# Partition created after the extension, parent published by wildcard rules.
$publisher->safe_psql('postgres', 'ALTER TABLE w_parted ADD CONSTRAINT wp_check CHECK (a > 0)');
$publisher->safe_psql('postgres', 'ALTER TABLE w_parted DROP CONSTRAINT wp_check');
catchup();
is(constraints_of($subscriber, 'w_parted_1'), '', 'the partition copy is dropped by the parent replay');
is($subscriber->safe_psql('postgres', 'SELECT pid IS NOT NULL FROM pg_stat_subscription'), 't',
    'and apply keeps running');

# Detached partition: its inherited copy becomes local, so a later drop on it must replicate.
for my $node ($publisher, $subscriber)
{
    $node->safe_psql('postgres', q(
        CREATE TABLE d_parted (id int, a int) PARTITION BY RANGE (id);
        CREATE TABLE d_part PARTITION OF d_parted FOR VALUES FROM (0) TO (100);
    ));
}
$subscriber->safe_psql('postgres', q(
    INSERT INTO ddl_repl.subscribe_rules (source_name, object_family, operation)
    VALUES ('publisher', 'table', 'detach_partition') ON CONFLICT DO NOTHING;
));
$publisher->safe_psql('postgres', q(
    INSERT INTO ddl_repl.publish_rules (object_family, operation)
    VALUES ('table', 'detach_partition') ON CONFLICT DO NOTHING;
));
$publisher->safe_psql('postgres', 'ALTER TABLE d_parted ADD CONSTRAINT d_check CHECK (a > 0)');
$publisher->safe_psql('postgres', 'ALTER TABLE d_parted DETACH PARTITION d_part');
$publisher->safe_psql('postgres', 'ALTER TABLE d_part DROP CONSTRAINT d_check');
catchup();
is(constraints_of($subscriber, 'd_part'), '', 'a constraint dropped on a detached partition replicates');

$subscriber->stop;
$publisher->stop;
done_testing();
