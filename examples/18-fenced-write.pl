#!/usr/bin/env perl
# End-to-end fencing: a Redis lease issues a fencing token and MySQL rejects
# writes carrying an older token. Client A pauses past its lease; client B
# acquires a newer token and writes; A's late write and release both fail.
use strict;
use warnings;
use DBI;
use Redis;
use Time::HiRes qw(sleep);

my $SERVER = $ENV{REDIS_SERVER} // '127.0.0.1:6379';
my $LEASE  = 'lease:{report}';
my $FENCE  = 'fence:{report}';

# Redis executes the embedded Lua; Perl sends it as data.
my $ACQUIRE = <<'LUA';
if redis.call('SET', KEYS[1], ARGV[1], 'NX', 'PX', ARGV[2]) then
    return redis.call('INCR', KEYS[2])
end
return 0
LUA

# Redis executes the embedded Lua; Perl sends it as data.
my $RELEASE = <<'LUA';
if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('DEL', KEYS[1])
end
return 0
LUA

my $dbh = DBI->connect(
    $ENV{DB_DSN},
    $ENV{DB_USER},
    $ENV{DB_PASS},
    {
        RaiseError           => 1,
        PrintError           => 0,
        AutoCommit           => 1,
        mysql_auto_reconnect => 0,
    }
);

# The destination enforces ordering. "<=" admits several writes by the
# current holder; use "<" for exactly one write per generation.
sub fenced_write {
    my ( $fence, $payload ) = @_;
    my $n = $dbh->do(
        q{UPDATE protected_resource
        SET payload = ?, last_fence = ?
        WHERE resource_id = 'report' AND last_fence <= ?},
        undef, $payload, $fence, $fence
    );
    return $n == 1;
}

sub client {
    Redis->new(
        server        => $SERVER,
        cnx_timeout   => 1,
        read_timeout  => 1,
        write_timeout => 1,
        reconnect     => 0
    )
}

my ( $ra, $rb ) = ( client(), client() );    # two independent clients
$ra->del($LEASE);

my $fence_a = $ra->eval( $ACQUIRE, 2, $LEASE, $FENCE, 'owner-a', 300 );
die "A could not acquire\n" unless $fence_a;
fenced_write( $fence_a, 'written by A' )
    or die "A's first write rejected: fence counter is behind the "
    . "destination (Redis data loss?). Fencing failed safe.\n";

sleep(0.5);    # A stalls: GC, SIGSTOP, swap

my $fence_b = $rb->eval( $ACQUIRE, 2, $LEASE, $FENCE, 'owner-b', 5000 );
die "B could not acquire after A's lease expired\n" unless $fence_b;
die "fence must increase\n" unless $fence_b > $fence_a;
fenced_write( $fence_b, 'written by B' ) or die "B's write rejected\n";

# A resumes, unaware that its lease expired.
my $stale = fenced_write( $fence_a, 'late write by A' );
my $a_rel = $ra->eval( $RELEASE, 1, $LEASE, 'owner-a' );
my $b_rel = $rb->eval( $RELEASE, 1, $LEASE, 'owner-b' );

my ( $payload, $last ) = $dbh->selectrow_array(
    q{SELECT payload, last_fence
    FROM protected_resource WHERE resource_id = 'report'}
);
$dbh->disconnect;

die "stale write accepted\n" if $stale;
die "A released B's lease\n" if $a_rel;
die "B could not release\n" unless $b_rel;
die "unexpected row: $payload\n"
    unless $payload eq 'written by B'
    && $last == $fence_b;
print "fence $fence_a rejected after fence $fence_b; row keeps B's write\n";
