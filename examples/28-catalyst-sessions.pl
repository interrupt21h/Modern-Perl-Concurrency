#!/usr/bin/env perl
# Drives the SessionLab Catalyst application (examples/catalyst-session)
# under Starman with four preforked workers, exactly as production would,
# and verifies each session-coordination property against live Redis.
#
# Requires: Catalyst, Catalyst::Plugin::Session (+ State::Cookie), Sereal,
#           Starman, Redis. Uses REDIS_SERVER (default 127.0.0.1:6379) and
#           only the key namespaces listed in @NAMESPACES below.
use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
use HTTP::Tiny;
use IO::Socket::INET;
use JSON::PP qw(decode_json);
use POSIX qw(_exit);
use Redis;
use Sereal::Encoder;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

$| = 1;
my $APP      = "$FindBin::Bin/catalyst-session";
my $REDIS    = $ENV{REDIS_SERVER} // '127.0.0.1:6379';
my @NAMESPACES = qw(sess:* cart:* idem:* charges:* ratelimit:* user-sessions:* slock:*);
my $COOKIE   = 'sessionlab_sid';

sub now { clock_gettime(CLOCK_MONOTONIC) }
my $redis = Redis->new(server => $REDIS, reconnect => 0);

# ---------------------------------------------------------------- server
sub clear_namespaces {
    for my $pattern (@NAMESPACES) {
        my $cursor = 0;
        do {
            ($cursor, my $keys) = $redis->scan($cursor, 'MATCH', $pattern,
                'COUNT', 500);
            $redis->del(@$keys) if @$keys;
        } while ($cursor);
    }
}

my $port = do {
    my $s = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0)
        or die "no free port: $!";
    my $p = $s->sockport;
    close $s;
    $p;
};
my $log = tempdir(CLEANUP => 1) . '/starman.log';
clear_namespaces();

defined(my $server = fork()) or die "fork: $!";
if (!$server) {
    open STDOUT, '>>', $log;
    open STDERR, '>>', $log;
    $ENV{SESSIONLAB_FAULTS} = 1;                # enable the crash switch
    exec 'starman', '--workers', 4, '--listen', "127.0.0.1:$port",
        '--error-log', $log, "$APP/app.psgi" or _exit(127);
}
# local $? keeps waitpid from overwriting this script's own exit status.
END {
    local $?;
    if ($server) {
        kill 'TERM', $server;
        waitpid($server, 0);
    }
}

my $base = "http://127.0.0.1:$port";
my $http = HTTP::Tiny->new(timeout => 10);
my $ready = now() + 30;
until ($http->get("$base/")->{status} == 200) {
    die "server did not start; see $log\n" if now() > $ready;
    sleep(0.2);
}

# ---------------------------------------------------------------- client
# A minimal browser: remembers one session cookie, honors Set-Cookie.
sub client { return { sid => undef } }

