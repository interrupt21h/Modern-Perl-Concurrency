use strict;
use warnings;
use threads;
use threads::shared;
my $ready :shared = 0;
my @workers = map { threads->create(sub {
    lock($ready);
    my $deadline = time + 10;
    until ($ready) {
        my $signalled = cond_timedwait($ready, $deadline);
        die "startup timeout" unless $signalled || $ready;
    }
    return 1;
}) } 1..4;
{ lock($ready); $ready = 1; cond_broadcast($ready); }
for (@workers) { die "worker failed" unless $_->join; }
print "all ready\n";
