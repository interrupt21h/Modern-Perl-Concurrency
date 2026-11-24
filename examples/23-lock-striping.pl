#!/usr/bin/env perl
# Lock striping with a global acquisition order.
# 64 accounts share 8 stripe locks. A transfer locks the two stripes it
# needs in ascending order, so no cycle of waiters (deadlock) can form.
# An auditor locks every stripe, again in ascending order, to take a
# consistent total while transfers continue.
use strict;
use warnings;
use threads;
use threads::shared;

my $ACCOUNTS = 64;
my $STRIPES  = 8;
my $OPENING  = 1000;

my @balance : shared = ($OPENING) x $ACCOUNTS;

# One shared scalar per stripe, held by reference. lock() works on the
# dereferenced scalar. (Never call these $a and $b: they shadow sort's
# variables.)
my @stripe = map { my $s = 0; share($s); \$s } 1 .. $STRIPES;

sub stripe_of { $_[0] % $STRIPES }

sub transfer {
    my ( $from, $to, $amount ) = @_;
    my ( $low, $high ) = sort { $a <=> $b } stripe_of($from),
        stripe_of($to);
    lock( ${ $stripe[$low] } );    # lower rank first, always
    lock( ${ $stripe[$high] } );    # same stripe twice: lock() is recursive
    return 0 if $balance[$from] < $amount;
    $balance[$from] -= $amount;
    $balance[$to]   += $amount;
    return 1;
}

# lock() releases at scope exit, so a variable number of locks is held by
# recursing: each frame keeps its stripe locked until the innermost returns.
sub with_all_stripes {
    my ( $code, $i ) = ( @_, 0 );
    return $code->() if $i == @stripe;
    lock( ${ $stripe[$i] } );
    return with_all_stripes( $code, $i + 1 );
}

my $stop : shared = 0;

my @movers = map {
    threads->create(
        sub {
            my $done = 0;
            for ( 1 .. 5000 ) {
                my $from = int rand $ACCOUNTS;
                my $to   = int rand $ACCOUNTS;
                next if $from == $to;
                $done += transfer( $from, $to, 1 + int rand 50 );
            }
            return $done;
        }
    );
} 1 .. 4;

my $auditor = threads->create(
    sub {
        my $audits = 0;
        until ($stop) {
            my $sum = with_all_stripes(
                sub { my $t = 0; $t += $_ for @balance; $t } );
            die "inconsistent audit: $sum\n"
                unless $sum == $ACCOUNTS * $OPENING;
            ++$audits;
        }
        return $audits;
    }
);

my $transfers = 0;
for my $thr (@movers) {
    my $n = $thr->join;
    die 'mover failed: ' . ( $thr->error // 'no result' ) unless defined $n;
    $transfers += $n;
}
{ lock($stop); $stop = 1; }
my $audits = $auditor->join;
die 'auditor failed: ' . ( $auditor->error // 'no result' )
    unless defined $audits;

my $total = 0;
$total += $_ for @balance;
die "money created or destroyed: $total\n"
    unless $total == $ACCOUNTS * $OPENING;
die "negative balance\n" if grep { $_ < 0 } @balance;
print "$transfers transfers, $audits consistent audits, total=$total\n";
