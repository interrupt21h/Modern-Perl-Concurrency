package SessionLab::Tokens;
# Credential primitives for the API laboratory: random tokens, at-rest
# hashing, deterministic refresh successors, JWT access tokens and HMAC
# request signatures. Secrets come from the environment; the defaults exist
# only so the laboratory runs out of the box.
use strict;
use warnings;
use Crypt::JWT qw(encode_jwt decode_jwt);
use Digest::SHA qw(sha256_hex hmac_sha256_hex);
use Exporter 'import';

our @EXPORT_OK = qw(random_hex token_hash new_api_key new_family new_refresh
    successor_of family_of issue_access_token verify_access_token sign_request);

my $JWT_KEY     = $ENV{SESSIONLAB_JWT_KEY}     // 'lab-only-jwt-key-change-me-0123456789abcdef';
my $REFRESH_KEY = $ENV{SESSIONLAB_REFRESH_KEY} // 'lab-only-refresh-key-change-me-0123456789';
my $ISSUER      = 'https://sessionlab.example/';
my $AUDIENCE    = 'sessionlab-api';
my $ACCESS_TTL  = 300;                       # five minutes

sub random_hex {
    my ($bytes) = @_;
    open my $fh, '<:raw', '/dev/urandom' or die "urandom: $!";
    read($fh, my $buf, $bytes) == $bytes or die "short read from urandom";
    return unpack 'H*', $buf;
}

# Tokens are 256-bit random values, so a fast hash is the right choice:
# slow password hashes (bcrypt, Argon2) exist for low-entropy secrets.
sub token_hash { sha256_hex($_[0]) }

# A recognizable prefix lets secret scanners and log filters find leaked keys.
sub new_api_key { 'slk_' . random_hex(32) }

# Refresh tokens carry their family ID in clear text ("family.secret") so the
# server can build Redis keys with a {family} hash tag without a lookup.
sub new_family  { random_hex(8) }
sub new_refresh { my ($family) = @_; "$family." . random_hex(32) }
sub family_of   { my ($t) = @_; $t =~ /\A([0-9a-f]{16})\.[0-9a-f]{64}\z/ ? $1 : undef }

# The successor of a refresh token is a keyed hash of it. Duplicate refresh
# requests within the grace window therefore receive the same successor
# without the server ever storing a plaintext token.
sub successor_of {
    my ($token) = @_;
    my $family = family_of($token) // die "malformed refresh token\n";
    return "$family." . hmac_sha256_hex($token, $REFRESH_KEY);
}

sub issue_access_token {
    my (%claims) = @_;                       # sub, fam
    my $now = time;
    my %payload = (%claims, iss => $ISSUER, aud => $AUDIENCE,
        iat => $now, exp => $now + $ACCESS_TTL, jti => random_hex(16));
    # typ "at+jwt" marks this as an access token (RFC 9068), so an ID token
    # or any other JWT signed with the same key cannot be replayed here.
    return (encode_jwt(payload => \%payload, alg => 'HS256', key => $JWT_KEY,
                       extra_headers => { typ => 'at+jwt' }),
            \%payload);
}

# Pin the algorithm, REQUIRE exp (Crypt::JWT checks exp only when the claim
# is present unless verify_exp => 1 is passed) and check the explicit type,
# which Crypt::JWT does not verify on its own.
sub verify_access_token {
    my ($jwt) = @_;
    my ($header, $claims) = decode_jwt(
        token          => $jwt,
        key            => $JWT_KEY,
        accepted_alg   => 'HS256',
        verify_exp     => 1,
        verify_iss     => $ISSUER,
        verify_aud     => $AUDIENCE,
        leeway         => 30,                # tolerate small clock skew
        decode_header  => 1,
    );
    die "not an access token\n" unless lc($header->{typ} // '') eq 'at+jwt';
    return $claims;
}

# Signature over method, path, timestamp, nonce and body.
sub sign_request {
    my ($secret, $method, $path, $ts, $nonce, $body) = @_;
    return hmac_sha256_hex(join("\n", $method, $path, $ts, $nonce,
        $body // ''), $secret);
}

1;
