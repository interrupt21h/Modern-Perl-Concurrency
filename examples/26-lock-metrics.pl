#!/usr/bin/env perl
# Measuring lock wait and hold time separately under real contention.
# with_timed_lock() wraps any critical section; each thread keeps its own
# samples (no shared metrics lock to distort the measurement) and returns
# them on join, where percentiles are computed.
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

sub now { clock_gettime(CLOCK_MONOTONIC) }

my $gate :shared;
my $counter :shared = 0;

# lock() lives for the duration of this sub, so the code runs while held.
sub with_timed_lock {
    my ($samples, $code) = @_;
    my $t0 = now();
    lock($gate);
    my $t1 = now();
    my @result = $code->();
    push @{ $samples->{wait} }, $t1 - $t0;
    push @{ $samples->{hold} }, now() - $t1;
    return wantarray ? @result : $result[0];
}

sub percentile {
    my ($p, @sorted) = @_;
    return $sorted[ int($p / 100 * $#sorted + 0.5) ];
}

my ($THREADS, $ITER, $WORK) = (4, 200, 0.001);   # 1 ms simulated work

my @workers = map {
    threads->create(sub {
        my %samples = (wait => [], hold => []);
        for (1 .. $ITER) {
            with_timed_lock(\%samples, sub { sleep($WORK); ++$counter });
            sleep(rand 0.001);                 # think time outside the lock
        }
        return \%samples;
    });
} 1 .. $THREADS;

my (@wait, @hold);
for my $thr (@workers) {
    my $s = $thr->join;
    die 'worker failed: ' . ($thr->error // 'no result') unless $s;
    push @wait, @{ $s->{wait} };
    push @hold, @{ $s->{hold} };
}

my $n = $THREADS * $ITER;
die "lost update: $counter\n" unless $counter == $n;
die "missing samples\n"       unless @wait == $n && @hold == $n;
@wait = sort { $a <=> $b } @wait;
@hold = sort { $a <=> $b } @hold;
die "hold shorter than the work done under the lock\n" if $hold[0] < $WORK * 0.9;

my $contended = grep { $_ > 0.0001 } @wait;      # waited more than 100 us
printf "%-5s %8s %8s %8s %8s   (ms, n=%d)\n", '', 'p50', 'p95', 'p99', 'max', $n;
for (['wait', \@wait], ['hold', \@hold]) {
    my ($name, $s) = @$_;
    printf "%-5s %8.3f %8.3f %8.3f %8.3f\n", $name,
        map { 1000 * $_ } percentile(50, @$s), percentile(95, @$s),
                          percentile(99, @$s), $s->[-1];
}
printf "contended acquisitions: %.0f%%\n", 100 * $contended / $n;
