#!/usr/bin/env perl
# Fenced Redis lease: atomic SET NX PX + INCR fence in one script, owner-
# checked renewal and release, EVALSHA with NOSCRIPT fallback.
# Forks competing workers, then verifies that critical sections never
# overlapped and that fencing tokens increase in acquisition order.
use strict;
use warnings;
use Redis;
use File::Temp  qw(tempfile);
use POSIX       qw(_exit);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

my $SERVER  = $ENV{REDIS_SERVER} // '127.0.0.1:6379';
my $LEASE   = 'lease:{demo-report}';    # hash tag keeps both keys in one
my $FENCE   = 'fence:{demo-report}';    # cluster slot for the script
my $TTL_MS  = 2000;
my $MARGIN  = 0.2;    # seconds reserved for skew/latency
my $WORKERS = 4;

# Redis executes the embedded Lua; Perl sends it as data.
my %SCRIPT = (
    acquire => <<'LUA',
if redis.call('SET', KEYS[1], ARGV[1], 'NX', 'PX', ARGV[2]) then
    return redis.call('INCR', KEYS[2])
end
return 0
LUA
    renew => <<'LUA',
if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('PEXPIRE', KEYS[1], ARGV[2])
end
return 0
LUA
    release => <<'LUA',
if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('DEL', KEYS[1])
end
return 0
LUA
);

sub now { clock_gettime(CLOCK_MONOTONIC) }

sub token {
    open my $fh, '<:raw', '/dev/urandom' or die "urandom: $!";
    read( $fh, my $bytes, 16 ) == 16 or die "short random read\n";
    return unpack 'H*', $bytes;
}

sub connect_redis {
    return Redis->new(
        server        => $SERVER,
        name          => "lease-demo-$$",
        cnx_timeout   => 1,
        read_timeout  => 1,
        write_timeout => 1,
        reconnect     => 0,    # never replay a mutating command
        (
            defined $ENV{REDIS_PASSWORD}
            ? (
                username => $ENV{REDIS_USERNAME} // 'default',
                password => $ENV{REDIS_PASSWORD}
                )
            : ()
        ),
    );
}

# EVALSHA first; load the script once if the server's cache lacks it.
my %sha;

sub run_script {
    my ( $r, $name, @keys_and_args ) = @_;
    my $reply = eval {
        $sha{$name} //= $r->script_load( $SCRIPT{$name} );
        $r->evalsha( $sha{$name}, @keys_and_args );
    };
    return $reply unless $@;
    die $@        unless $@ =~ /NOSCRIPT/;
    $sha{$name} = $r->script_load( $SCRIPT{$name} );
    return $r->evalsha( $sha{$name}, @keys_and_args );
}

# Returns (fence, valid_until) or an empty list when the budget expires.
sub acquire {
    my ( $r, $owner, $budget ) = @_;
    my $stop = now() + $budget;
    while ( now() < $stop ) {
        my $start = now();    # measured before the request
        my $fence =
            run_script( $r, 'acquire', 2, $LEASE, $FENCE, $owner, $TTL_MS );
        return ( $fence, $start + $TTL_MS / 1000 - $MARGIN ) if $fence;
        sleep( 0.025 + rand 0.075 );    # randomized backoff
    }
    return;
}

sub renew {
    my ( $r, $owner ) = @_;
    my $start = now();
    return
        unless run_script( $r, 'renew', 1, $LEASE, $owner, $TTL_MS ) == 1;
    return $start + $TTL_MS / 1000 - $MARGIN;
}

sub worker {
    my ( $trace_fh, $id ) = @_;
    my $r = connect_redis();    # one connection per process
    my $owner = token();
    my ( $fence, $valid_until ) = acquire( $r, $owner, 15 )
        or die "worker $id: lease unavailable\n";
    my $entered = now();
    my $ok      = eval {
        for my $step ( 1 .. 4 ) {    # bounded work in short steps
            die "lease budget exhausted\n" if now() >= $valid_until;
            sleep(0.05);

            # Heartbeat when a third of the TTL has elapsed.
            if ( $valid_until - now() < 2 * $TTL_MS / 3000 ) {
                $valid_until = renew( $r, $owner )
                    or die "ownership lost\n";
            }
        }
        1;
    };
    my $err  = $@;
    my $left = now();
    syswrite $trace_fh,
        sprintf( "%d %.6f %.6f %d\n", $fence, $entered, $left, $$ );
    my $released = eval { run_script( $r, 'release', 1, $LEASE, $owner ) };
    warn "worker $id: release uncertain or ownership lost\n"
        unless $released;
    die $err unless $ok;
}

my ( $trace_fh, $trace ) = tempfile( UNLINK => 1 );
my @pids;
for my $id ( 1 .. $WORKERS ) {
    defined( my $pid = fork() ) or die "fork: $!";
    if ( !$pid ) {
        my $ok = eval { worker( $trace_fh, $id ); 1 };
        warn $@ unless $ok;
        _exit( $ok ? 0 : 1 );
    }
    push @pids, $pid;
}
for (@pids) {
    waitpid( $_, 0 );
    die "worker failed\n" if $?;
}

open my $in, '<', $trace or die "trace: $!";
my @spans = sort { $a->[1] <=> $b->[1] } map { [split] } <$in>;
die "expected $WORKERS spans\n" unless @spans == $WORKERS;
for my $i ( 1 .. $#spans ) {
    my ( $prev, $cur ) = @spans[ $i - 1, $i ];
    die "overlap between $prev->[3] and $cur->[3]\n"
        if $cur->[1] < $prev->[2];
    die "fence did not increase\n" unless $cur->[0] > $prev->[0];
}
printf "%d leases, no overlap, fences %s\n", scalar @spans,
    join( ' < ', map { $_->[0] } @spans );
