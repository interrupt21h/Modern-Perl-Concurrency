package SessionLab::Controller::API;

# API credentials on Redis: hashed API keys, rotating refresh tokens with
# reuse detection, JWT access tokens with a revocation denylist, signed
# requests with nonce replay protection, and per-key rate limiting.
# Documented by examples/catalyst-session/openapi.yaml.
use Moose;
use namespace::autoclean;
use JSON::PP    ();
use Digest::SHA qw(hmac_sha256_hex);
use Time::HiRes qw(sleep);
use SessionLab::Redis;
use SessionLab::Tokens qw(random_hex token_hash new_api_key new_family
    new_refresh successor_of family_of issue_access_token verify_access_token
    sign_request);

BEGIN { extends 'Catalyst::Controller' }
__PACKAGE__->config( namespace => 'api' );

my $JSON           = JSON::PP->new->canonical;
my $KEY_TTL        = 90 * 86_400;    # API keys: 90 days
my $REFRESH_TTL    = 30 * 86_400;    # refresh families: 30 days
my $GRACE_MS       = $ENV{SESSIONLAB_REFRESH_GRACE_MS} // 30_000;
my $SKEW           = 300;    # signed-request clock window
my $SIGNING_MASTER = $ENV{SESSIONLAB_SIGNING_KEY}
    // 'lab-only-signing-master-change-me';

sub _redis { SessionLab::Redis->handle }

sub _json {
    my ( $c, $status, $data ) = @_;
    $c->res->status($status);
    $c->res->content_type('application/json');
    $c->res->header( 'Cache-Control' => 'no-store' )
        ;    # never cache credentials
    $c->res->body( $JSON->encode($data) );
}

sub _body {
    my ($c) = @_;
    my $b = $c->req->body_data;
    return ref $b eq 'HASH' ? $b : {};
}

# Length-independent comparison for secrets.
sub _secure_eq {
    my ( $x, $y ) = @_;
    return 0 unless defined $x && defined $y && length $x == length $y;
    my $diff = 0;
    $diff |= ord( substr $x, $_, 1 ) ^ ord( substr $y, $_, 1 )
        for 0 .. length($x) - 1;
    return $diff == 0;
}

# The exact bytes that were signed: Catalyst exposes the body as a
# filehandle (spooled by HTTP::Body) or, for some types, as a string.
sub _raw_body {
    my ($c) = @_;
    my $b = $c->req->body;
    return '' unless defined $b;
    return $b unless ref $b;
    seek $b, 0, 0;
    local $/;
    my $raw = <$b>;
    return $raw // '';
}

sub _session_user {
    my ($c) = @_;
    return $c->sessionid ? $c->session->{user} : undef;
}

# ------------------------------------------------------------------ API keys
# The key is shown once; Redis stores only its SHA-256. The HMAC signing
# secret is derived from the key hash, so it is never stored either.
sub create_key : Path('keys') : Args(0) {
    my ( $self, $c ) = @_;
    my $user = _session_user($c)
        or return _json( $c, 401, { error => 'login required' } );
    my $key = new_api_key();
    my $kid = token_hash($key);
    _redis()->hset( "apikey:$kid", user => $user, created => time );
    _redis()->expire( "apikey:$kid", $KEY_TTL );
    _redis()->sadd( "user-apikeys:$user", $kid );
    _json(
        $c, 201,
        {
            api_key        => $key,
            key_id         => $kid,
            signing_secret => hmac_sha256_hex( $kid, $SIGNING_MASTER ),
            expires_in     => $KEY_TTL
        }
    );
}

# ------------------------------------------------------------------ tokens
# Issuance from an authenticated first-party session keeps the laboratory
# focused on storage and concurrency. A production authorization server
# uses the authorization code flow with PKCE (RFC 9700); the resource owner
# password grant must not be used.
sub create_token : Path('token') : Args(0) {
    my ( $self, $c ) = @_;
    my $user = _session_user($c)
        or return _json( $c, 401, { error => 'login required' } );
    my $family  = new_family();
    my $refresh = new_refresh($family);
    my $rh      = token_hash($refresh);
    my $r       = _redis();
    $r->hset( "rtfam:{$family}", user => $user, current => $rh );
    $r->expire( "rtfam:{$family}", $REFRESH_TTL );
    $r->hset( "rt:{$family}:$rh", state => 'active', user => $user );
    $r->expire( "rt:{$family}:$rh", $REFRESH_TTL );
    my ($jwt) = issue_access_token( sub => $user, fam => $family );
    _json(
        $c, 201,
        {
            access_token  => $jwt,
            token_type    => 'Bearer',
            expires_in    => 300,
            refresh_token => $refresh
        }
    );
}

