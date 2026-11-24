#!/usr/bin/env perl
# Counting semaphore bounding concurrency; peak usage tracked separately.
use strict;
use warnings;
use threads;
use threads::shared;
use Thread::Semaphore;
use Time::HiRes qw(sleep);

my $slots = Thread::Semaphore->new(3);
my $active : shared = 0;
my $peak   : shared = 0;

my @workers = map {
    threads->create(
        sub {
            die "permit timeout\n" unless $slots->down_timed(5);

            # Exactly one up() for the successful down(), on every path.
            my $ok = eval {
                {
                    lock($active);
                    ++$active;
                    $peak = $active if $active > $peak;
                }
                sleep(0.05);    # simulated bounded work
                1;
            };
            my $err = $@;
            { lock($active); --$active; }
            $slots->up;
            die $err unless $ok;
            return 1;
        }
    );
} 1 .. 12;

for my $thr (@workers) {
    $thr->join or die 'worker failed: ' . ( $thr->error // 'no result' );
}
die "invalid peak=$peak active=$active" unless $peak <= 3 && $active == 0;
print "peak=$peak\n";
