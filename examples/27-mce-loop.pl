#!/usr/bin/env perl
# MCE process pool: chunked parallel work, per-worker setup and gathered
# results, verified against a closed-form answer.
use strict;
use warnings;
use MCE::Loop;

# Kept small enough that every intermediate value is an exact integer:
# Perl numbers lose precision above 2**53 once they become floating point.
my $N = 200_000;
my $worker_resource;                 # per-worker state, created after fork

MCE::Loop->init(
    max_workers => 4,
    chunk_size  => 5_000,
    # Runs once in each worker after fork: open DB/Redis connections here,
    # never in the parent.
    user_begin  => sub { $worker_resource = "connection-for-$$" },
    user_end    => sub { undef $worker_resource },
);

# mce_loop_s iterates a numeric sequence without building the list in memory.
# Each chunk is summed locally; one gather per chunk keeps IPC cheap.
my @parts = mce_loop_s {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    die "worker setup missing\n" unless $worker_resource;
    my $sum = 0;
    $sum += $_ * $_ for @$chunk_ref;
    MCE->gather([ $chunk_id, scalar @$chunk_ref, $sum, $$ ]);
} 1, $N;

MCE::Loop->finish;

my ($count, $sum, %pids, %chunks) = (0, 0);
for (@parts) {
    my ($id, $n, $s, $pid) = @$_;
    die "chunk $id gathered twice\n" if $chunks{$id}++;
    $count += $n;
    $sum   += $s;
    $pids{$pid}++;
}
my $expected = $N * ($N + 1) * (2 * $N + 1) / 6;   # sum of squares 1..N
die "result exceeds exact integer range\n" if $expected >= 2**53;
die "missing items: $count\n" unless $count == $N;
die "wrong sum: $sum\n"       unless $sum == $expected;
printf "sum of squares 1..%d = %d from %d chunks across %d workers\n",
    $N, $sum, scalar @parts, scalar keys %pids;
