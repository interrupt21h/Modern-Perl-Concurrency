#!/usr/bin/env perl
# Transfer with deterministic lock ordering, guarded UPDATE and bounded retry.
# Usage: perl 11-mysql-transfer.pl [iterations]   (default 1)
use strict;
use warnings;
use DBI;
use Time::HiRes qw(sleep);

my %RETRYABLE = (1213 => 'deadlock', 1205 => 'lock wait timeout');
my $MAX_ATTEMPTS = 5;

my $dbh = DBI->connect($ENV{DB_DSN}, $ENV{DB_USER}, $ENV{DB_PASS}, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1,
    mysql_auto_reconnect => 0,           # a reconnect silently loses txn state
});
# Fail fast instead of the 50 s server default; the caller owns retry policy.
$dbh->do('SET SESSION innodb_lock_wait_timeout = 5');

sub transfer {
    my ($from, $to, $cents) = @_;
    die "invalid transfer\n" unless $from != $to && $cents > 0;
    for my $attempt (1 .. $MAX_ATTEMPTS) {
        my $ok = eval {
            $dbh->begin_work;
            # Lock both rows in a global order (ascending primary key).
            for my $id (sort { $a <=> $b } $from, $to) {
                my ($exists) = $dbh->selectrow_array(
                    'SELECT id FROM account WHERE id = ? FOR UPDATE',
                    undef, $id);
                die "missing account $id\n" unless defined $exists;
            }
            # The constraint lives in the write itself, not in a prior read.
            my $n = $dbh->do(
                'UPDATE account SET cents = cents - ? WHERE id = ? AND cents >= ?',
                undef, $cents, $from, $cents);
            die "insufficient funds\n" unless $n == 1;
            $dbh->do('UPDATE account SET cents = cents + ? WHERE id = ?',
                undef, $cents, $to);
            $dbh->commit;
            1;
        };
        return 1 if $ok;
        # Capture diagnostics before any further DBI call can replace them.
        my ($err, $errno) = ($@, $dbh->err // 0);
        my $rolled = eval { $dbh->rollback unless $dbh->{AutoCommit}; 1 };
        die "rollback failed; discard connection. Original error: $err"
            unless $rolled;
        die $err unless $RETRYABLE{$errno} && $attempt < $MAX_ATTEMPTS;
        # Exponential backoff with jitter.
        sleep(0.02 * 2 ** ($attempt - 1) + rand(0.03));
    }
    return;
}

my $iterations = shift // 1;
my ($done, $declined) = (0, 0);
for my $i (1 .. $iterations) {
    my ($from, $to) = $i % 2 ? (1, 2) : (2, 1);   # opposing directions
    my $ok = eval { transfer($from, $to, 1 + int rand 200) };
    if ($ok) { ++$done; next }
    die $@ unless $@ eq "insufficient funds\n";
    ++$declined;
}
$dbh->disconnect;
print "transfers=$done declined=$declined\n";
