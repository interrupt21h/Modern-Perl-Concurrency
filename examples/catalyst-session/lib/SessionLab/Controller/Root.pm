package SessionLab::Controller::Root;
use Moose;
use namespace::autoclean;
use JSON::PP    ();
use Digest::SHA qw(sha256_hex);
use Time::HiRes qw(sleep);
use SessionLab::Redis;

BEGIN { extends 'Catalyst::Controller' }
__PACKAGE__->config( namespace => '' );

my $JSON = JSON::PP->new->canonical;
my %USERS =
    ( alice => 'correct horse', bob => 'battery staple' );    # lab only
my $SESSION_TTL = 3600;

sub _json {
    my ( $c, $status, $data ) = @_;
    $c->res->status($status);
    $c->res->content_type('application/json');
    $c->res->body( $JSON->encode($data) );
}

sub _redis { SessionLab::Redis->handle }

sub index : Path :
    Args(0) { my ( $self, $c ) = @_; _json( $c, 200, { ok => 1 } ) }

# ------------------------------------------------------------------ login
# Fixed-window attempt counter: INCR and the window's expiry in one script,
# so a crash can never leave a counter without a TTL (a permanent lockout).
# Redis executes the embedded Lua; Perl sends it as data.
my $RATE = <<'LUA';
local n = redis.call('INCR', KEYS[1])
if n == 1 then redis.call('PEXPIRE', KEYS[1], ARGV[1]) end
return n
LUA

sub login : Local : Args(0) {
    my ( $self, $c ) = @_;
    my $user = $c->req->params->{user}     // '';
    my $pass = $c->req->params->{password} // '';
    return _json( $c, 405, { error => 'POST required' } )
        unless $c->req->method eq 'POST';

    my $attempts = SessionLab::Redis->run_script( $RATE, 1,
        'ratelimit:login:' . lc $user, 60_000 );
    if ( $attempts > 5 ) {
        $c->res->header( 'Retry-After' => 60 );
        return _json( $c, 429, { error => 'too many attempts' } );
    }
    # Lab-only fixed credentials: production must verify a password hash
    # using a vetted password-verification library, not compare plaintext.
    return _json( $c, 401, { error => 'invalid credentials' } )
        unless exists $USERS{$user} && $USERS{$user} eq $pass;

    # Session fixation defense: an identifier issued before authentication
    # must never survive it. change_session_id copies the data to a fresh
    # ID and deletes the old records.
    my $before = $c->sessionid;
    $c->change_session_id if $before;
    $c->session->{user} = $user;
    $c->session->{csrf} = $c->random_hex(16);    # never rand() for tokens
    my $sid = $c->sessionid;

    # Index sessions per user so they can all be revoked together.
    SessionLab::Redis->run_script(
        q{
        redis.call('SADD', KEYS[1], ARGV[1])
        redis.call('EXPIRE', KEYS[1], ARGV[2])
        return 1
    }, 1, "user-sessions:$user", $sid, $SESSION_TTL
    );
    _redis()->del( "ratelimit:login:" . lc $user );
    _json( $c, 200, { user => $user, rotated => ( $before ? 1 : 0 ) } );
}

sub whoami : Local : Args(0) {
    my ( $self, $c ) = @_;
    my $user = $c->sessionid ? $c->session->{user} : undef;
    return _json( $c, 401, { error => 'not logged in' } ) unless $user;
    _json( $c, 200, { user => $user } );
}

sub logout_everywhere : Local : Args(0) {
    my ( $self, $c ) = @_;
    my $user = $c->sessionid ? $c->session->{user} : undef;
    return _json( $c, 401, { error => 'not logged in' } ) unless $user;
    my @sids = _redis()->smembers("user-sessions:$user");
    my $prefix = $c->_session_plugin_config->{redis_prefix} // 'sess:';
    _redis()->del(
        map {
            ( "${prefix}session:$_", "${prefix}expires:$_", "${prefix}flash:$_" )
        } @sids
    );
    _redis()->del("user-sessions:$user");
    $c->delete_session('logout everywhere');
    _json( $c, 200, { revoked => scalar @sids } );
}