sub request {
    my ($cl, $method, $path, %opt) = @_;
    my %headers = %{ $opt{headers} // {} };
    $headers{Cookie} = "$COOKIE=$cl->{sid}" if $cl->{sid};
    my $res = $opt{form}
        ? $http->post_form("$base$path", $opt{form}, { headers => \%headers })
        : $http->request($method, "$base$path", { headers => \%headers });
    my $set = $res->{headers}{'set-cookie'};
    for my $c (ref $set ? @$set : grep defined, $set) {
        $cl->{sid} = $1, $cl->{cookie} = $c if $c =~ /^\Q$COOKIE\E=([0-9a-f]+)/;
    }
    my $body = eval { decode_json($res->{content}) } // {};
    return ($res->{status}, $body, $res->{headers});
}

# Run $n identical requests concurrently from forked processes that share
# the client's session cookie; returns the status codes.
sub concurrently {
    my ($n, $cl, @req) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my @pids;
    for my $i (1 .. $n) {
        defined(my $pid = fork()) or die "fork: $!";
        if (!$pid) {
            my %copy = %$cl;                       # same cookie, no write-back
            my ($status) = request(\%copy, @req);
            open my $fh, '>', "$dir/$i" or _exit(1);
            print {$fh} $status;
            close $fh;
            _exit(0);
        }
        push @pids, $pid;
    }
    waitpid($_, 0) for @pids;
    return map { open my $fh, '<', "$dir/$_" or die; scalar <$fh> } 1 .. $n;
}

sub check {
    my ($ok, $what) = @_;
    die "FAILED: $what\n" unless $ok;
    printf "  ok  %s\n", $what;
}

# ---------------------------------------------------------------- 1. storage
print "Session storage\n";
my $anon = client();
request($anon, 'GET', '/cart_atomic/x');
check($anon->{sid} && $anon->{sid} =~ /\A[0-9a-f]{64}\z/, '256-bit random session ID');
check($anon->{cookie} =~ /HttpOnly/i && $anon->{cookie} =~ /SameSite=Lax/i,
    'cookie carries HttpOnly and SameSite=Lax');
my $ttl = $redis->ttl("sess:session:$anon->{sid}");
check($ttl > 0 && $ttl <= 3600, "session record has a TTL ($ttl s), set atomically");
my $raw = $redis->get("sess:session:$anon->{sid}");
check($raw =~ /\A=(?:srl|\xF3rl)/, 'record is Sereal-encoded, not Storable');

# ---------------------------------------------------------------- 2. fixation
print "Authentication\n";
my $alice = client();
request($alice, 'GET', '/cart_atomic/x');                  # pre-login session
my $pre = $alice->{sid};
my ($st, $body) = request($alice, 'POST', '/login',
    form => { user => 'alice', password => 'correct horse' });
check($st == 200 && $body->{rotated}, 'login succeeds and rotates the session');
check($alice->{sid} ne $pre, 'session ID changed at login (fixation defense)');
check(!$redis->exists("sess:session:$pre"), 'pre-login session record deleted');

# ---------------------------------------------------------------- 3. races
print "Concurrent requests in one session (8 at once, 4 workers)\n";
concurrently(8, $alice, 'GET', '/cart_naive/apple?delay=0.3');
(undef, $body) = request($alice, 'GET', '/cart');
my $naive = $body->{session}{apple} // 0;
check($naive < 8, "naive session read-modify-write LOST updates: $naive of 8 kept");

concurrently(8, $alice, 'GET', '/cart_atomic/pear?delay=0.3');
(undef, $body) = request($alice, 'GET', '/cart');
check(($body->{atomic}{pear} // 0) == 8, 'atomic HINCRBY outside the session: 8 of 8');

my $t0 = now();
my @codes = concurrently(8, $alice, 'GET', '/cart_locked/plum?delay=0.1');
my $locked_elapsed = now() - $t0;
(undef, $body) = request($alice, 'GET', '/cart');
check(($body->{session}{plum} // 0) == 8 && !grep({ $_ != 200 } @codes),
    'per-session lock: 8 of 8 kept');
check($locked_elapsed >= 0.8,
    sprintf('...at the price of serialization (%.2fs for 8 x 0.1s)', $locked_elapsed));

# ---------------------------------------------------------------- 4. idempotency
print "Idempotency keys\n";
my $key = 'order-7f3a9c2e-0001';
@codes = concurrently(6, $alice, 'POST', '/pay',
    form => { amount => 25 }, headers => { 'Idempotency-Key' => $key });
my $created = grep { $_ == 201 } @codes;
check($created == 1, "6 simultaneous submissions: exactly one 201 (@codes)");
my ($rs, $rb, $rh) = request($alice, 'POST', '/pay',
    form => { amount => 25 }, headers => { 'Idempotency-Key' => $key });
check($rs == 201 && ($rh->{'idempotent-replayed'} // '') eq 'true',
    'retry replays the stored response');
(undef, $body) = request($alice, 'GET', '/charges');
check($body->{charges} == 1, 'customer charged once');
($rs) = request($alice, 'POST', '/pay',
    form => { amount => 99 }, headers => { 'Idempotency-Key' => $key });
check($rs == 422, 'same key, different request: rejected');
my $idem_ttl = $redis->ttl("idem:alice:$key");
check($idem_ttl > 86_000, "idempotency record kept for 24 h (TTL $idem_ttl s)");

# A worker killed after charging but before storing the response: the
# outcome is unknown to the client, so a retry must NOT charge again.
my $crash_key = 'order-7f3a9c2e-0002';
my ($cs) = request($alice, 'POST', '/pay?crash=1',
    form => { amount => 40 }, headers => { 'Idempotency-Key' => $crash_key });
check($cs >= 500, "worker killed mid-request: client sees $cs");
(undef, $body) = request($alice, 'GET', '/charges');
check($body->{charges} == 2, 'the side effect did happen');
($rs) = request($alice, 'POST', '/pay',
    form => { amount => 40 }, headers => { 'Idempotency-Key' => $crash_key });
check($rs == 409, 'immediate retry refused while the outcome is unknown');
(undef, $body) = request($alice, 'GET', '/charges');
check($body->{charges} == 2, 'no second charge');
my $stuck_ttl = $redis->ttl("idem:alice:$crash_key");
check($stuck_ttl > 0 && $stuck_ttl <= 120,
    "abandoned pending key expires in $stuck_ttl s, not 24 h");

# ---------------------------------------------------------------- 5. rate limit
print "Login rate limiting\n";
my $bob = client();
my @attempts = map {
    (request($bob, 'POST', '/login', form => { user => 'bob', password => 'guess' }))[0]
} 1 .. 7;
check("@attempts" eq '401 401 401 401 401 429 429', "attempts: @attempts");
($rs) = request($bob, 'POST', '/login', form => { user => 'bob',
    password => 'battery staple' });
check($rs == 429, 'even the right password waits for the window to expire');
check($redis->pttl('ratelimit:login:bob') > 0, 'counter expires with its window');

# ---------------------------------------------------------------- 6. revocation
print "Logout everywhere\n";
my $alice2 = client();
request($alice2, 'POST', '/login', form => { user => 'alice',
    password => 'correct horse' });
check((request($alice, 'GET', '/whoami'))[0] == 200
   && (request($alice2, 'GET', '/whoami'))[0] == 200,
       'two concurrent sessions for alice');
(undef, $body) = request($alice2, 'GET', '/logout_everywhere');
check($body->{revoked} >= 2, "revoked $body->{revoked} sessions");
check((request($alice, 'GET', '/whoami'))[0] == 401, 'other device is logged out');

# ---------------------------------------------------------------- 7. forgery
print "Forged session record\n";
my $victim = client();
request($victim, 'POST', '/login', form => { user => 'alice',
    password => 'correct horse' });
my $evil = Sereal::Encoder->new->encode(bless { user => 'mallory' }, 'Evil::Payload');
$redis->set("sess:session:$victim->{sid}", $evil, 'EX', 60);
($rs) = request($victim, 'GET', '/whoami');
check($rs == 401, 'record containing an object is discarded, not revived');
my $logged;                                 # workers may flush after replying
for (1 .. 20) {
    open my $lf, '<', $log or die "log: $!";
    last if $logged = grep { /discarding undecodable session record/ } <$lf>;
    sleep(0.1);
}
check($logged, 'and the event is logged');

clear_namespaces();
printf "Catalyst sessions: all checks passed (naive kept %d of 8)\n", $naive;
