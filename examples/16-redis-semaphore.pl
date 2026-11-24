#!/usr/bin/env perl
# Distributed counting semaphore: a sorted set of owner tokens scored by
# server-side expiry time. Expired holders are purged atomically on every
# acquisition, so a crashed holder's permit returns after its TTL.
# Forks more workers than permits and verifies the concurrency bound.
use strict;
use warnings;
use Redis;
use File::Temp qw(tempfile);
use POSIX qw(_exit);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

my $SERVER  = $ENV{REDIS_SERVER} // '127.0.0.1:6379';
my $KEY     = 'sem:{demo-api}';
my $PERMITS = 3;
my $TTL_MS  = 3000;
my $WORKERS = 10;

# Server TIME is used so client clocks never decide expiry.
# Redis executes the embedded Lua; Perl sends it as data.
my %SCRIPT = (
    acquire => <<'LUA',
local t = redis.call('TIME')
local now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now)
if redis.call('ZCARD', KEYS[1]) >= tonumber(ARGV[1]) then
    return 0
end
redis.call('ZADD', KEYS[1], now + tonumber(ARGV[3]), ARGV[2])
local last = redis.call('ZRANGE', KEYS[1], -1, -1, 'WITHSCORES')
redis.call('PEXPIREAT', KEYS[1], last[2])
return 1
LUA
    renew => <<'LUA',
local t = redis.call('TIME')
local now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
local score = redis.call('ZSCORE', KEYS[1], ARGV[1])
if not score or tonumber(score) <= now then
    return 0
end
redis.call('ZADD', KEYS[1], 'XX', now + tonumber(ARGV[2]), ARGV[1])
local last = redis.call('ZRANGE', KEYS[1], -1, -1, 'WITHSCORES')
redis.call('PEXPIREAT', KEYS[1], last[2])
return 1
LUA
);

sub now { clock_gettime(CLOCK_MONOTONIC) }

sub token {
    open my $fh, '<:raw', '/dev/urandom' or die "urandom: $!";
    read($fh, my $bytes, 16) == 16 or die "short random read\n";
    return unpack 'H*', $bytes;
}

my %sha;
sub run_script {
    my ($r, $name, @rest) = @_;
    my $reply = eval {
        $sha{$name} //= $r->script_load($SCRIPT{$name});
        $r->evalsha($sha{$name}, @rest);
    };
    return $reply unless $@;
    die $@ unless $@ =~ /NOSCRIPT/;
    $sha{$name} = $r->script_load($SCRIPT{$name});
    return $r->evalsha($sha{$name}, @rest);
}

sub worker {
    my ($trace_fh) = @_;
    my $r = Redis->new(server => $SERVER, cnx_timeout => 1,
        read_timeout => 1, write_timeout => 1, reconnect => 0,
        (defined $ENV{REDIS_PASSWORD}
            ? (username => $ENV{REDIS_USERNAME} // 'default',
               password => $ENV{REDIS_PASSWORD}) : ()));
    my $owner = token();
    my $stop  = now() + 20;
    until (run_script($r, 'acquire', 1, $KEY, $PERMITS, $owner, $TTL_MS)) {
        die "permit timeout\n" if now() >= $stop;
        sleep(0.02 + rand 0.05);
    }
    my $entered = now();
    my $ok = eval {
        sleep(0.15);                                   # simulated call
        run_script($r, 'renew', 1, $KEY, $owner, $TTL_MS)
            or die "permit expired\n";                 # heartbeat demo
        sleep(0.05);
        1;
    };
    my $err = $@;
    my $left = now();
    syswrite $trace_fh, sprintf("%.6f %.6f\n", $entered, $left);
    eval { $r->zrem($KEY, $owner) };                   # owner-scoped release
    die $err unless $ok;
}

my ($trace_fh, $trace) = tempfile(UNLINK => 1);
my @pids;
for (1 .. $WORKERS) {
    defined(my $pid = fork()) or die "fork: $!";
    if (!$pid) {
        my $ok = eval { worker($trace_fh); 1 };
        warn $@ unless $ok;
        _exit($ok ? 0 : 1);
    }
    push @pids, $pid;
}
for (@pids) {
    waitpid($_, 0);
    die "worker failed\n" if $?;
}

# Sweep entry/exit events to find the peak number of concurrent holders.
open my $in, '<', $trace or die "trace: $!";
my @events = sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] }
    map { my ($s, $e) = split; ([$s, 1], [$e, -1]) } <$in>;
die "expected $WORKERS holders\n" unless @events == 2 * $WORKERS;
my ($active, $peak) = (0, 0);
for (@events) {
    $active += $_->[1];
    $peak = $active if $active > $peak;
}
die "bound violated: peak=$peak\n" if $peak > $PERMITS;
print "$WORKERS holders, peak=$peak (limit $PERMITS)\n";
