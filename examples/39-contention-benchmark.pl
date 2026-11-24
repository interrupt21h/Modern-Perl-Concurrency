#!/usr/bin/env perl
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

my $workers    = 4;
my $iterations = 10_000;

sub trial {
    my ($stripes)        = @_;
    my @counter : shared = (0) x $stripes;
    my @guard            = map { shared_clone( {} ) } 1 .. $stripes;
    my $start            = clock_gettime(CLOCK_MONOTONIC);
    my @pool             = map {
        my $worker = $_;
        threads->create(
            sub {
                for my $i ( 1 .. $iterations ) {
                    my $bucket = $worker % $stripes;
                    lock( %{ $guard[$bucket] } );
                    ++$counter[$bucket];
                }
                return 1;
            }
        );
    } 0 .. $workers - 1;
    for my $worker (@pool) {
        my $ok = $worker->join;
        die "worker failed" unless $ok && !$worker->error;
    }
    my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $start;
    my $total   = 0;
    $total += $_ for @counter;
    die "lost increment" unless $total == $workers * $iterations;
    printf "stripes=%d workers=%d increments=%d elapsed=%.6fs\n",
        $stripes, $workers, $total, $elapsed;
}

# Includes thread creation and join: not a pure lock microbenchmark.
for ( 1 .. 3 ) {
    trial(1);
    trial(4);
}
print "all benchmark trials preserved the counter invariant\n";
