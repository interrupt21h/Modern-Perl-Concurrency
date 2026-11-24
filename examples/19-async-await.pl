#!/usr/bin/env perl
# Event-loop concurrency with Future::AsyncAwait: bounded fan-out (an async
# semaphore) and Future::Mutex protecting state across an await point.
use strict;
use warnings;
use Future::AsyncAwait;
use Future::Mutex;
use Future::Utils qw(fmap_void);
use IO::Async::Loop;

my $loop  = IO::Async::Loop->new;
my $mutex = Future::Mutex->new;
my ( $active, $peak, $balance ) = ( 0, 0, 0 );

async sub request {
    my ($id) = @_;
    ++$active;
    $peak = $active if $active > $peak;
    await $loop->delay_future( after => 0.01 + rand 0.02 );    # simulated I/O

    # One interpreter, yet this read-modify-write is still a race: another
    # request can run while this one is suspended at the inner await.
    await $mutex->enter(
        async sub {
            my $seen = $balance;
            await $loop->delay_future( after => 0.001 );
            $balance = $seen + 1;
        }
    );
    --$active;
    return;
}

my $all = fmap_void { request(shift) } foreach => [ 1 .. 40 ],
    concurrent => 5;
$loop->await($all);
$all->get;    # rethrows any failure

die "concurrency bound violated: $peak\n" if $peak > 5;
die "lost update: $balance\n" unless $balance == 40;
print "40 requests, peak=$peak, balance=$balance\n";
