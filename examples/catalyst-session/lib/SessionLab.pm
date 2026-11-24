package SessionLab;

# Catalyst application demonstrating Redis-backed sessions and request-level
# coordination: secure session IDs, fixation defense, lost-update races and
# their fixes, idempotency keys, rate limiting and logout-everywhere.
use Moose;
use namespace::autoclean;
use Catalyst::Runtime 5.80;
use Catalyst qw/
    Session
    Session::State::Cookie
    +SessionLab::Plugin::Session::Store::RedisSafe
    /;
use SessionLab::Redis;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

extends 'Catalyst';

__PACKAGE__->config(
    name                                        => 'SessionLab',
    disable_component_resolution_regex_fallback => 1,

   # Behind an ingress in another pod (Traefik, nginx), REMOTE_ADDR is not
   # 127.0.0.1, so Catalyst will not apply ReverseProxy by itself. Enable it
   # explicitly, and make sure only the proxy can reach the application:
   # X-Forwarded-* headers are trusted once this is on.
    using_frontend_proxy => $ENV{SESSIONLAB_BEHIND_PROXY} // 0,
    'Plugin::Session'    => {
        expires          => 3600,    # idle timeout in seconds
        expiry_threshold => 300,    # extend at most every 5 min: fewer writes
        redis_prefix    => 'sess:',
        cookie_name     => 'sessionlab_sid',
        cookie_httponly => 1,    # not readable from JavaScript
        cookie_samesite =>
            'Lax',    # basic CSRF mitigation for top-level POSTs
    # Production behind TLS: 1. Mode 2 relies on $c->req->secure, which is
    # false behind a TLS-terminating proxy unless ReverseProxy middleware
            # is applied. The laboratory runs over plain HTTP on loopback.
        cookie_secure => $ENV{SESSION_COOKIE_SECURE} // 0,
    },
);

# All security tokens come from the kernel CSPRNG, never from rand().
sub random_hex {
    my ( $c, $bytes ) = @_;
    open my $fh, '<:raw', '/dev/urandom' or die "urandom: $!";
    read( $fh, my $buf, $bytes ) == $bytes or die "short read from urandom";
    return unpack 'H*', $buf;
}

# Session IDs must be unpredictable. The plugin's default hashes a counter,
# time, rand(), the PID and an address: not a cryptographic source.
sub generate_session_id { $_[0]->random_hex(32) }    # 256 bits, hex

# ------------------------------------------------------------------------
# Per-session request lock. Catalyst::Plugin::Session loads the whole
# session on first access and writes the whole session back at the end of
# the request, so two concurrent requests in one session are a classic
# read-modify-write race. Actions that must mutate the session safely call
# lock_session() BEFORE their first $c->session access; the lock is released
# after the session has been saved, in finalize_session below.

# Redis executes the embedded Lua; Perl sends it as data.
my $RELEASE = <<'LUA';
if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('DEL', KEYS[1])
end
return 0
LUA

has _session_lock => ( is => 'rw', clearer => '_clear_session_lock' );

sub lock_session {
    my ( $c, %opt ) = @_;
    my $sid = $c->sessionid or return 1;    # no session yet: nothing to race
    my $key   = "slock:{$sid}";
    my $ttl   = $opt{ttl_ms} // 10_000;    # longer than any request
    my $wait  = $opt{wait_s} // 5;
    my $token = $c->random_hex(16);

    my $deadline = clock_gettime(CLOCK_MONOTONIC) + $wait;
    my $pause    = 0.005;
    until (
        SessionLab::Redis->handle->set( $key, $token, 'NX', 'PX', $ttl ) )
    {
        return 0 if clock_gettime(CLOCK_MONOTONIC) >= $deadline;
        sleep( $pause * ( 0.5 + rand ) );
        $pause *= 2 if $pause < 0.05;
    }
    $c->_session_lock( [ $key, $token ] );
    return 1;
}

sub finalize_session {
    my $c = shift;
    $c->next::method(@_);    # the session is written here
    if ( my $lock = $c->_session_lock ) {    # ... and only then unlocked
        $c->_clear_session_lock;
        eval { SessionLab::Redis->run_script( $RELEASE, 1, @$lock ); 1 }
            or $c->log->warn("session unlock failed: $@");
    }
}

__PACKAGE__->setup();

# Catalyst's default UTF-8 encoding runs binmode(STDERR, ':encoding(UTF-8)'),
# which silently makes STDERR buffered. Log lines then reach the container log
# late, in batches, and are lost if the worker is killed. Restore line-at-a-
# time delivery.
STDERR->autoflush(1);
1;
