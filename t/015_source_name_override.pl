use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('origin');
$node->init(allows_streaming => 'logical');
$node->append_conf('postgresql.conf', "cluster_name = 'origin'");
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_ddl_repl;');
$node->safe_psql('postgres', 'CREATE ROLE app LOGIN');
$node->safe_psql('postgres', 'CREATE SCHEMA app AUTHORIZATION app');
$node->safe_psql('postgres', 'CREATE TABLE app.t (id int)', extra_params => [ '-U', 'app' ]);
$node->safe_psql('postgres', q(SELECT ddl_repl.publish_table('app.t'::regclass)));

sub last_source
{
    return $node->safe_psql('postgres',
        'SELECT source_name FROM ddl_repl.command_queue ORDER BY captured_at DESC, id DESC LIMIT 1');
}

$node->safe_psql('postgres', q(
    SET ddl_repl.source_name = 'forged';
    ALTER TABLE app.t ADD COLUMN a int;
), extra_params => [ '-U', 'app' ]);
is(last_source(), 'origin', 'a non-superuser session cannot override source_name');

$node->psql('postgres', q(ALTER ROLE app SET ddl_repl.source_name = 'forged-role'),
    extra_params => [ '-U', 'app' ]);
$node->safe_psql('postgres', 'ALTER TABLE app.t ADD COLUMN b int', extra_params => [ '-U', 'app' ]);
is(last_source(), 'origin', 'nor through a per-role setting');
$node->safe_psql('postgres', 'ALTER ROLE app RESET ddl_repl.source_name');

$node->safe_psql('postgres', q(
    SET ddl_repl.source_name = 'set-by-superuser';
    ALTER TABLE app.t ADD COLUMN c int;
));
is(last_source(), 'set-by-superuser', 'a superuser session can override source_name');

# Before PG17, ALTER SYSTEM only accepts the parameter once the library defining it is loaded.
$node->safe_psql('postgres', q(
    LOAD 'pg_ddl_repl';
    ALTER SYSTEM SET ddl_repl.source_name = 'from-config';
));
$node->reload;
$node->safe_psql('postgres', 'ALTER TABLE app.t ADD COLUMN d int', extra_params => [ '-U', 'app' ]);
is(last_source(), 'from-config', 'a server-wide setting applies to every role');

$node->stop;
done_testing();
