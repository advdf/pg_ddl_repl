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

plan skip_all => 'PostgreSQL 18 constraint features'
  if $publisher->safe_psql('postgres', q(SELECT current_setting('server_version_num')::int < 180000)) eq 't';

for my $node ($publisher, $subscriber)
{
    $node->safe_psql('postgres', q(
        CREATE EXTENSION pg_ddl_repl;
        CREATE TABLE beat (id serial PRIMARY KEY);
        CREATE TABLE p (id int PRIMARY KEY);
        CREATE TABLE t (id int PRIMARY KEY, title text, pid int);
        INSERT INTO p VALUES (1);
        INSERT INTO t VALUES (1, 'a', 1);
        ALTER TABLE t ADD CONSTRAINT t_pid_fkey FOREIGN KEY (pid) REFERENCES p (id);
    ));
}
$publisher->safe_psql('postgres', q(SELECT ddl_repl.publish_table('t'::regclass)));

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

$subscriber->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('publisher', 'public', 't')));

$publisher->safe_psql('postgres', 'ALTER TABLE t ADD CONSTRAINT nn_title NOT NULL title NOT VALID');
catchup();
is(constraints_of($subscriber, 't'), constraints_of($publisher, 't'), 'a named NOT NULL NOT VALID keeps its name and validity');

$publisher->safe_psql('postgres', 'ALTER TABLE t VALIDATE CONSTRAINT nn_title');
$publisher->safe_psql('postgres', 'ALTER TABLE t RENAME CONSTRAINT nn_title TO nn_title2');
catchup();
is(constraints_of($subscriber, 't'), constraints_of($publisher, 't'), 'and VALIDATE / RENAME of it replicate');

$publisher->safe_psql('postgres', 'ALTER TABLE t ALTER CONSTRAINT t_pid_fkey NOT ENFORCED');
catchup();
is(constraints_of($subscriber, 't'), constraints_of($publisher, 't'), 'ALTER CONSTRAINT ... NOT ENFORCED replicates');

$publisher->safe_psql('postgres', 'ALTER TABLE t ALTER CONSTRAINT nn_title2 NO INHERIT');
catchup();
is(constraints_of($subscriber, 't'), constraints_of($publisher, 't'), 'ALTER CONSTRAINT ... NO INHERIT replicates');
is($subscriber->safe_psql('postgres', 'SELECT pid IS NOT NULL FROM pg_stat_subscription'), 't', 'and apply keeps running');

$subscriber->stop;
$publisher->stop;
done_testing();
