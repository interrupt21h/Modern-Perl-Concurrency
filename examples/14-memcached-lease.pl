#!/usr/bin/env perl
# Best-effort Memcached lease for cache-refresh coalescing: add-if-absent,
# owner-checked CAS tombstone release. Distinguishes contention from backend
# failure. Never use this as the sole guard for correctness-critical work.
use strict;
use warnings;
use Cache::Memcached::Fast;
use File::Temp qw(tempfile);
use POSIX qw(_exit);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

my $SERVER  = $ENV{MEMCACHED_SERVER} // '127.0.0.1:11211';
my $KEY     = 'lease:demo:refresh';
my $TTL     = 10;            # seconds; Memcached expiry has 1 s granularity
my $WORKERS = 4;

sub now { clock_gettime(CLOCK_MONOTONIC) }
sub token {
    open my $fh, '<:raw', '/dev/urandom' or die "urandom: $!";
    read($fh, my $bytes, 16) == 16 or die "short random read\n";
    return unpack 'H*', $bytes;
}

sub worker {
    my ($trace_fh) = @_;
    my $m = Cache::Memcached::Fast->new({
        servers => [$SERVER],        # one fixed server: no rehashing
        connect_timeout => 1, io_timeout => 1, max_failures => 0,
    });
    my $owner = token();
    my ($valid_until, $errors);
    my $stop = now() + 10;
    while (now() < $stop) {
        my $start = now();
        my $added = $m->add($KEY, $owner, $TTL);
        if ($added) {
            # 1 s expiry granularity plus skew: keep a generous margin.
            $valid_until = $start + $TTL - 2;
            last;
        }
        ++$errors unless defined $added;     # undef = backend error
        die "memcached unavailable\n" if ($errors // 0) >= 5;
        sleep(0.025 + rand 0.075);
    }
    die "lease unavailable\n" unless defined $valid_until;

    my $entered = now();
    my $ok = eval {
        die "lease budget exhausted\n" if now() >= $valid_until;
        sleep(0.1);                          # bounded cache refresh
        1;
    };
    my $err  = $@;
    my $left = now();
    syswrite $trace_fh, sprintf("%.6f %.6f\n", $entered, $left);

    # Classic protocol has no conditional delete: CAS-replace our own entry
    # with a short tombstone. A changed CAS means someone else owns it now.
    my $entry = $m->gets($KEY);
    if ($entry && $entry->[1] eq $owner) {
        $m->cas($KEY, $entry->[0], 'released', 1)
            or warn "conditional release failed\n";
    }
    die $err unless $ok;
}

my ($trace_fh, $trace) = tempfile(UNLINK => 1);
my @pids;
for (1 .. $WORKERS) {
    defined(my $pid = fork()) or die "fork: $!";
    if (!$pid) {
        my $ok = eval { worker($trace_fh); 1 };
        warn $@ unless $ok;
        _exit($ok ? 0 : 1);
    }
    push @pids, $pid;
}
for (@pids) { waitpid($_, 0); die "worker failed\n" if $? }

open my $in, '<', $trace or die "trace: $!";
my @spans = sort { $a->[0] <=> $b->[0] } map { [split] } <$in>;
for my $i (1 .. $#spans) {
    die "overlapping leases\n" if $spans[$i][0] < $spans[$i - 1][1];
}
printf "%d refreshes serialized (best effort)\n", scalar @spans;