# ------------------------------------------------------------------ carts
# 1. Naive: read-modify-write of the session blob. Concurrent requests in
#    the same session overwrite each other's changes at finalize time.
sub cart_naive : Local : Args(1) {
    my ( $self, $c, $item ) = @_;
    my $cart = $c->session->{cart} //= {};
    my $seen = $cart->{$item} // 0;
    sleep( $c->req->params->{delay} // 0 );    # widen the race window
    $c->session->{cart} = { %$cart, $item => $seen + 1 };
    _json( $c, 200, { $item => $seen + 1 } );
}

# 2. Atomic: keep mutable per-user state OUT of the session blob, in a
#    Redis hash updated by a single atomic command, expiring with the session.
sub cart_atomic : Local : Args(1) {
    my ( $self, $c, $item ) = @_;
    my $sid = $c->sessionid
        // do { $c->session->{created} = time; $c->sessionid };
    sleep( $c->req->params->{delay} // 0 );
    my $n = SessionLab::Redis->run_script(
        q{
        local n = redis.call('HINCRBY', KEYS[1], ARGV[1], 1)
        redis.call('EXPIRE', KEYS[1], ARGV[2])
        return n
    }, 1, "cart:{$sid}", $item, $SESSION_TTL
    );
    _json( $c, 200, { $item => $n } );
}

# 3. Locked: serialize session-mutating requests per session. Correct, but
#    every request in the session now waits its turn.
sub cart_locked : Local : Args(1) {
    my ( $self, $c, $item ) = @_;
    $c->lock_session
        or return _json( $c, 503, { error => 'session busy' } );
    my $cart = $c->session->{cart} //= {};    # first access: after lock
    my $seen = $cart->{$item} // 0;
    sleep( $c->req->params->{delay} // 0 );
    $c->session->{cart} = { %$cart, $item => $seen + 1 };
    _json( $c, 200, { $item => $seen + 1 } );
}

sub cart : Local : Args(0) {
    my ( $self, $c ) = @_;
    my $sid    = $c->sessionid;
    my %atomic = $sid ? _redis()->hgetall("cart:{$sid}") : ();
    _json(
        $c, 200,
        {
            session => ( $sid ? $c->session->{cart} // {} : {} ),
            atomic  => \%atomic
        }
    );
}

# ------------------------------------------------------------------ payments
# Idempotency keys: a retried or double-submitted request with the same key
# performs the side effect once and replays the stored response.
# A simulated provider ledger, separate from the expiring admission claim.
# Single Redis instance, no eviction; intentionally retained until test cleanup.
# Production must use the actual provider's durable idempotency contract.
my $PROVIDER = <<'LUA';
local prior = redis.call('HGET', KEYS[1], 'fp')
if prior then
    if prior ~= ARGV[1] then return {0, 0} end
    return {1, tonumber(redis.call('HGET', KEYS[1], 'number'))}
end
local n = redis.call('INCR', KEYS[2])
redis.call('HSET', KEYS[1], 'fp', ARGV[1], 'number', n)
return {1, n}
LUA

my $COMPLETE = <<'LUA';
if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
redis.call('SET', KEYS[1], ARGV[2], 'EX', 86400)
return 1
LUA
my $RELEASE_CLAIM = <<'LUA';
if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('DEL', KEYS[1])
end
return 0
LUA

sub pay : Local : Args(0) {
    my ( $self, $c ) = @_;
    my $user = $c->sessionid ? $c->session->{user} : undef;
    return _json( $c, 401, { error => 'not logged in' } ) unless $user;
    my $idem = $c->req->header('Idempotency-Key') // '';
    return _json( $c, 400, { error => 'Idempotency-Key required' } )
        unless $idem =~ /\A[A-Za-z0-9_-]{16,64}\z/;

    my $amount      = $c->req->params->{amount} // 0;
    my $fingerprint = sha256_hex( join "\0", $user, $amount );
    my $key         = "idem:$user:$idem";    # scoped per user

    # A short TTL while pending: if this worker dies mid-request, the key
    # frees itself in two minutes instead of blocking retries for a day.
    my $pending = $JSON->encode({
        state => 'pending', fp => $fingerprint, owner => $c->random_hex(16)
    });
    my $claimed = _redis()->set($key, $pending, 'NX', 'EX', 120);
    unless ($claimed) {
        my $prior =
            $JSON->decode( _redis()->get($key) // '{"state":"pending"}' );
        return _json( $c, 422,
            { error => 'key reused with a different request' } )
            if defined $prior->{fp} && $prior->{fp} ne $fingerprint;
        if ( $prior->{state} eq 'pending' ) {
            $c->res->header( 'Retry-After' => 1 );
            return _json( $c, 409, { error => 'request in progress' } );
        }
        $c->res->header( 'Idempotent-Replayed' => 'true' );
        return _json( $c, $prior->{status}, $prior->{body} );
    }

    my ( $status, $body ) = eval {
        sleep(0.2);
        my ($matched, $n) = @{ SessionLab::Redis->run_script(
            $PROVIDER, 2, "charges:$user:$idem", "charges:$user", $fingerprint
        ) };
        if (!$matched) {
            return (422, { error => 'key reused with a different request' });
        }
    # Laboratory fault injection: die abruptly after the side effect and
    # before the response is stored, as an OOM kill or node loss would.
        kill 'KILL', $$
            if $ENV{SESSIONLAB_FAULTS} && $c->req->params->{crash};
        ( 201, { charged => $amount, charge_no => $n } );
    };
    unless ($status) {
        # A transport error may have followed a committed provider operation.
        # Preserve the claim until expiration; reconciliation uses the same key.
        return _json( $c, 502, { error => 'payment outcome unknown' } );
    }

    if ($status == 422) {
        SessionLab::Redis->run_script($RELEASE_CLAIM, 1, $key, $pending);
        return _json($c, $status, $body);
    }

    # Completed: keep the stored response for 24 hours of safe retries.
    my $saved = SessionLab::Redis->run_script(
        $COMPLETE, 1, $key, $pending,
        $JSON->encode(
            {
                state  => 'done',
                fp     => $fingerprint,
                status => $status,
                body   => $body
            }
        )
    );
    $c->log->warn('payment response not cached: claim expired or ownership changed') unless $saved;
    _json( $c, $status, $body );
}

sub charges : Local : Args(0) {
    my ( $self, $c ) = @_;
    my $user = $c->sessionid ? $c->session->{user} : undef;
    return _json( $c, 401, { error => 'not logged in' } ) unless $user;
    _json( $c, 200, { charges => _redis()->get("charges:$user") // 0 } );
}

sub default : Path {
    my ( $self, $c ) = @_;
    _json( $c, 404, { error => 'not found' } )
}

__PACKAGE__->meta->make_immutable;
1;
