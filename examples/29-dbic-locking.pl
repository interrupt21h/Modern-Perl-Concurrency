#!/usr/bin/env perl
# DBIx::Class: pessimistic and optimistic locking, SKIP LOCKED claims and an
# explicit deadlock-retry policy. Forks competing workers and verifies:
#   1. transfers under txn_scope_guard + FOR UPDATE conserve the total;
#   2. optimistic version checks lose no edits and hold no locks while thinking;
#   3. SKIP LOCKED claims never hand the same job to two workers.
# Requires DBIx::Class, DBD::mysql and the laboratory schema (schema.sql).
use strict;
use warnings;

# ---------------------------------------------------------------- schema
package Lab::Schema::Result::Account {
    use base 'DBIx::Class::Core';
    __PACKAGE__->table('account');
    __PACKAGE__->add_columns(qw(id cents));
    __PACKAGE__->set_primary_key('id');
}

package Lab::Schema::Result::Document {
    use base 'DBIx::Class::Core';
    __PACKAGE__->table('document');
    __PACKAGE__->add_columns(qw(id body version));
    __PACKAGE__->set_primary_key('id');
}

package Lab::Schema::Result::Job {
    use base 'DBIx::Class::Core';
    __PACKAGE__->table('job');
    __PACKAGE__->add_columns(
        qw(id payload state visible_at owner attempt max_attempts last_error)
    );
    __PACKAGE__->set_primary_key('id');
}

# DBIx::Class's MySQL SQL maker accepts only for => 'update' and 'shared'
# ('shared' emits the legacy LOCK IN SHARE MODE). This subclass also accepts
# a literal clause, e.g. for => \'UPDATE SKIP LOCKED' or \'SHARE NOWAIT'.
package Lab::SQLMaker {
    use base 'DBIx::Class::SQLMaker::MySQL';

    sub _lock_select {
        my ( $self, $type ) = @_;
        return " FOR $$type" if ref $type eq 'SCALAR';
        return $self->SUPER::_lock_select($type);
    }
}

package Lab::Schema {
    use base 'DBIx::Class::Schema';
    __PACKAGE__->register_class(
        Account => 'Lab::Schema::Result::Account' );
    __PACKAGE__->register_class(
        Document => 'Lab::Schema::Result::Document' );
    __PACKAGE__->register_class( Job => 'Lab::Schema::Result::Job' );
}

package main;
use File::Temp  qw(tempdir);
use POSIX       qw(_exit);
use Time::HiRes qw(sleep);

$| = 1;

# Connect inside each process. DBIx::Class also reconnects by itself when it
# notices a new PID, but explicit per-process connections make that obvious.
sub connect_schema {
    my $schema = Lab::Schema->connect(
        $ENV{DB_DSN},
        $ENV{DB_USER},
        $ENV{DB_PASS},
        {
            RaiseError           => 1,
            PrintError           => 0,
            AutoCommit           => 1,
            mysql_auto_reconnect => 0,
            on_connect_do => ['SET SESSION innodb_lock_wait_timeout = 5'],
        }
    );
    $schema->storage->ensure_connected;    # determines the driver
    $schema->storage->sql_maker_class('Lab::SQLMaker');
    return $schema;
}

# txn_do retries only when the connection was lost, never on deadlock, so
# the application owns this policy. Retry only the two transient errors.
sub with_deadlock_retry {
    my ( $schema, $code, $max ) = ( @_, 5 );
    for my $attempt ( 1 .. $max ) {
        my @result;
        my $ok = eval { @result = $schema->txn_do($code); 1 };
        return wantarray ? @result : $result[0] if $ok;
        my $err = $@;
        die $err
            unless "$err" =~ /Deadlock found|Lock wait timeout exceeded/
            && $attempt < $max;
        sleep( 0.01 * 2**$attempt + rand 0.02 );    # backoff with jitter
    }
}

# ---------------------------------------------------------------- 1. pessimistic
sub transfer {
    my ( $schema, $from, $to, $cents ) = @_;
    with_deadlock_retry(
        $schema,
        sub {
            my $accounts = $schema->resultset('Account');

          # SELECT ... ORDER BY id FOR UPDATE: both rows, global lock order.
            my @locked = $accounts->search( { id => [ $from, $to ] },
                { order_by => 'id', for => 'update' } )->all;
            die "missing account\n" unless @locked == 2;

            # Guarded UPDATE: the balance rule lives in the WHERE clause.
            my $n = $accounts->search(
                { id => $from, cents => { '>=' => $cents } } )
                ->update( { cents => \[ 'cents - ?', $cents ] } );
            return 0 unless $n == 1;    # insufficient funds
            $accounts->search( { id => $to } )
                ->update( { cents => \[ 'cents + ?', $cents ] } );
            return 1;
        }
    );
}

