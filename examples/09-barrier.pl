use strict;
use warnings;
use threads;
use threads::shared;
my $gate :shared;
my $arrived :shared = 0;
my $generation :shared = 0;
my $parties = 4;
sub barrier {
    lock($gate);
    my $g = $generation;
    if (++$arrived == $parties) {
        $arrived = 0;
        ++$generation;
        cond_broadcast($gate);
    } else {
        cond_wait($gate) while $generation == $g;
    }
}
my @t = map { threads->create(sub {
    barrier() for 1..20;
    return 1;
}) } 1..$parties;
for (@t) { die "failed" unless $_->join; }
die "wrong generation" unless $generation == 20;
print "20 phases completed\n";
