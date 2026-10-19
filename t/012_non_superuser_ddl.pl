use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('publisher');
$node->init(allows_streaming => 'logical');
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_ddl_repl;');
$node->safe_psql('postgres', 'CREATE ROLE app LOGIN');
$node->safe_psql('postgres', 'CREATE SCHEMA app AUTHORIZATION app');

my @as_app = (extra_params => [ '-U', 'app' ]);

my ($ret, $stdout, $stderr) = $node->psql('postgres', q(
    CREATE TABLE app.scratch (id int PRIMARY KEY);
    ALTER TABLE app.scratch ADD COLUMN note text;
    CREATE INDEX scratch_note_idx ON app.scratch (note);
    DROP TABLE app.scratch;
    CREATE TEMP TABLE tmp (id int);
), @as_app);
is($ret, 0, 'non-superuser DDL on an unpublished table succeeds');
is($stderr, '', 'no error raised by the capture triggers');

$node->safe_psql('postgres', 'CREATE TABLE app.orders (id int PRIMARY KEY)', @as_app);
$node->safe_psql('postgres', q(SELECT ddl_repl.publish_table('app.orders'::regclass)));

($ret, $stdout, $stderr) = $node->psql('postgres',
    'ALTER TABLE app.orders ADD COLUMN amount int', @as_app);
is($ret, 0, 'non-superuser DDL on a published table succeeds');
is($node->safe_psql('postgres',
        q(SELECT count(*) FROM ddl_repl.command_queue WHERE payload->>'operation' = 'add_column')),
    '1', 'and is captured');

($ret, $stdout, $stderr) = $node->psql('postgres', 'DROP TABLE app.orders', @as_app);
is($ret, 0, 'non-superuser DROP TABLE on a published table succeeds');
is($node->safe_psql('postgres',
        q(SELECT count(*) FROM ddl_repl.command_queue WHERE payload->>'operation' = 'drop_table')),
    '1', 'and is captured');

($ret, $stdout, $stderr) = $node->psql('postgres',
    q(INSERT INTO ddl_repl.command_queue (source_name, payload) VALUES ('x', '{}')), @as_app);
isnt($ret, 0, 'non-superuser still cannot write the queue directly');

$node->stop;
done_testing();