# One atomic step decides the fate of a presented refresh token:
#   active            -> mark used, activate the successor        (rotated)
#   used, within grace -> same successor again                    (replay)
#   used, after grace  -> revoke the whole family                 (reuse)
# Server TIME is used so client clocks never matter.
# Redis executes the embedded Lua; Perl sends it as data.
my $ROTATE = <<'LUA';
if redis.call('EXISTS', KEYS[2]) == 0 then
    return 'revoked'
end

local rec = redis.call('HMGET', KEYS[1], 'state', 'used_at', 'successor', 'user')
if not rec[1] then
    return 'unknown'
end

local t = redis.call('TIME')
local now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
if rec[1] == 'active' then
    redis.call('HSET', KEYS[1],
        'state', 'used', 'used_at', now, 'successor', ARGV[1])
    redis.call('HSET', KEYS[3], 'state', 'active', 'user', rec[4])
    redis.call('EXPIRE', KEYS[3], ARGV[3])
    redis.call('HSET', KEYS[2], 'current', ARGV[1])
    redis.call('EXPIRE', KEYS[2], ARGV[3])
    return 'rotated'
end
if rec[3] == ARGV[1] and now - tonumber(rec[2]) <= tonumber(ARGV[2]) then
    return 'replay'
end
redis.call('DEL', KEYS[2])
return 'reuse'
LUA

sub refresh : Path('refresh') : Args(0) {
    my ( $self, $c ) = @_;
    my $presented = _body($c)->{refresh_token} // '';
    my $family    = family_of($presented)
        or return _json( $c, 400, { error => 'malformed refresh token' } );
    my $successor = successor_of($presented);
    my ( $old_h, $new_h ) =
        ( token_hash($presented), token_hash($successor) );
    my $outcome =
        SessionLab::Redis->run_script( $ROTATE, 3, "rt:{$family}:$old_h",
        "rtfam:{$family}", "rt:{$family}:$new_h",
        $new_h, $GRACE_MS, $REFRESH_TTL, );
    if ( $outcome eq 'rotated' || $outcome eq 'replay' ) {
        my $user = _redis()->hget( "rt:{$family}:$new_h", 'user' );
        my ($jwt) = issue_access_token( sub => $user, fam => $family );
        $c->res->header( 'X-Refresh-Outcome' => $outcome );
        return _json(
            $c, 200,
            {
                access_token  => $jwt,
                token_type    => 'Bearer',
                expires_in    => 300,
                refresh_token => $successor,
            }
        );
    }
    $c->log->warn("refresh token reuse detected; family $family revoked")
        if $outcome eq 'reuse';
    $c->res->header( 'X-Refresh-Outcome' => $outcome );
    _json(
        $c, 401,
        {
            error => $outcome eq 'reuse'
            ? 'refresh token reuse detected; all tokens in this family revoked'
            : 'invalid refresh token'
        }
    );
}

