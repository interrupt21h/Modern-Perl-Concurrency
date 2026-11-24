#!/usr/bin/env perl
# Redis Streams consumer group: at-least-once delivery, XACK after an
# idempotent effect, and XAUTOCLAIM recovery of entries left pending by a
# consumer that dies. Requires Redis 6.2+ or Valkey 7.2+.
use strict;
use warnings;
use Redis;
use POSIX qw(_exit);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

$| = 1;                      # children leave via _exit: flush eagerly
my $SERVER   = $ENV{REDIS_SERVER} // '127.0.0.1:6379';
my $STREAM   = 'jobs:{demo}';
my $RESULTS  = 'results:{demo}';
my $STOP     = 'stop:{demo}';
my $GROUP    = 'workers';
my $JOBS     = 200;
my $WORKERS  = 4;
my $IDLE_MS  = 500;          # pending longer than this is presumed abandoned

sub now { clock_gettime(CLOCK_MONOTONIC) }
sub connect_redis {
    Redis->new(server => $SERVER, cnx_timeout => 1, read_timeout => 5,
        write_timeout => 1, reconnect => 0);
}

# Idempotent effect: the first writer for an id wins; replays are no-ops.
sub handle {
    my ($r, $consumer, $id, $fields) = @_;
    my %f = @$fields;
    $r->hsetnx($RESULTS, $f{job}, "$consumer:" . $f{n} ** 2);
    $r->xack($STREAM, $GROUP, $id);
}

sub consume {
    my ($consumer, $crash) = @_;
    my $r = connect_redis();
    my $next_claim = now();
    my ($handled, $claimed) = (0, 0);
    until ($r->exists($STOP)) {
        # Periodically adopt entries other consumers left pending too long.
        if (now() >= $next_claim) {
            my $reply = $r->xautoclaim($STREAM, $GROUP, $consumer,
                $IDLE_MS, '0-0', 'COUNT', 50);
            for my $entry (@{ $reply->[1] }) {
                next unless $entry && ref $entry->[1];   # trimmed entries
                handle($r, $consumer, @$entry);
                ++$claimed;
            }
            $next_claim = now() + $IDLE_MS / 1000;
        }
        my $reply = $r->xreadgroup('GROUP', $GROUP, $consumer, 'COUNT', 10,
            'BLOCK', 200, 'STREAMS', $STREAM, '>') or next;
        for my $entry (@{ $reply->[0][1] }) {
            _exit(0) if $crash;            # die holding unacknowledged work
            handle($r, $consumer, @$entry);
            ++$handled;
        }
    }
    print "$consumer handled=$handled reclaimed=$claimed\n";
}

my $r = connect_redis();
$r->del($STREAM, $RESULTS, $STOP);
$r->xgroup('CREATE', $STREAM, $GROUP, '$', 'MKSTREAM');
$r->xadd($STREAM, '*', job => $_, n => $_) for 1 .. $JOBS;

my @pids;
for my $i (1 .. $WORKERS) {
    defined(my $pid = fork()) or die "fork: $!";
    if (!$pid) {
        my $ok = eval { consume("c$i", $i == 1); 1 };   # c1 crashes
        warn $@ unless $ok;
        _exit($ok ? 0 : 1);
    }
    push @pids, $pid;
}

# Supervisor: finished when every job has an effect and nothing is pending.
my $deadline = now() + 30;
while (1) {
    my $pending = $r->xpending($STREAM, $GROUP)->[0];
    last if $r->hlen($RESULTS) == $JOBS && $pending == 0;
    die "timeout: pending=$pending\n" if now() > $deadline;
    sleep(0.1);
}
$r->set($STOP, 1, 'EX', 60);
for (@pids) { waitpid($_, 0); die "consumer failed\n" if $? }

my %by = map { (split /:/)[0] => 1 } $r->hvals($RESULTS);
printf "%d jobs, each effect applied once, consumers: %s\n",
    $r->hlen($RESULTS), join(',', sort keys %by);
$r->del($STREAM, $RESULTS, $STOP);
