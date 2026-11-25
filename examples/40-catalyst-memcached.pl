#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use DBI;
use Digest::SHA qw(sha256_hex);
use HTTP::Tiny;
use IO::Socket::INET;
use JSON::PP qw(decode_json);
use Cache::Memcached::Fast;
use POSIX       qw(_exit);
use Time::HiRes qw(sleep time);
use File::Temp  qw(tempdir);
my $db = DBI->connect( $ENV{DB_DSN}, $ENV{DB_USER}, $ENV{DB_PASS},
    { RaiseError => 1, PrintError => 0, AutoCommit => 1 } );
my $app = "$FindBin::Bin/catalyst-memcached";
open my $schema, '<', "$app/schema.sql" or die $!;
{ local $/; $db->do($_) for grep /\S/, split /;/, <$schema>; }
open my $random, '<:raw', '/dev/urandom' or die $!;
read( $random, my $bytes, 64 ) == 64 or die 'random';
my ( $token, $reader ) = map { unpack 'H*', $_ }
    ( substr( $bytes, 0, 32 ), substr( $bytes, 32 ) );
my $principal = 'lab-' . substr( $token, 0, 24 );

for my $pair ( [ $token, 'write' ], [ $reader, 'read' ] ) {
    $db->do(
        'INSERT INTO mc_tokens VALUES (?,?,?,?)',
        undef, sha256_hex( $pair->[0] ),
        $principal, $pair->[1], int(time) + 600
    );
}
my $sock = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Listen    => 1
) or die $!;
my $port = $sock->sockport;
close $sock;
my $dir    = tempdir( CLEANUP => 1 );
my $parent = $$;
my $pid    = fork();
defined $pid or die $!;

if ( !$pid ) {
    open STDOUT, '>',  "$dir/server.log" or _exit(1);
    open STDERR, '>&', \*STDOUT          or _exit(1);
    exec 'starman', '--workers', 4, '--listen', "127.0.0.1:$port",
        "$app/app.psgi"
        or _exit(127);
}

END {
    if ( $$ == $parent && $pid ) {
        local $?;
        kill 'TERM', $pid;
        waitpid( $pid, 0 );
        eval {
            $db->do( 'DELETE FROM mc_orders WHERE principal=?',
                undef, $principal );
            $db->do( 'DELETE FROM mc_tokens WHERE principal=?',
                undef, $principal );
        };
    }
}
my $base = "http://127.0.0.1:$port";

sub request {
    my ( $method, $path, $bearer, $amount, $key ) = @_;
    my %h;
    $h{Authorization}     = "Bearer $bearer" if defined $bearer;
    $h{'Idempotency-Key'} = $key             if defined $key;
    my $http = HTTP::Tiny->new( timeout => 5 );
    return defined $amount
        ? $http->post_form(
        "$base$path",
        { amount  => $amount },
        { headers => \%h }
        )
        : $http->request( $method, "$base$path", { headers => \%h } );
}
sub check { die "FAILED: $_[1]\n" unless $_[0]; print "ok $_[1]\n"; }
my $until = time + 15;
while ( request( 'GET', '/' )->{status} != 200 ) {
    die 'server startup failed' if time > $until;
    sleep .1;
}
my $spec = request( 'GET', '/openapi.json' );
check(
    $spec->{status} == 200
        && decode_json( $spec->{content} )
        ->{components}{securitySchemes}{bearerAuth}{scheme} eq 'bearer',
    'live OpenAPI'
);
check( request( 'GET', '/whoami' )->{status} == 401, 'missing token' );
check( request( 'POST', '/counter', $reader )->{status} == 403,
    'read scope rejected' );
check( request( 'GET', '/whoami', $token )->{status} == 200,
    'authenticated identity' );

sub concurrent {
    my ( $path, $amount, $key ) = @_;
    my @pids;
    for my $i ( 1 .. 8 ) {
        my $child = fork();
        defined $child or die $!;
        if ( !$child ) {
            my $res = request( 'POST', $path, $token, $amount, $key );
            open my $fh, '>', "$dir/result-$i" or _exit(1);
            print {$fh} $res->{content};
            close $fh;
            _exit( $res->{status} == 200 ? 0 : 1 );
        }
        push @pids, $child;
    }
    for (@pids) { waitpid( $_, 0 ); die 'request failed' if $?; }
    return map {
        open my $fh, '<', "$dir/result-$_" or die $!;
        local $/;
        decode_json(<$fh>)
    } 1 .. 8;
}
my @values = sort { $a <=> $b } map { $_->{value} } concurrent('/counter');
check(
    "@values" eq '1 2 3 4 5 6 7 8',
    'CAS preserves concurrent increments'
);
concurrent( '/order', 25, 'one' );
my ($n) = $db->selectrow_array(
    'SELECT COUNT(*) FROM mc_orders WHERE principal=?',
    undef, $principal );
check( $n == 1, 'one durable order after eight submissions' );
check( request( 'POST', '/order', $token, 26, 'one' )->{status} == 409,
    'conflicting replay rejected' );
my $m = Cache::Memcached::Fast->new(
    { servers => [ $ENV{MEMCACHED_SERVER} ] } );
$m->delete("mclab:counter:$principal");
$m->delete( "mclab:rate:$principal:" . int( time / 60 ) );
check( request( 'POST', '/order', $token, 25, 'one' )->{status} == 200,
    'replay after cache loss' );
($n) = $db->selectrow_array(
    'SELECT COUNT(*) FROM mc_orders WHERE principal=?',
    undef, $principal );
check( $n == 1, 'durable invariant survives cache loss' );
check( request( 'POST', '/revoke', $token )->{status} == 200,
    'revoke token' );
check( request( 'GET', '/whoami', $token )->{status} == 401,
    'revocation enforced' );
print "Memcached Catalyst API: all checks passed\n";
