#!/usr/bin/env perl
# Bounded work queue with explicit envelopes and end-of-stream signalling.
use strict;
use warnings;
use threads;
use Thread::Queue;

my $jobs    = Thread::Queue->new;
my $results = Thread::Queue->new;    # unbounded: consumed after join
$jobs->limit = 16;    # producers block when 16 are pending

my @workers = map {
    threads->create(
        sub {
            while ( defined( my $job = $jobs->dequeue ) ) {
                my $value = eval { $job->{n}**2 };
                my $err   = $@;
                $results->enqueue(
                    {
                        id    => $job->{id},
                        value => $value,
                        error => $err
                    }
                );
            }
            return 1;
        }
    );
} 1 .. 4;

$jobs->enqueue( { id => $_, n => $_ } ) for 1 .. 100;
$jobs->end;    # dequeue returns undef once drained
for my $thr (@workers) {
    $thr->join or die 'worker failed: ' . ( $thr->error // 'no result' );
}
$results->end;

my %seen;
while ( defined( my $r = $results->dequeue ) ) {
    die $r->{error}          if $r->{error};
    die "duplicate $r->{id}" if $seen{ $r->{id} }++;
    die "bad result $r->{id}" unless $r->{value} == $r->{id}**2;
}
die 'missing jobs' unless keys(%seen) == 100;
print "100 jobs completed\n";
