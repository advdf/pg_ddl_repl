use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Simulates queue rows arriving through a subscription: the apply trigger
# only fires under session_replication_role = replica.
my $node = PostgreSQL::Test::Cluster->new('subscriber');
$node->init;
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_ddl_repl;');
$node->safe_psql('postgres', 'CREATE TABLE t (id int CONSTRAINT t_local_pk PRIMARY KEY, title text)');
$node->safe_psql('postgres', 'CREATE TABLE local_ref (t_id int REFERENCES t (id))');
$node->safe_psql('postgres', q(SELECT ddl_repl.subscribe_table('src', 'public', 't')));

my $next_id = 1;

sub replay
{
    my ($payload) = @_;
    my $id = $next_id++;
    my ($ret, $stdout, $stderr) = $node->psql('postgres', qq(
        SET session_replication_role = replica;
        INSERT INTO ddl_repl.command_queue (id, source_name, payload)
        VALUES ($id, 'src', \$p\$$payload\$p\$::jsonb);
    ));
    return ($ret, $stderr);
}

my ($ret, $stderr) = replay(q({"schema_version": 1, "object_family": "constraint", "operation": "drop_constraint",
          "schema_name": "public", "table_name": "t", "constraint_name": "t_local_pk"}));
isnt($ret, 0, 'a replayed drop with a subscriber-only dependent is refused');
like($stderr, qr/depend/, 'with the dependency error');
is($node->safe_psql('postgres', q(SELECT count(*) FROM pg_constraint WHERE conrelid = 'local_ref'::regclass AND contype = 'f')),
    '1', 'and the subscriber-only foreign key is kept');

($ret, $stderr) = replay(q({"schema_version": 1, "object_family": "constraint", "operation": "add_constraint",
          "schema_name": "public", "table_name": "t", "constraint_name": "t_pkey",
          "contype": "p", "constraint_def": "PRIMARY KEY (id, title)"}));
isnt($ret, 0, 'a replayed primary key on a table that has another one is refused');
like($stderr, qr/already has primary key "t_local_pk"/, 'with an error naming both keys');

$node->stop;
done_testing();