# ---------------------------------------------------------------- 2. optimistic
# Read without locking, "think", then write only if nobody changed the row in
# between. A conflict costs a re-read, never a blocked connection.
sub append_line {
    my ( $schema, $line ) = @_;
    my $docs = $schema->resultset('Document');
    for my $try ( 1 .. 50 ) {
        my $doc = $docs->find(1);
        my ( $body, $seen ) = ( $doc->body, $doc->version );
        sleep( rand 0.005 );    # user think time
        my $n = $docs->search( { id => 1, version => $seen } )->update(
            {
                body    => $body . "$line\n",
                version => $seen + 1,
            }
        );
        return $try if $n == 1;    # attempts needed
    }
    die "gave up after 50 conflicts\n";
}

# ---------------------------------------------------------------- 3. SKIP LOCKED
sub claim_job {
    my ( $schema, $owner ) = @_;
    return with_deadlock_retry(
        $schema,
        sub {
            my $job = $schema->resultset('Job')->search(
                {
                    state      => 'pending',
                    visible_at => { '<=' => \'UTC_TIMESTAMP(6)' }
                },
                {
                    order_by => [qw(visible_at id)],
                    rows     => 1,
                    for      => \'UPDATE SKIP LOCKED'
                },    # via Lab::SQLMaker
            )->single or return;
            $job->update(
                {
                    owner      => $owner,
                    attempt    => $job->attempt + 1,
                    visible_at => \'UTC_TIMESTAMP(6) + INTERVAL 30 SECOND'
                }
            );
            return $job->id;
        }
    );
}

# ---------------------------------------------------------------- driver
sub in_workers {
    my ( $n, $code ) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    my @pids;
    for my $i ( 1 .. $n ) {
        defined( my $pid = fork() ) or die "fork: $!";
        if ( !$pid ) {
            my $out = eval { $code->( connect_schema(), $i ) };
            if ( !defined $out ) { warn $@ if $@; _exit(1) }
            open my $fh, '>', "$dir/$i" or _exit(1);
            print {$fh} $out;
            close $fh;
            _exit(0);
        }
        push @pids, $pid;
    }
    my @failed;
    for my $pid (@pids) {
        my $reaped;
        do { $reaped = waitpid( $pid, 0 ) }
            while $reaped == -1 && $!{EINTR};
        push @failed, $pid if $reaped != $pid || $?;
    }
    die "workers failed: @failed\n" if @failed;
    return
        map { open my $fh, '<', "$dir/$_" or die; local $/; scalar <$fh> }
        1 .. $n;
}

my $schema = connect_schema();
my $total  = $schema->resultset('Account')->get_column('cents')->sum;
$schema->resultset('Document')->search( { id => 1 } )->update(
    {
        body    => '',
        version => 0
    }
);

# 1. Four workers, 50 transfers each, alternating direction (deadlock bait).
in_workers(
    4,
    sub {
        my ($s) = @_;
        my $done = 0;
        for my $i ( 1 .. 50 ) {
            my ( $from, $to ) = $i % 2 ? ( 1, 2 ) : ( 2, 1 );
            $done += transfer( $s, $from, $to, 1 + int rand 100 );
        }
        return $done;
    }
);
my $after = $schema->resultset('Account')->get_column('cents')->sum;
die "money created or destroyed: $total -> $after\n"
    unless $after == $total;
print "pessimistic: 200 transfers, total preserved ($after)\n";

# 2. Four writers append 20 lines each to one document.
my @tries = in_workers(
    4,
    sub {
        my ( $s, $w ) = @_;
        my $retries = 0;
        $retries += append_line( $s, "w$w-$_" ) - 1 for 1 .. 20;
        return $retries;
    }
);
my $doc   = $schema->resultset('Document')->find(1);
my @lines = split /\n/, $doc->body;
die "lost edits: " . scalar(@lines) . " of 80\n"
    unless @lines == 80
    && $doc->version == 80;
my %uniq = map { $_ => 1 } @lines;
die "duplicate edits\n" unless keys %uniq == 80;
my $conflicts = 0;
$conflicts += $_ for @tries;
print
"optimistic: 80 of 80 edits kept, version 80, $conflicts conflicts retried\n";

# 3. Seed 20 fresh jobs, then let two workers drain the queue with SKIP LOCKED.
$schema->resultset('Job')
    ->populate( [ map { { payload => qq({"n":$_}) } } 1 .. 20 ] );
my $pending = $schema->resultset('Job')->search(
    {
        state      => 'pending',
        visible_at => { '<=' => \'UTC_TIMESTAMP(6)' }
    }
)->count;
die "no claimable jobs to test with\n" unless $pending >= 20;
my @claimed = in_workers(
    2,
    sub {
        my ( $s, $w ) = @_;
        my @ids;
        while ( defined( my $id = claim_job( $s, "dbic-worker-$w" ) ) ) {
            push @ids, $id
        }
        return join ',', @ids;
    }
);
my @all = map { split /,/ } @claimed;
my %seen;
die "job claimed twice\n" if grep { $seen{$_}++ } @all;
die "jobs missed\n" unless @all == $pending;
printf "skip locked: %d jobs claimed by 2 workers (%s), none twice\n",
    scalar @all, join( ' + ', map { scalar( () = /\d+/g ) } @claimed );
