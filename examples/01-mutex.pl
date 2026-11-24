#!/usr/bin/env perl
# Lexical mutex protecting a read-modify-write on a shared counter.
use strict;
use warnings;
use threads;
use threads::shared;

my $count : shared = 0;
my $mutex : shared;    # dedicated lock variable, never mutated

my @workers = map {
    threads->create(
        sub {
            for ( 1 .. 10_000 ) {
                lock($mutex);    # released when this block iteration exits
                ++$count;
            }
            return 1;
        }
    );
} 1 .. 4;

for my $thr (@workers) {
    my $ok = $thr->join;
    die 'worker failed: ' . ( $thr->error // 'no result' ) unless $ok;
}
die "lost update: $count" unless $count == 40_000;
print "$count\n";
