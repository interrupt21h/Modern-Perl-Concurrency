package MemcachedLab::Controller::Root;
use Moose;
use namespace::autoclean;
use Cache::Memcached::Fast;
use DBI;
use Digest::SHA    qw(sha256_hex);
use JSON::PP       qw(encode_json);
use Time::HiRes    qw(sleep clock_gettime CLOCK_MONOTONIC);
use File::Basename qw(dirname);
use File::Spec;
BEGIN { extends 'Catalyst::Controller' }
__PACKAGE__->config( namespace => '' );

sub reply {
    my ( $c, $status, $data ) = @_;
    $c->res->status($status);
    $c->res->content_type('application/json');
    $c->res->header( 'Cache-Control'    => 'no-store' );
    $c->res->header( 'WWW-Authenticate' => 'Bearer' ) if $status == 401;
    $c->res->body( encode_json($data) );
}

sub db {
    return DBI->connect( $ENV{DB_DSN}, $ENV{DB_USER}, $ENV{DB_PASS},
        { RaiseError => 1, PrintError => 0, AutoCommit => 1 } );
}

sub cache {
    return Cache::Memcached::Fast->new(
        {
            servers => [ $ENV{MEMCACHED_SERVER} // '127.0.0.1:11211' ],
            connect_timeout => 1,
            io_timeout      => 1,
            max_failures    => 0,
        }
    );
}

sub auth {
    my ( $c, $db, $write ) = @_;
    my $header = $c->req->header('Authorization') // '';
    unless ( $header =~ /\ABearer ([a-f0-9]{64})\z/ ) {
        reply( $c, 401, { error => 'invalid_token' } );
        return;
    }
    my $hash = sha256_hex($1);
    my $row  = $db->selectrow_hashref(
'SELECT principal, scope FROM mc_tokens WHERE token_hash=? AND expires_at>?',
        undef, $hash, time
    );
    unless ($row) {
        reply( $c, 401, { error => 'invalid_token' } );
        return;
    }
    if ( $write && $row->{scope} ne 'write' ) {
        reply( $c, 403, { error => 'insufficient_scope' } );
        return;
    }
    $row->{hash} = $hash;
    return $row;
}

sub method {
    my ( $c, $wanted ) = @_;
    return 1 if $c->req->method eq $wanted;
    $c->res->header( Allow => $wanted );
    reply( $c, 405, { error => 'method_not_allowed' } );
    return;
}

sub index : Path('/') Args(0) {
    my ( $self, $c ) = @_;
    reply( $c, 200, { openapi => '/openapi.json' } );
}

sub spec : Path('/openapi.json') Args(0) {
    my ( $self, $c ) = @_;
    return unless method( $c, 'GET' );
    my $path = File::Spec->catfile( dirname(__FILE__), '..', '..', '..',
        'openapi.json' );
    open my $fh, '<:raw', $path or die "spec: $!";
    local $/;
    $c->res->content_type('application/json');
    $c->res->body(<$fh>);
}

sub whoami : Path('/whoami') Args(0) {
    my ( $self, $c ) = @_;
    return unless method( $c, 'GET' );
    my $a = auth( $c, db(), 0 ) or return;
    reply( $c, 200,
        { principal => $a->{principal}, scope => $a->{scope} } );
}

sub revoke : Path('/revoke') Args(0) {
    my ( $self, $c ) = @_;
    return unless method( $c, 'POST' );
    my $db = db();
    my $a  = auth( $c, $db, 0 ) or return;
    $db->do( 'DELETE FROM mc_tokens WHERE token_hash=?', undef,
        $a->{hash} );
    reply( $c, 200, { revoked => JSON::PP::true } );
}

sub counter : Path('/counter') Args(0) {
    my ( $self, $c ) = @_;
    return unless method( $c, 'POST' );
    my $a        = auth( $c, db(), 1 ) or return;
    my $m        = cache();
    my $key      = 'mclab:counter:' . $a->{principal};
    my $deadline = clock_gettime(CLOCK_MONOTONIC) + 2;
    for ( 1 .. 50 ) {
        last if clock_gettime(CLOCK_MONOTONIC) >= $deadline;
        my $entry = $m->gets($key);
        if ($entry) {
            my $next = $entry->[1] + 1;
            if ( $m->cas( $key, $entry->[0], "$next", 300 ) ) {
                reply( $c, 200, { value => $next } );
                return;
            }
        }
        elsif ( $m->add( $key, '1', 300 ) ) {
            reply( $c, 200, { value => 1 } );
            return;
        }
        sleep( 0.005 + rand(0.015) );
    }
    reply( $c, 503, { error => 'cache_unavailable_or_contended' } );
}

sub order : Path('/order') Args(0) {
    my ( $self, $c ) = @_;
    return unless method( $c, 'POST' );
    my $db     = db();
    my $a      = auth( $c, $db, 1 ) or return;
    my $key    = $c->req->header('Idempotency-Key') // '';
    my $amount = $c->req->body_parameters->{amount} // '';
    unless ( $key =~ /\A[A-Za-z0-9_-]{1,64}\z/
        && $amount =~ /\A[1-9][0-9]{0,5}\z/ )
    {
        reply( $c, 400, { error => 'invalid_request' } );
        return;
    }
    my $m    = cache();
    my $rate = 'mclab:rate:' . $a->{principal} . ':' . int( time / 60 );
    $m->add( $rate, '0', 120 );
    my $count = $m->incr( $rate, 1 );
    unless ( defined $count ) {
        reply( $c, 503, { error => 'cache_unavailable' } );
        return;
    }
    if ( $count > 100 ) {
        reply( $c, 429, { error => 'rate_limited' } );
        return;
    }
    $db->do(
'INSERT INTO mc_orders (principal,request_key,amount) VALUES (?,?,?) ON DUPLICATE KEY UPDATE request_key=request_key',
        undef, $a->{principal}, $key, $amount
    );
    my ($stored) = $db->selectrow_array(
        'SELECT amount FROM mc_orders WHERE principal=? AND request_key=?',
        undef, $a->{principal}, $key
    );
    if ( $stored != $amount ) {
        reply( $c, 422, { error => 'idempotency_conflict' } );
        return;
    }
    reply( $c, 200, { request_key => $key, amount => 0 + $stored } );
}
__PACKAGE__->meta->make_immutable;
1;
