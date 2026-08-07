use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_ddl_repl;');

is($node->safe_psql('postgres',
        "SELECT extname FROM pg_extension WHERE extname = 'pg_ddl_repl'"),
    'pg_ddl_repl',
    'extension pg_ddl_repl loads');

is($node->safe_psql('postgres',
        "SELECT nspname FROM pg_namespace WHERE nspname = 'ddl_repl'"),
    'ddl_repl',
    'schema ddl_repl created');

$node->stop;
done_testing();
