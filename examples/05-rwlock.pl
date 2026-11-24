use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep);
my $gate :shared;
my $readers :shared = 0;
my $writer :shared = 0;
my $waiting :shared = 0;
my $value :shared = 0;
sub acquire_read {
    lock($gate);
    cond_wait($gate) while $writer || $waiting;
    ++$readers;
}
sub release_read {
    lock($gate);
    --$readers;
    cond_broadcast($gate) unless $readers;
}
sub acquire_write {
    lock($gate);
    ++$waiting;
    cond_wait($gate) while $writer || $readers;
    --$waiting;
    $writer = 1;
}
sub release_write {
    lock($gate);
    $writer = 0;
    cond_broadcast($gate);
}
sub with_rw {
    my ($write, $code) = @_;
    $write ? acquire_write() : acquire_read();
    my $result;
    my $ok = eval { $result = $code->(); 1 };
    my $err = $@;
    $write ? release_write() : release_read();
    die $err unless $ok;
    return $result;
}
my @t;
push @t, threads->create(sub {
    with_rw(1, sub { ++$value }) for 1..500;
}) for 1..2;
push @t, threads->create(sub {
    for (1..500) {
        with_rw(0, sub { die "bad value" if $value < 0 });
    }
}) for 1..4;
$_->join for @t;
die "lost update" unless $value == 1000;
print "value=$value\n";
