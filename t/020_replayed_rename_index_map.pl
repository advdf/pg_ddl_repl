use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# A node that receives a rename and also publishes: its own index_table_map must follow.
my $node = PostgreSQL::Test::Cluster->new('middle');
$node->init(allows_streaming => 'logical');
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_ddl_repl;');
$node->safe_psql('postgres', 'CREATE TABLE t (id int, a int)');
$node->safe_psql('postgres', q(SELECT ddl_repl.publish_table('t'::regclass)));
$node->safe_psql('postgres', 'CREATE INDEX t_a_idx ON t (a)');
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

my ($ret) = replay(q({"schema_version": 1, "object_family": "table", "operation": "rename_table",
          "schema_name": "public", "table_name": "t", "new_name": "t2"}));
is($ret, 0, 'replayed rename applied');

$node->safe_psql('postgres', 'DROP INDEX t_a_idx');
is($node->safe_psql('postgres',
        q(SELECT payload->>'table_name' FROM ddl_repl.command_queue
          WHERE source_name <> 'src' AND payload->>'operation' = 'drop_index')),
    't2', 'a local drop_index after a replayed rename carries the new table name');

$node->stop;
done_testing();
