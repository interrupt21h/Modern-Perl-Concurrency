#!/usr/bin/env perl
# API credentials on Redis, driven through the SessionLab Catalyst app under
# Starman (4 workers): hashed API keys, per-key rate limits, JWT validation,
# the refresh-token rotation race (naive vs atomic), reuse detection, logout
# revocation, signed-request replay protection and OpenAPI coverage.
#
# Requires: Catalyst stack, Starman, Sereal, Redis, Crypt::JWT, YAML::XS.
use strict;
use warnings;
use FindBin;
use Crypt::JWT  qw(encode_jwt);
use Digest::SHA qw(sha256_hex hmac_sha256_hex);
use File::Temp  qw(tempdir);
use HTTP::Tiny;
use IO::Socket::INET;
use JSON::PP qw(encode_json decode_json);
use POSIX    qw(_exit);
use Redis;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);
use YAML::XS    qw(LoadFile);

$| = 1;
my $APP        = "$FindBin::Bin/catalyst-session";
my $REDIS      = $ENV{REDIS_SERVER} // '127.0.0.1:6379';
my $COOKIE     = 'sessionlab_sid';
my $GRACE_MS   = 1500;    # short grace window for the lab
my @NAMESPACES = qw(sess:* apikey:* user-apikeys:* rt:* rtfam:* jwt:deny:*
    nonce:* ratelimit:* user-sessions:*);

sub now { clock_gettime(CLOCK_MONOTONIC) }
my $redis = Redis->new( server => $REDIS, reconnect => 0 );

sub clear_namespaces {
    for my $pattern (@NAMESPACES) {
        my $cursor = 0;
        do {
            ( $cursor, my $keys ) =
                $redis->scan( $cursor, 'MATCH', $pattern, 'COUNT', 500 );
            $redis->del(@$keys) if @$keys;
        } while ($cursor);
    }
}

sub scan_keys {
    my ($pattern) = @_;
    my ( $cursor, @all ) = (0);
    do {
        ( $cursor, my $k ) =
            $redis->scan( $cursor, 'MATCH', $pattern, 'COUNT', 500, );
        push @all, @$k;
    } while ($cursor);
    return @all;
}

# ---------------------------------------------------------------- server
my $port = do {
    my $s = IO::Socket::INET->new(
        Listen    => 1,
        LocalAddr => '127.0.0.1',
        LocalPort => 0
    ) or die "no free port: $!";
    my $p = $s->sockport;
    close $s;
    $p;
};
my $log = tempdir( CLEANUP => 1 ) . '/starman.log';
clear_namespaces();
defined( my $server = fork() ) or die "fork: $!";
if ( !$server ) {
    open STDOUT, '>>', $log;
    open STDERR, '>>', $log;
    $ENV{SESSIONLAB_REFRESH_GRACE_MS} = $GRACE_MS;
    exec 'starman', '--workers', 4, '--listen', "127.0.0.1:$port",
        '--error-log', $log, "$APP/app.psgi"
        or _exit(127);
}

END {
    local $?;
    if ($server) {
        kill 'TERM', $server;
        waitpid( $server, 0 );
    }
}

my $base  = "http://127.0.0.1:$port";
my $http  = HTTP::Tiny->new( timeout => 10 );
my $ready = now() + 30;
until ( $http->get("$base/")->{status} == 200 ) {
    die "server did not start; see $log\n" if now() > $ready;
    sleep(0.2);
}

