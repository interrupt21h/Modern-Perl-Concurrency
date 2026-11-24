#!/usr/bin/env perl
# Lease-based work queue: SKIP LOCKED claim, owner + attempt fencing,
# heartbeat, conditional completion and an idempotent effect in one commit.
# Run several copies concurrently; each exits when nothing is claimable.
use strict;
use warnings;
use DBI;
use JSON::PP      qw(encode_json decode_json);
use Sys::Hostname qw(hostname);
use Time::HiRes   qw(sleep);

my $LEASE_SECONDS = 30;
my $dbh           = DBI->connect(
    $ENV{DB_DSN},
    $ENV{DB_USER},
    $ENV{DB_PASS},
    {
        RaiseError           => 1,
        PrintError           => 0,
        AutoCommit           => 1,
        mysql_auto_reconnect => 0,
    }
);
$dbh->do('SET SESSION innodb_lock_wait_timeout = 5');

# Owner identity is diagnostic; the attempt number is the fencing token.
my $owner =
    substr( sprintf( '%s:%d:%04x', hostname(), $$, rand 0xffff ), 0, 64 );

# Run $code in a transaction; retry deadlock and lock-wait victims only.
sub with_txn {
    my ($code) = @_;
    for my $attempt ( 1 .. 5 ) {
        my @result;
        my $ok =
            eval { $dbh->begin_work; @result = $code->(); $dbh->commit; 1 };
        return wantarray ? @result : $result[0] if $ok;
        my ( $err, $errno ) = ( $@, $dbh->err // 0 );
        eval { $dbh->rollback unless $dbh->{AutoCommit}; 1 }
            or die "rollback failed; discard connection: $err";
        die $err
            unless ( $errno == 1213 || $errno == 1205 ) && $attempt < 5;
        sleep( 0.01 * 2**$attempt + rand 0.02 );
    }
}

sub claim {
    while (1) {
        my $job = with_txn(
            sub {
                my $row = $dbh->selectrow_hashref(
                    q{
                SELECT id, payload, attempt, max_attempts FROM job
                WHERE state = 'pending' AND visible_at <= UTC_TIMESTAMP(6)
                ORDER BY visible_at, id LIMIT 1
                FOR UPDATE SKIP LOCKED}
                );
                return undef unless $row;
                if ( $row->{attempt} >= $row->{max_attempts} ) {
                    $dbh->do(
                        q{UPDATE job SET state = 'dead', owner = NULL
                    WHERE id = ?}, undef, $row->{id}
                    );
                    return { dead => 1 };
                }
                $dbh->do(
                    q{UPDATE job SET owner = ?, attempt = attempt + 1,
                visible_at = UTC_TIMESTAMP(6) + INTERVAL ? SECOND
                WHERE id = ?}, undef, $owner, $LEASE_SECONDS, $row->{id}
                );
                $row->{attempt}++;
                return $row;
            }
        );
        return $job unless $job && $job->{dead};    # dead-lettered: look again
    }
}

# Heartbeat: extend only if this worker still holds this exact attempt.
sub extend {
    my ($job) = @_;
    my $n = $dbh->do(
        q{UPDATE job
        SET visible_at = UTC_TIMESTAMP(6) + INTERVAL ? SECOND
        WHERE id = ? AND state = 'pending' AND owner = ? AND attempt = ?},
        undef, $LEASE_SECONDS, $job->{id}, $owner, $job->{attempt}
    );
    return $n == 1;
}

# Completion and effect commit together, or not at all.
sub complete {
    my ( $job, $result ) = @_;
    return with_txn(
        sub {
            my $n = $dbh->do(
                q{UPDATE job SET state = 'done', owner = NULL
            WHERE id = ? AND state = 'pending' AND owner = ? AND attempt = ?},
                undef, $job->{id}, $owner, $job->{attempt}
            );
            return 0 unless $n == 1;    # lease lost: no effect
            $dbh->do(
'INSERT INTO job_effect (job_id, attempt, result) VALUES (?, ?, ?)',
                undef, $job->{id}, $job->{attempt}, encode_json($result)
            );
            return 1;
        }
    );
}

# Release for retry with backoff; also conditional on the attempt.
sub fail {
    my ( $job, $error ) = @_;
    $dbh->do(
        q{UPDATE job SET owner = NULL, last_error = ?,
        visible_at = UTC_TIMESTAMP(6) + INTERVAL ? SECOND
        WHERE id = ? AND state = 'pending' AND owner = ? AND attempt = ?},
        undef,      substr( $error, 0, 255 ), 2**$job->{attempt},
        $job->{id}, $owner,                   $job->{attempt}
    );
}

my ( $completed, $lost ) = ( 0, 0 );
while ( my $job = claim() ) {
    my $result = eval {
        my $n = decode_json( $job->{payload} )->{n};
        extend($job) or die "lease lost before work\n";    # heartbeat demo
        { n => $n, square => $n * $n };
    };
    if ( !$result ) { fail( $job, $@ ); next }
    complete( $job, $result ) ? ++$completed : ++$lost;
}
$dbh->disconnect;
print "worker $$ completed=$completed lost=$lost\n";
