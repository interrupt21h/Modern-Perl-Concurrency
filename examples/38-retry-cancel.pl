#!/usr/bin/env perl
use strict;
use warnings;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

# The operation returns a classified outcome, not a raw driver exception.
# Only confirmed conflicts are retried. Unknown outcomes are reconciled.
sub retry_operation {
    my ( $attempt, $cancelled, $budget, $deadline ) = @_;
    for my $number ( 1 .. $budget ) {
        return 'cancelled' if $cancelled->();
        return 'deadline'  if clock_gettime(CLOCK_MONOTONIC) >= $deadline;
        my $status = $attempt->($number);
        return $status unless $status eq 'conflict';
        return 'exhausted' if $number == $budget;
        my $delay = 0.001 * ( 2**( $number - 1 ) );
        $delay = 0.05 if $delay > 0.05;
        $delay *= 0.5 + rand();
        my $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
        return 'deadline' if $remaining <= 0;
        sleep( $delay < $remaining ? $delay : $remaining );
    }
    return 'exhausted';
}

my $deadline = clock_gettime(CLOCK_MONOTONIC) + 5;
my $calls    = 0;
my $result   = retry_operation(
    sub { ++$calls == 3 ? 'committed' : 'conflict' },
    sub { 0 },
    4, $deadline,
);
die "retry invariant" unless $result eq 'committed' && $calls == 3;
$calls = 0;
$result =
    retry_operation( sub { ++$calls; 'unknown' }, sub { 0 }, 4, $deadline,
    );
die "unknown outcome retried" unless $result eq 'unknown' && $calls == 1;
$calls  = 0;
$result = retry_operation(
    sub { ++$calls; 'conflict' },
    sub { $calls >= 1 },
    4, $deadline,
);
die "cancellation ignored" unless $result eq 'cancelled' && $calls == 1;
print "classified retries, unknown outcome and cancellation verified\n";
