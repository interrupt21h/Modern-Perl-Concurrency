#!/usr/bin/env perl
use strict;
use warnings;
use threads;
use threads::shared;
use Thread::Queue;

my $counter : shared = 0;
my $read             = Thread::Queue->new;
my $go               = Thread::Queue->new;
my @workers          = map {
    threads->create(
        sub {
            my $snapshot;
            { lock($counter); $snapshot = $counter; }
            $read->enqueue(1);
            $go->dequeue;
            { lock($counter); $counter = $snapshot + 1; }
            return 1;
        }
    );
} 1 .. 2;

$read->dequeue for 1 .. 2;
$go->enqueue( 1, 1 );
for my $worker (@workers) {
    my $ok = $worker->join;
    die "worker failed" unless $ok && !$worker->error;
}
die "expected lost update" unless $counter == 1;

$counter = 0;
@workers = map {
    threads->create(
        sub {
            $read->enqueue(1);
            $go->dequeue;
            {
                lock($counter);
                my $snapshot = $counter;
                threads->yield();
                $counter = $snapshot + 1;
            }
            return 1;
        }
    );
} 1 .. 2;
$read->dequeue for 1 .. 2;
$go->enqueue( 1, 1 );
for my $worker (@workers) {
    my $ok = $worker->join;
    die "worker failed" unless $ok && !$worker->error;
}
die "fixed update lost" unless $counter == 2;
print "forced lost update and corrected critical section verified\n";
