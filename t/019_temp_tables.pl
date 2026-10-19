use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('publisher');
$node->init(allows_streaming => 'logical');
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_ddl_repl;');
$node->safe_psql('postgres', q(
    INSERT INTO ddl_repl.publish_rules (object_family, operation) VALUES
        ('table', 'drop_table'), ('column', 'add_column'),
        ('index', 'create_index'), ('index', 'drop_index');
));

$node->safe_psql('postgres', q(
    CREATE TEMP TABLE tmp (id int);
    ALTER TABLE tmp ADD COLUMN a int;
    CREATE INDEX tmp_a_idx ON tmp (a);
    DROP INDEX tmp_a_idx;
    DROP TABLE tmp;
));
is($node->safe_psql('postgres', 'SELECT count(*) FROM ddl_repl.command_queue'),
    '0', 'DDL on a temporary table is never captured, even with wildcard rules');

$node->safe_psql('postgres', 'CREATE TABLE regular (id int)');
$node->safe_psql('postgres', 'ALTER TABLE regular ADD COLUMN a int');
is($node->safe_psql('postgres', q(SELECT count(*) FROM ddl_repl.command_queue WHERE payload->>'table_name' = 'regular')),
    '1', 'while the same rules still capture a regular table');

$node->stop;
done_testing();