# Naive version for comparison: read, decide, write in separate commands,
# with a random successor. Concurrent duplicates fork the family.
sub refresh_naive : Path('refresh_naive') : Args(0) {
    my ( $self, $c ) = @_;
    my $presented = _body($c)->{refresh_token} // '';
    my $family    = family_of($presented)
        or return _json( $c, 400, { error => 'malformed refresh token' } );
    my $key = "rt:{$family}:" . token_hash($presented);
    my $r   = _redis();
    my ( $state, $user ) = $r->hmget( $key, 'state', 'user' );
    return _json( $c, 401, { error => 'invalid refresh token' } )
        unless ( $state // '' ) eq 'active';
    sleep( $c->req->params->{delay} // 0 );    # widen the race window
    my $successor = new_refresh($family);
    my $nh        = token_hash($successor);
    $r->hset( $key, state => 'used' );
    $r->hset( "rt:{$family}:$nh", state => 'active', user => $user );
    $r->expire( "rt:{$family}:$nh", $REFRESH_TTL );
    my ($jwt) = issue_access_token( sub => $user, fam => $family );
    _json( $c, 200, { access_token => $jwt, refresh_token => $successor } );
}

# ------------------------------------------------------------------ resources
# Bearer JWT (signature, algorithm, exp, iss, aud, then denylist and family)
# or an API key (hash lookup). Returns (user, credential description).
sub _principal {
    my ($c) = @_;
    my $r = _redis();
    if ( my ($jwt) =
        ( $c->req->header('Authorization') // '' ) =~ /\ABearer\s+(\S+)\z/ )
    {
        my $claims = eval { verify_access_token($jwt) } or return;
        return if $r->exists("jwt:deny:$claims->{jti}");    # logged out
        return if !$r->exists("rtfam:{$claims->{fam}}");    # family revoked
        return (
            $claims->{sub},
            {
                type => 'jwt',
                jti  => $claims->{jti},
                exp  => $claims->{exp},
                fam  => $claims->{fam}
            }
        );
    }
    if ( defined( my $key = $c->req->header('X-API-Key') ) ) {
        my $kid  = token_hash($key);
        my $user = $r->hget( "apikey:$kid", 'user' ) or return;
        return ( $user, { type => 'api_key', kid => $kid } );
    }
    return;
}

sub me : Path('me') : Args(0) {
    my ( $self, $c )    = @_;
    my ( $user, $cred ) = _principal($c)
        or return _json( $c, 401, { error => 'unauthenticated' } );
    _json( $c, 200, { user => $user, credential => $cred->{type} } );
}

sub logout : Path('logout') : Args(0) {
    my ( $self, $c )    = @_;
    my ( $user, $cred ) = _principal($c);
    return _json( $c, 401, { error => 'bearer token required' } )
        unless $user && $cred->{type} eq 'jwt';
    my $remaining = $cred->{exp} - time;

    # Deny this access token until it would have expired anyway ...
    _redis()
        ->set( "jwt:deny:$cred->{jti}", 1, 'EX',
        $remaining > 0 ? $remaining : 1 );

    # ... and revoke the refresh family so no new access tokens are minted.
    _redis()->del("rtfam:{$cred->{fam}}");
    _json( $c, 200, { logged_out => 1 } );
}

# Per-key fixed-window limit (same atomic script as the login limiter).
# Returns the count and the milliseconds left in the window.
# Redis executes the embedded Lua; Perl sends it as data.
my $RATE = <<'LUA';
local n = redis.call('INCR', KEYS[1])
if n == 1 then
    redis.call('PEXPIRE', KEYS[1], ARGV[1])
end
return { n, redis.call('PTTL', KEYS[1]) }
LUA

# Header syntax of draft-ietf-httpapi-ratelimit-headers-11 (structured fields):
#   RateLimit-Policy: "perkey";q=10;w=60     quota and window
#   RateLimit:        "perkey";r=3;t=41      remaining and seconds to reset
my ( $QUOTA, $WINDOW ) = ( 10, 60 );

sub limited : Path('limited') : Args(0) {
    my ( $self, $c )    = @_;
    my ( $user, $cred ) = _principal($c);
    return _json( $c, 401, { error => 'API key required' } )
        unless $user && $cred->{type} eq 'api_key';
    my ( $n, $pttl ) =
        @{ SessionLab::Redis->run_script( $RATE, 1,
            "ratelimit:api:$cred->{kid}", $WINDOW * 1000 )
        };
    my $reset = int( ( $pttl + 999 ) / 1000 );
    my $left  = $n >= $QUOTA ? 0 : $QUOTA - $n;
    $c->res->header(
        'RateLimit-Policy' => qq{"perkey";q=$QUOTA;w=$WINDOW} );
    $c->res->header( 'RateLimit' => qq{"perkey";r=$left;t=$reset} );

    if ( $n > $QUOTA ) {
        $c->res->header( 'Retry-After' => $reset );
        return _json( $c, 429, { error => 'rate limit exceeded' } );
    }
    _json( $c, 200, { ok => 1, used => $n } );
}

# Signed requests: verify the signature FIRST, then record the nonce, so an
# attacker cannot burn a legitimate client's nonces with forged requests.
sub signed : Path('signed') : Args(0) {
    my ( $self, $c ) = @_;
    my $kid   = $c->req->header('X-Key-Id')    // '';
    my $ts    = $c->req->header('X-Timestamp') // '';
    my $nonce = $c->req->header('X-Nonce')     // '';
    my $sig   = $c->req->header('X-Signature') // '';
    return _json( $c, 401, { error => 'unknown key' } )
        unless $kid =~ /\A[0-9a-f]{64}\z/
        && _redis()->exists("apikey:$kid");
    return _json( $c, 401, { error => 'stale or future timestamp' } )
        unless $ts =~ /\A\d+\z/ && abs( time - $ts ) <= $SKEW;
    return _json( $c, 400, { error => 'bad nonce' } )
        unless $nonce =~ /\A[0-9a-f]{32}\z/;
    my $body   = _raw_body($c);
    my $secret = hmac_sha256_hex( $kid, $SIGNING_MASTER );
    my $expect =
        sign_request( $secret, $c->req->method, '/' . $c->req->path,
        $ts, $nonce, $body, );
    return _json( $c, 401, { error => 'bad signature' } )
        unless _secure_eq( $sig, $expect );
    _redis()->set( "nonce:$kid:$nonce", 1, 'NX', 'EX', 2 * $SKEW )
        or return _json( $c, 409, { error => 'replayed request' } );
    _json( $c, 200, { accepted => 1 } );
}

__PACKAGE__->meta->make_immutable;
1;
