use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep time);

# Random DDL on the publisher; after each batch both nodes must hold identical tables and apply must run.
# Reproduce or widen with DDL_FUZZ_SEEDS="1 2 3" and DDL_FUZZ_STEPS=40.
my @seeds = split /\s+/, ($ENV{DDL_FUZZ_SEEDS} // '1 2 3 4 5 6 7 8');
my $steps = $ENV{DDL_FUZZ_STEPS} // 40;
my $batch = 4;

my @types = ('int', 'bigint', 'text', 'varchar(20)', 'numeric(10,2)', 'mood');

sub literal_for
{
    my ($type) = @_;
    return int(rand(100)) if $type =~ /^(int|integer|bigint|smallint)$/;
    return sprintf("'%d.%02d'", int(rand(100)), int(rand(100))) if $type =~ /^numeric/;
    return (rand() < 0.5 ? "'ok'" : "'ko'") if $type =~ /mood/;
    return "'v" . int(rand(1000)) . "'";
}

sub pick { return $_[ int(rand(scalar @_)) ] }

sub fingerprint_sql
{
    return q{
        WITH t AS (
            SELECT c.oid, n.nspname || '.' || c.relname AS relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname IN ('public', 's2') AND c.relkind IN ('r', 'p') AND c.relname NOT IN ('beat', 'q_parted')
        )
        SELECT string_agg(line, E'\n' ORDER BY line) FROM (
            SELECT 'table ' || t.relname
                   || coalesce(' partition of ' || p.relname || ' ' || pg_get_expr(c.relpartbound, c.oid), '') AS line
            FROM t JOIN pg_class c ON c.oid = t.oid
            LEFT JOIN pg_inherits i ON i.inhrelid = t.oid LEFT JOIN pg_class p ON p.oid = i.inhparent
            UNION ALL
            SELECT format('column %s.%s %s notnull=%s default=%s', t.relname, a.attname,
                          format_type(a.atttypid, a.atttypmod), a.attnotnull,
                          coalesce(pg_get_expr(d.adbin, d.adrelid), '-'))
            FROM t JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped
            LEFT JOIN pg_attrdef d ON d.adrelid = t.oid AND d.adnum = a.attnum
            UNION ALL
            SELECT format('constraint %s.%s %s valid=%s', t.relname, k.conname, pg_get_constraintdef(k.oid), k.convalidated)
            FROM t JOIN pg_constraint k ON k.conrelid = t.oid
            -- Copies inherited from the unpublished q_parted only exist on the publisher, by design.
            WHERE NOT (t.relname = 'public.q_part1' AND NOT k.conislocal)
            UNION ALL
            SELECT format('index %s.%s', t.relname, pg_get_indexdef(i.indexrelid))
            FROM t JOIN pg_index i ON i.indrelid = t.oid
        ) lines
    };
}

sub rows_sql
{
    my ($tables) = @_;
    return join(' UNION ALL ',
        map { "SELECT '$_' || ':' || coalesce((SELECT md5(string_agg(r::text, '|' ORDER BY r::text)) FROM $_ r), '-')" }
          @$tables);
}

# Only rows of published tables travel: a detached partition's later rows legitimately differ.
sub published_tables
{
    my ($pub) = @_;
    return [ split /\n/, $pub->safe_psql('postgres', q{
        SELECT quote_ident(schemaname) || '.' || quote_ident(tablename) FROM pg_publication_tables
        WHERE pubname = 'pub1' AND schemaname IN ('public', 's2') AND tablename <> 'beat'
        UNION SELECT 'public.parted' WHERE to_regclass('public.parted') IS NOT NULL ORDER BY 1}) ];
}

sub query_list
{
    my ($node, $sql) = @_;
    my $out = $node->safe_psql('postgres', $sql);
    return grep { length } split /\n/, $out;
}

sub next_statement
{
    my ($pub, $n) = @_;
    my @tables = query_list($pub, q{
        SELECT quote_ident(n.nspname) || '.' || quote_ident(c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('public', 's2') AND c.relkind = 'r' AND NOT c.relispartition AND c.relname <> 'beat'});
    my $pg18 = $pub->safe_psql('postgres', q{SELECT current_setting('server_version_num')::int >= 180000}) eq 't';
    my $t = pick(@tables);
    my @cols = query_list($pub, qq{
        SELECT a.attname || '|' || format_type(a.atttypid, a.atttypmod) || '|' || a.attnotnull
        FROM pg_attribute a WHERE a.attrelid = '$t'::regclass AND a.attnum > 1 AND NOT a.attisdropped});
    my @cons = query_list($pub, qq{
        SELECT conname || '|' || contype::text || '|' || convalidated FROM pg_constraint
        WHERE conrelid = '$t'::regclass AND (contype <> 'n' OR } . ($pg18 ? 'true' : 'false') . q{)});
    my @idx = query_list($pub, qq{
        SELECT x.relname || '|' || i.indisunique FROM pg_index i JOIN pg_class x ON x.oid = i.indexrelid
        WHERE i.indrelid = '$t'::regclass
          AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.indexrelid)});
    my ($col, $ctype, $cnn) = @cols ? split(/\|/, pick(@cols)) : (undef, undef, undef);
    my ($con, $contype, $convalid) = @cons ? split(/\|/, pick(@cons)) : (undef, undef, undef);
    my ($ix, $ixunique) = @idx ? split(/\|/, pick(@idx)) : (undef, undef);
    my $other = pick(@tables);

    my @ops = (
        sub { my $ty = pick(@types); my $d = rand() < 0.5 ? ' DEFAULT ' . literal_for($ty) : '';
              my $nn = ($d && rand() < 0.4) ? ' NOT NULL' : '';
              qq{ALTER TABLE $t ADD COLUMN c$n $ty$d$nn} },
        sub { $col && qq{ALTER TABLE $t DROP COLUMN "$col"} },
        sub { $col && qq{ALTER TABLE $t RENAME COLUMN "$col" TO r$n} },
        sub { $col && qq{ALTER TABLE $t ALTER COLUMN "$col" TYPE text USING "$col"::text} },
        sub { $col && $ctype =~ /^(integer|text|character varying)/
                  && qq{ALTER TABLE $t ALTER COLUMN "$col" TYPE bigint USING length("$col"::text)} },
        sub { $col && qq{ALTER TABLE $t ALTER COLUMN "$col" SET DEFAULT } . literal_for($ctype) },
        sub { $col && qq{ALTER TABLE $t ALTER COLUMN "$col" DROP DEFAULT} },
        sub { $col && qq{ALTER TABLE $t ALTER COLUMN "$col" SET NOT NULL} },
        sub { $col && qq{ALTER TABLE $t ALTER COLUMN "$col" DROP NOT NULL} },
        sub { $col && qq{ALTER TABLE $t ADD CONSTRAINT k$n CHECK ("$col" IS DISTINCT FROM NULL OR true)}
                  . (rand() < 0.4 ? ' NOT VALID' : '') },
        sub { $col && qq{ALTER TABLE $t ADD CONSTRAINT u$n UNIQUE ("$col")} },
        sub { $col && qq{ALTER TABLE $other ADD CONSTRAINT f$n FOREIGN KEY (id) REFERENCES $t (id)}
                  . (rand() < 0.3 ? ' NOT VALID' : '') },
        sub { $con && qq{ALTER TABLE $t DROP CONSTRAINT "$con"} . (rand() < 0.3 ? ' CASCADE' : '') },
        sub { $con && qq{ALTER TABLE $t RENAME CONSTRAINT "$con" TO rk$n} },
        sub { $con && $convalid eq 'f' && qq{ALTER TABLE $t VALIDATE CONSTRAINT "$con"} },
        sub { $con && $contype eq 'f' && qq{ALTER TABLE $t ALTER CONSTRAINT "$con" DEFERRABLE INITIALLY DEFERRED} },
        sub { $col && qq{CREATE } . (rand() < 0.4 ? 'UNIQUE ' : '') . qq{INDEX i$n ON $t ("$col")} },
        sub { $ix && qq{DROP INDEX "$ix"} },
        sub { $ix && qq{ALTER INDEX "$ix" RENAME TO ri$n} },
        sub { $ix && $ixunique eq 't' && qq{ALTER TABLE $t ADD CONSTRAINT ui$n UNIQUE USING INDEX "$ix"} },
        sub { qq{ALTER TABLE $t RENAME TO t$n} },
        sub { qq{ALTER TABLE q_parted ADD CONSTRAINT qc$n CHECK (a > -1)} },
        sub { my @qc = query_list($pub, q{SELECT conname FROM pg_constraint WHERE conrelid = 'q_parted'::regclass AND contype = 'c'});
              @qc && qq{ALTER TABLE q_parted DROP CONSTRAINT "} . pick(@qc) . '"' },
        sub { $pg18 && $col && qq{ALTER TABLE $t ADD CONSTRAINT nn$n NOT NULL "$col"} . (rand() < 0.5 ? ' NOT VALID' : '') },
        sub { $pg18 && $con && $contype eq 'f' && qq{ALTER TABLE $t ALTER CONSTRAINT "$con" } . pick('ENFORCED', 'NOT ENFORCED') },
        sub { $pg18 && $con && $contype eq 'n' && qq{ALTER TABLE $t ALTER CONSTRAINT "$con" } . pick('INHERIT', 'NO INHERIT') },
        sub { my $ty = pick(@types);
              qq{ALTER TABLE $t ADD COLUMN m$n $ty DEFAULT } . literal_for($ty) . qq{, ADD CONSTRAINT mk$n CHECK (m$n IS NOT NULL)} },
        sub { $col && qq{BEGIN; ALTER TABLE $t ALTER COLUMN "$col" SET NOT NULL; ALTER TABLE $t ALTER COLUMN "$col" DROP NOT NULL; }
                  . qq{ALTER TABLE $t ALTER COLUMN "$col" SET NOT NULL; COMMIT;} },
        sub { qq{ALTER TABLE ONLY parted ADD CONSTRAINT pu$n UNIQUE (id, a)} },
        sub { qq{ALTER TABLE parted ADD CONSTRAINT pc$n CHECK (a > -1)} },
        sub { my @pc = query_list($pub, q{SELECT conname FROM pg_constraint WHERE conrelid = 'parted'::regclass AND contype = 'c'});
              @pc && qq{ALTER TABLE parted DROP CONSTRAINT "} . pick(@pc) . '"' },
        sub { qq{ALTER TABLE parted DETACH PARTITION parted_2} },
        sub { qq{ALTER TABLE parted ATTACH PARTITION parted_2 FOR VALUES FROM (100) TO (200)} },
    );
    for (1 .. 10)
    {
        my $sql = pick(@ops)->();
        return $sql if $sql;
    }
    return qq{ALTER TABLE $t ADD COLUMN c$n int};
}

sub insert_rows
{
    my ($pub, $n) = @_;
    for my $t (@{ published_tables($pub) })
    {
        my @cols = query_list($pub, qq{
            SELECT a.attname || '|' || format_type(a.atttypid, a.atttypmod) FROM pg_attribute a
            WHERE a.attrelid = '$t'::regclass AND a.attnum > 1 AND NOT a.attisdropped AND a.attgenerated = ''});
        my @names = ('id');
        my @values = ($t eq 'public.parted' ? int(rand(200)) : $t eq 'public.q_part1' ? int(rand(100)) : 1000 * $n + int(rand(1000)));
        for my $c (@cols)
        {
            my ($name, $type) = split /\|/, $c;
            next if rand() < 0.3;
            push @names, qq{"$name"};
            push @values, literal_for($type);
        }
        $pub->psql('postgres', qq{INSERT INTO $t (} . join(', ', @names) . ') VALUES (' . join(', ', @values) . ')');
    }
}

my @operations = (
    ['table', 'rename_table'], ['table', 'drop_table'], ['table', 'attach_partition'], ['table', 'detach_partition'],
    ['column', 'add_column'], ['column', 'drop_column'], ['column', 'rename_column'],
    ['column', 'alter_column_type'], ['column', 'alter_column_default'],
    ['column', 'set_not_null'], ['column', 'drop_not_null'],
    ['index', 'create_index'], ['index', 'drop_index'], ['index', 'rename_index'],
    ['constraint', 'add_constraint'], ['constraint', 'drop_constraint'], ['constraint', 'rename_constraint'],
    ['constraint', 'validate_constraint'], ['constraint', 'alter_constraint']);
my $values = join(', ', map { "('$_->[0]', '$_->[1]')" } @operations);

for my $seed (@seeds)
{
    srand($seed);
    my $pub = PostgreSQL::Test::Cluster->new("pub_$seed");
    $pub->init(allows_streaming => 'logical');
    $pub->start;
    my $sub = PostgreSQL::Test::Cluster->new("sub_$seed");
    $sub->init;
    $sub->start;

    for my $node ($pub, $sub)
    {
        $node->safe_psql('postgres', q{
            CREATE EXTENSION pg_ddl_repl;
            CREATE TYPE mood AS ENUM ('ok', 'ko');
            CREATE TABLE beat (id serial PRIMARY KEY);
            CREATE TABLE a (id int PRIMARY KEY, x int, y text);
            CREATE TABLE b (id int PRIMARY KEY, x int, y text);
            CREATE TABLE c (id int PRIMARY KEY, x int, y text);
            CREATE TABLE parted (id int, a int) PARTITION BY RANGE (id);
            CREATE TABLE parted_1 PARTITION OF parted FOR VALUES FROM (0) TO (100);
            CREATE TABLE parted_2 PARTITION OF parted FOR VALUES FROM (100) TO (200);
            CREATE SCHEMA s2;
            CREATE TABLE s2.d (id int PRIMARY KEY, x int, y text);
            CREATE TABLE q_parted (id int, a int) PARTITION BY RANGE (id);
            CREATE TABLE q_part1 PARTITION OF q_parted FOR VALUES FROM (0) TO (100);
        });
    }
    # The CHECK constraint on object_family/operation rejects unknown operations: insert one by one.
    for my $op (@operations)
    {
        $pub->psql('postgres', qq{INSERT INTO ddl_repl.publish_rules (object_family, operation) VALUES ('$op->[0]', '$op->[1]')});
    }
    # q_parted is the unpublished parent of a published partition: per-table rules win over the wildcard ones.
    for my $op (grep { $_->[0] eq 'constraint' } @operations)
    {
        $pub->psql('postgres', qq{INSERT INTO ddl_repl.publish_rules (relid, object_family, operation, enabled)
                                  VALUES ('q_parted'::regclass, '$op->[0]', '$op->[1]', false)});
    }
    $pub->safe_psql('postgres', q{
        CREATE PUBLICATION pub1 FOR TABLE beat, a, b, c, parted, s2.d, q_part1 WITH (publish_via_partition_root = true);
        SELECT ddl_repl.enable_for_publication('pub1');
        INSERT INTO a VALUES (1, 1, 'a'), (2, 2, 'b');
        INSERT INTO b VALUES (1, 1, 'a'), (2, 2, 'b');
        INSERT INTO c VALUES (1, 1, 'a'), (2, 2, 'b');
        INSERT INTO s2.d VALUES (1, 1, 'a');
        INSERT INTO parted VALUES (1, 1), (150, 2);
        INSERT INTO q_part1 VALUES (1, 1);
    });
    my $source = $pub->safe_psql('postgres', q{SELECT ddl_repl.source_name()});
    for my $op (@operations)
    {
        $sub->psql('postgres', qq{
            INSERT INTO ddl_repl.subscribe_rules (source_name, object_family, operation, allow_raw_fallback)
            VALUES ('$source', '$op->[0]', '$op->[1]', true)});
    }
    my $connstr = $pub->connstr . ' dbname=postgres';
    $sub->safe_psql('postgres', "CREATE SUBSCRIPTION s CONNECTION '$connstr' PUBLICATION pub1");
    $sub->wait_for_subscription_sync($pub, 's');

    my @log;
    my $ok = 1;
    for my $n (1 .. $steps)
    {
        my $sql = next_statement($pub, $n);
        my ($ret, $out, $err) = $pub->psql('postgres', $sql);
        push @log, ($ret == 0 ? 'ran    ' : 'failed ') . $sql;
        # A publisher-side failure is fine, unless the extension itself caused it.
        if ($ret != 0 && $err =~ /ddl_repl|command_queue/)
        {
            $ok = 0;
            diag("seed $seed: the extension made a publisher DDL fail at step $n\nstatements:\n"
                 . join("\n", map { "  $_" } @log) . "\nerror: $err");
            last;
        }
        insert_rows($pub, $n);
        next if $n % $batch && $n != $steps;

        $pub->safe_psql('postgres', 'INSERT INTO beat DEFAULT VALUES');
        my $target = $pub->safe_psql('postgres', 'SELECT pg_current_wal_lsn()');
        my $deadline = time() + 20;
        my $caught = 0;
        while (time() < $deadline)
        {
            if ($pub->safe_psql('postgres', qq{
                    SELECT coalesce(bool_and(confirmed_flush_lsn >= '$target'), false) FROM pg_replication_slots
                    WHERE slot_name = 's'}) eq 't')
            {
                $caught = 1;
                last;
            }
            usleep(200_000);
        }
        my $fp_pub = $pub->safe_psql('postgres', fingerprint_sql()) . "\n"
          . $pub->safe_psql('postgres', rows_sql(published_tables($pub)));
        my $fp_sub = $sub->safe_psql('postgres', fingerprint_sql()) . "\n"
          . (eval { $sub->safe_psql('postgres', rows_sql(published_tables($pub))) } // 'rows: tables differ');
        next if $caught && $fp_pub eq $fp_sub;

        $ok = 0;
        my %p = map { $_ => 1 } split /\n/, $fp_pub;
        my %s = map { $_ => 1 } split /\n/, $fp_sub;
        my @diff = ((map { "  publisher only: $_" } grep { !$s{$_} } sort keys %p),
                    (map { "  subscriber only: $_" } grep { !$p{$_} } sort keys %s));
        my ($last_error) = reverse grep { /ERROR/ } split /\n/, slurp_file($sub->logfile);
        diag("seed $seed diverged after step $n" . ($caught ? '' : ' (apply did not catch up)') . "\n"
             . "statements:\n" . join("\n", map { "  $_" } @log) . "\n"
             . "difference:\n" . join("\n", @diff) . "\n"
             . 'last subscriber error: ' . ($last_error // '-'));
        last;
    }
    ok($ok, "seed $seed: $steps random DDL steps replicated identically");
    $sub->stop('immediate');
    $pub->stop('immediate');
}

done_testing();
