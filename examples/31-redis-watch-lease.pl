#!/usr/bin/env perl
# Owner-checked renewal and release, using Perl and Redis transactions.
# Run only against a disposable Redis >= 6.0.9 or Valkey instance.
use strict;
use warnings;
use Redis;
use Time::HiRes qw(sleep);

sub connect_redis {
    return Redis->new(
        server        => $ENV{REDIS_SERVER} // '127.0.0.1:6379',
        reconnect     => 0,
        cnx_timeout   => 1,
        read_timeout  => 1,
        write_timeout => 1,
        (
            defined $ENV{REDIS_PASSWORD}
            ? (
                username => $ENV{REDIS_USERNAME} // 'default',
                password => $ENV{REDIS_PASSWORD},
                )
            : ()
        ),
    );
}

# A dedicated connection per attempt avoids leaking WATCH/MULTI state
# on exceptions. Only a confirmed conflict is retried, never a lost reply.
sub change_lease {
    my ( $key, $owner, $ttl_ms ) = @_;

    for my $attempt ( 1 .. 8 ) {
        my $redis = connect_redis();
        $redis->watch($key);

        my $current = $redis->get($key);
        if ( !defined $current || $current ne $owner ) {
            $redis->unwatch();
            return 0;
        }

        $redis->multi();
        if ( defined $ttl_ms ) {
            $redis->pexpire( $key, $ttl_ms );
        }
        else {
            $redis->del($key);
        }

        # A null EXEC reply means a watched key changed. A successful
        # transaction has exactly one integer result in this example.
        my @reply = $redis->exec();
        if ( @reply == 1 && defined $reply[0] ) {
            return $reply[0] == 1;
        }
        die "unexpected EXEC reply\n" if @reply > 1;
        sleep( 0.005 + rand(0.015) );
    }
    die "transaction conflict budget exhausted\n";
}

my $redis = connect_redis();
open my $random, '<:raw', '/dev/urandom' or die "urandom: $!";
read( $random, my $bytes, 16 ) == 16 or die "short random read\n";
my $key   = 'lease:watch-demo:' . unpack( 'H*', $bytes );
my $owner = 'a';    # Lab-only owners; production needs random tokens.

$redis->set( $key, $owner, 'NX', 'PX', 5000 ) or die "acquire A\n";
change_lease( $key, $owner, 10_000 )          or die "renew A\n";
die "foreign renewal succeeded\n" if change_lease( $key, 'b', 5000 );
change_lease( $key, $owner, undef ) or die "release A\n";

$redis->set( $key, 'b', 'NX', 'PX', 5000 ) or die "acquire B\n";
die "stale release succeeded\n" if change_lease( $key, $owner, undef );
die "successor missing\n" unless ( $redis->get($key) // '' ) eq 'b';

# Force a WATCH conflict with a separate connection.
my $watcher = connect_redis();
$watcher->watch($key);
$redis->set( $key, 'c', 'PX', 5000 );
$watcher->multi();
$watcher->del($key);
my @aborted = $watcher->exec();
die "expected WATCH conflict\n" if grep { defined } @aborted;
die "conflicting transaction deleted key\n"
    unless ( $redis->get($key) // '' ) eq 'c';
change_lease( $key, 'c', undef ) or die "release C\n";

print "owner checks and WATCH conflict verified\n";