# ---------------------------------------------------------------- client
sub request {
    my ( $cl, $method, $path, %opt ) = @_;
    my %h = %{ $opt{headers} // {} };
    $h{Cookie} = "$COOKIE=$cl->{sid}" if $cl && $cl->{sid};
    my %args = ( headers => \%h );
    if ( $opt{json} ) {
        $args{content} =
            ref $opt{json} ? encode_json( $opt{json} ) : $opt{json};
        $h{'Content-Type'} = 'application/json';
    }
    my $res =
          $opt{form}
        ? $http->post_form( "$base$path", $opt{form}, \%args )
        : $http->request( $method, "$base$path", \%args );
    if ($cl) {
        my $set = $res->{headers}{'set-cookie'};
        for my $c ( ref $set ? @$set : grep defined, $set ) {
            $cl->{sid} = $1 if $c =~ /^\Q$COOKIE\E=([0-9a-f]+)/;
        }
    }
    my $body = eval { decode_json( $res->{content} ) } // {};
    return ( $res->{status}, $body, $res->{headers} );
}

# $n identical requests at once from forked processes; returns
# [status, body, outcome-header] for each.
sub concurrently {
    my ( $n, @req ) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    my @pids;
    for my $i ( 1 .. $n ) {
        defined( my $pid = fork() ) or die "fork: $!";
        if ( !$pid ) {
            my ( $s, $b, $h ) = request( undef, @req );
            open my $fh, '>', "$dir/$i" or _exit(1);
            print {$fh}
                encode_json( [ $s, $b, $h->{'x-refresh-outcome'} // '' ] );
            close $fh;
            _exit(0);
        }
        push @pids, $pid;
    }
    waitpid( $_, 0 ) for @pids;
    return map {
        open my $fh, '<', "$dir/$_" or die;
        local $/;
        decode_json(<$fh>);
    } 1 .. $n;
}

sub check {
    my ( $ok, $what ) = @_;
    die "FAILED: $what\n" unless $ok;
    printf "  ok  %s\n", $what;
}
sub bearer { { Authorization => "Bearer $_[0]" } }

sub active_in_family {
    my ($family) = @_;
    return scalar grep {
        ( $redis->hget( $_, 'state' ) // '' ) eq 'active'
    } scan_keys("rt:{$family}:*");
}

my $alice = { sid => undef };
my ($st) = request(
    $alice, 'POST', '/login',
    form => {
        user     => 'alice',
        password => 'correct horse'
    }
);
die "login failed\n" unless $st == 200;

# ---------------------------------------------------------------- 1. API keys
print "API keys\n";
my ( $s,   $b,   $h )       = request( $alice, 'POST', '/api/keys' );
my ( $key, $kid, $signing ) = @$b{qw(api_key key_id signing_secret)};
check(
    $s == 201 && $key =~ /\Aslk_[0-9a-f]{64}\z/,
    'key issued once, with a scannable prefix'
);
check(
    ( $h->{'cache-control'} // '' ) eq 'no-store',
    'credential responses are marked no-store'
);
check( $kid eq sha256_hex($key) && $redis->exists("apikey:$kid"),
    'Redis stores the SHA-256, keyed by hash' );
my $leak = grep {
    my $k = $_;
    grep { index( $_ // '', $key ) >= 0 } ( $k, $redis->hvals($k) )
} scan_keys('apikey:*');
check( !$leak, 'plaintext key appears nowhere in Redis' );
my $kttl = $redis->ttl("apikey:$kid");
check( $kttl > 89 * 86_400, "key expires (TTL $kttl s)" );
check(
    (
        request(
            undef, 'GET', '/api/me', headers => { 'X-API-Key' => $key }
        )
        )[0] == 200
        && (
        request(
            undef,     'GET',
            '/api/me', headers => { 'X-API-Key' => "${key}0" }
        )
        )[0] == 401,
    'valid key accepted, altered key refused'
);
my @codes = map {
    (
        request(
            undef,          'GET',
            '/api/limited', headers => { 'X-API-Key' => $key },
        )
    )[0]
} 1 .. 12;
check(
    10 == grep( { $_ == 200 } @codes ) && 2 == grep( { $_ == 429 } @codes ),
    'per-key limit: 10 allowed, then 429'
);
my ( undef, undef, $lh ) = request( undef, 'GET', '/api/limited',
    headers => { 'X-API-Key' => $key } );
check(
    ( $lh->{'ratelimit-policy'} // '' ) eq '"perkey";q=10;w=60'
        && ( $lh->{'ratelimit'} // '' ) =~ /\A"perkey";r=0;t=(\d+)\z/
        && $1 <= 60
        && ( $lh->{'retry-after'} // 0 ) == $1,
"RateLimit-Policy / RateLimit headers in draft-11 syntax ($lh->{ratelimit})"
);

# ---------------------------------------------------------------- 2. JWT
print "Access tokens (JWT)\n";
my ( undef, $pair ) = request( $alice, 'POST', '/api/token' );
check(
    (
        request(
            undef,     'GET',
            '/api/me', headers => bearer( $pair->{access_token} )
        )
    )[0] == 200,
    'bearer token accepted'
);
my ( $hdr, $pl, $sig ) = split /\./, $pair->{access_token};
my $none = join '.', 'eyJhbGciOiJub25lIn0', $pl, '';    # {"alg":"none"}
check(
    ( request( undef, 'GET', '/api/me', headers => bearer($none) ) )[0] ==
        401,
    'alg "none" refused'
);
my $lab_key = 'lab-only-jwt-key-change-me-0123456789abcdef';
my %good    = (
    sub => 'alice',
    fam => family( $pair->{refresh_token} ),
    iss => 'https://sessionlab.example/',
    aud => 'sessionlab-api',
    jti => 'y' x 32,
    iat => time,
    exp => time + 300
);
my %no_exp = %good;
delete $no_exp{exp};
my $no_exp = encode_jwt(
    alg           => 'HS256',
    key           => $lab_key,
    extra_headers => { typ => 'at+jwt' },
    payload       => \%no_exp
);
check(
    ( request( undef, 'GET', '/api/me', headers => bearer($no_exp) ) )[0]
        == 401,
    'correctly signed token without exp refused (verify_exp => 1)'
);
my $untyped =
    encode_jwt( alg => 'HS256', key => $lab_key, payload => \%good );
check(
    ( request( undef, 'GET', '/api/me', headers => bearer($untyped) ) )[0]
        == 401,
'correctly signed token without typ "at+jwt" refused (RFC 9068 explicit typing)'
);
my $typed = encode_jwt(
    alg           => 'HS256',
    key           => $lab_key,
    extra_headers => { typ => 'at+jwt' },
    payload       => \%good
);
check(
    ( request( undef, 'GET', '/api/me', headers => bearer($typed) ) )[0] ==
        200,
    '... and the same claims with the right typ are accepted (control)'
);
sub family { ( split /\./, $_[0] )[0] }

# ---------------------------------------------------------------- 3. naive refresh race
print "Refresh-token rotation: 6 simultaneous refreshes of one token\n";
my ( undef, $naive ) = request( $alice, 'POST', '/api/token' );
my @r = concurrently(
    6, 'POST',
    '/api/refresh_naive?delay=0.3',
    json => { refresh_token => $naive->{refresh_token} }
);
my $live = active_in_family( family( $naive->{refresh_token} ) );
check( $live > 1,
    "naive read-then-write FORKED the family: $live live refresh tokens" );

# ---------------------------------------------------------------- 4. atomic refresh
my ( undef, $atomic ) = request( $alice, 'POST', '/api/token' );
my $fam = family( $atomic->{refresh_token} );
@r = concurrently( 6, 'POST', '/api/refresh',
    json => { refresh_token => $atomic->{refresh_token} } );
my %outcome;
$outcome{ $_->[2] }++ for @r;
my %succ = map { ( $_->[1]{refresh_token} // '' ) => 1 } @r;
check(
    6 == grep( { $_->[0] == 200 } @r ),
    'atomic rotation: all six callers succeed'
);
check(
    ( $outcome{rotated} // 0 ) == 1 && ( $outcome{replay} // 0 ) == 5,
    'exactly one rotation; five duplicates replayed within the grace window'
);
check(
    keys %succ == 1 && active_in_family($fam) == 1,
    'all six got the same successor; one live token'
);
my ($successor) = keys %succ;

# ---------------------------------------------------------------- 5. reuse detection
print "Reuse detection\n";
my ( $s2, $b2 ) = request( undef, 'POST', '/api/refresh',
    json => { refresh_token => $successor } );
check(
    $s2 == 200 && $b2->{refresh_token} ne $successor,
    'normal rotation continues the chain'
);
my $current = $b2->{refresh_token};
sleep( $GRACE_MS / 1000 + 0.3 );
my ( $s3, undef, $h3 ) = request( undef, 'POST', '/api/refresh',
    json => { refresh_token => $atomic->{refresh_token} } );
check(
    $s3 == 401 && ( $h3->{'x-refresh-outcome'} // '' ) eq 'reuse',
    'old token presented after the grace window: reuse detected'
);
check(
    (
        request(
            undef,          'POST',
            '/api/refresh', json => { refresh_token => $current }
        )
    )[0] == 401,
    'whole family revoked: even the newest refresh token is refused'
);
check(
    (
        request(
            undef,     'GET',
            '/api/me', headers => bearer( $b2->{access_token} )
        )
    )[0] == 401,
    'access tokens of the revoked family stop working immediately'
);

# ---------------------------------------------------------------- 6. logout
print "Logout and revocation\n";
my ( undef, $p3 ) = request( $alice, 'POST', '/api/token' );
my $claims = decode_json(
    do {
        my $p = ( split /\./, $p3->{access_token} )[1];
        $p =~ tr{-_}{+/};
        $p .= '=' x ( -length($p) % 4 );
        require MIME::Base64;
        MIME::Base64::decode_base64($p);
    }
);
check(
    (
        request(
            undef,         'POST',
            '/api/logout', headers => bearer( $p3->{access_token} )
        )
    )[0] == 200,
    'logout'
);
check(
    (
        request(
            undef,     'GET',
            '/api/me', headers => bearer( $p3->{access_token} )
        )
    )[0] == 401,
    'same access token refused after logout'
);
my $dttl = $redis->ttl("jwt:deny:$claims->{jti}");
check( $dttl > 0 && $dttl <= 300,
    "denylist entry lives only until the token's exp ($dttl s)" );
check(
    (
        request(
            undef, 'POST', '/api/refresh',
            json => { refresh_token => $p3->{refresh_token} }
        )
    )[0] == 401,
    'refresh token of the logged-out family refused'
);

# ---------------------------------------------------------------- 7. signed requests
print "Signed requests\n";

sub nonce {
    join '', map { sprintf '%02x', int rand 256 } 1 .. 16
}

sub signed_req {
    my ( $ts, $nonce, $body, $sig_override ) = @_;
    my $sig = $sig_override // hmac_sha256_hex(
        join( "\n", 'POST', '/api/signed', $ts, $nonce, $body ),
        $signing, );
    return (
        request(
            undef, 'POST',
            '/api/signed',
            json    => $body,
            headers => {
                'X-Key-Id'    => $kid,
                'X-Timestamp' => $ts,
                'X-Nonce'     => $nonce,
                'X-Signature' => $sig,
            }
        )
    )[0];
}
my ( $ts, $n1, $body ) = ( time, nonce(), '{"amount":25}' );
check( signed_req( $ts, $n1, $body ) == 200, 'valid signature accepted' );
check( signed_req( $ts, $n1, $body ) == 409,
    'identical replay refused (nonce already used)' );
check( signed_req( time - 1000, nonce(), $body ) == 401,
    'stale timestamp refused' );
my $n2 = nonce();
check( signed_req( $ts, $n2, $body, '0' x 64 ) == 401,
    'forged signature refused ...' );
check( signed_req( time, $n2, $body ) == 200,
    '... without consuming the nonce of the real client' );

# ---------------------------------------------------------------- 8. OpenAPI
print "OpenAPI document\n";
my $doc = LoadFile("$APP/openapi.yaml");
check( $doc->{openapi} eq '3.2.0', 'document declares OpenAPI 3.2.0' );
my @tested = (
    '/api/keys',   '/api/token',   '/api/refresh', '/api/me',
    '/api/logout', '/api/limited', '/api/signed',  '/pay'
);
my @missing = grep { !$doc->{paths}{$_} } @tested;
check( !@missing,
    'every tested route is documented'
        . ( @missing ? ": missing @missing" : '' ) );
my @unsecured = grep {
    my $p = $doc->{paths}{$_};
    grep { !exists $p->{$_}{security} }
        grep { /^(get|post|put|patch|delete)$/ }
        keys %$p
} @tested;
check( !@unsecured,
    'every operation states its security requirement explicitly' );

clear_namespaces();
print
"API tokens: all checks passed (naive refresh left $live live tokens)\n";
