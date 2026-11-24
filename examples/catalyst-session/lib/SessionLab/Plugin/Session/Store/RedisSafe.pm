package SessionLab::Plugin::Session::Store::RedisSafe;

# Hardened Redis session store for Catalyst::Plugin::Session.
#
# Differences from Catalyst::Plugin::Session::Store::Redis 0.900:
#   * value and TTL written by one atomic SET ... EX (no immortal sessions
#     if the process dies between SET and EXPIRE);
#   * Sereal with objects refused on both encode and decode, instead of
#     Storable thaw, so a forged record cannot instantiate Perl objects;
#   * undecodable records are discarded and logged, not fatal;
#   * no PING round trip before every command; fork-safe connection with
#     ACL credentials and TLS (see SessionLab::Redis);
#   * configurable key prefix for namespacing and ACL key patterns.
use strict;
use warnings;
use base 'Catalyst::Plugin::Session::Store';
use MRO::Compat;
use Sereal::Encoder;
use Sereal::Decoder;
use SessionLab::Redis;

my $ENCODER = Sereal::Encoder->new( { croak_on_bless => 1 } );
my $DECODER = Sereal::Decoder->new(
    {
        refuse_objects => 1,    # blessed data is rejected, never revived
        max_recursion_depth   => 64,
        max_num_hash_entries  => 10_000,
        max_num_array_entries => 10_000,
    }
);

sub _redis_key {
    my ( $c, $key ) = @_;    # $key: session:SID, expires:SID, flash:SID
    return ( $c->_session_plugin_config->{redis_prefix} // 'sess:' ) . $key;
}

sub get_session_data {
    my ( $c, $key ) = @_;
    my $raw = SessionLab::Redis->handle->get( _redis_key( $c, $key ) );
    return unless defined $raw;
    return $raw if $key =~ /^expires:/;    # plain epoch seconds
    my $data = eval { $DECODER->decode($raw) };
    unless ( defined $data ) {
        $c->log->warn("discarding undecodable session record '$key': $@");
        return;
    }
    return $data;
}

sub store_session_data {
    my ( $c, $key, $data ) = @_;

    # Expire every record together with the session it belongs to.
    my $ttl = $c->session_expires - time;
    $ttl = 1 if $ttl < 1;
    my $value = $key =~ /^expires:/ ? $data : $ENCODER->encode($data);
    SessionLab::Redis->handle->set( _redis_key( $c, $key ),
        $value, 'EX', $ttl );
    return;
}

sub delete_session_data {
    my ( $c, $key ) = @_;
    SessionLab::Redis->handle->del( _redis_key( $c, $key ) );
    return;
}

sub delete_expired_sessions { }    # Redis expires keys itself

1;
