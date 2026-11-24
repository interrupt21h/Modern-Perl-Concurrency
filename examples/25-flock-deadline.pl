#!/usr/bin/env perl
# flock with a deadline. flock() has no timeout of its own, so poll with
# LOCK_NB, a monotonic clock and jittered backoff. A child process holds the
# lock while the parent first times out, then waits long enough to succeed.
use strict;
use warnings;
use Errno       qw(EAGAIN EWOULDBLOCK EINTR);
use Fcntl       qw(:DEFAULT :flock);
use File::Temp  qw(tempdir);
use POSIX       qw(_exit);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

sub now { clock_gettime(CLOCK_MONOTONIC) }

# Returns true when acquired, false on timeout; dies on real errors.
sub flock_deadline {
    my ( $fh, $mode, $timeout ) = @_;
    my $deadline = now() + $timeout;
    my $pause    = 0.005;
    until ( flock( $fh, $mode | LOCK_NB ) ) {
        die "flock: $!\n"
            unless $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
        my $left = $deadline - now();
        return 0 if $left <= 0;
        sleep( ( $pause < $left ? $pause : $left ) * ( 0.5 + rand ) )
            ;    # jitter
        $pause *= 2 if $pause < 0.1;    # capped backoff
    }
    return 1;
}

sub open_lockfile {
    my ($path) = @_;
    sysopen( my $fh, $path, O_CREAT | O_RDWR, 0600 )
        or die "open $path: $!\n";
    return $fh;
}

# Use a private directory: never a world-writable one such as /tmp itself.
my $dir  = $ENV{LOCK_DIR} // tempdir( CLEANUP => 1 );
my $path = "$dir/nightly-report.lock";
my $HOLD = 0.6;

pipe( my $ready_r, my $ready_w ) or die "pipe: $!\n";
defined( my $pid = fork() )      or die "fork: $!\n";
if ( !$pid ) {    # child: hold the lock briefly
    close $ready_r;
    my $fh = open_lockfile($path);    # own open file description
    flock( $fh, LOCK_EX ) or _exit(1);
    syswrite $ready_w, "1";    # tell the parent it is held
    sleep($HOLD);
    close $fh;    # release
    _exit(0);
}
close $ready_w;
sysread( $ready_r, my $byte, 1 ) == 1 or die "child failed to lock\n";
my $held_since = now();

my $fh = open_lockfile($path);

# 1. A short deadline expires while the child holds the lock.
my $t0     = now();
my $got    = flock_deadline( $fh, LOCK_EX, 0.2 );
my $waited = now() - $t0;
die "acquired a lock that was held\n" if $got;
die sprintf( "timeout not honored (%.3fs)\n", $waited )
    if $waited < 0.19
    || $waited > 0.45;

# 2. A longer deadline succeeds once the child releases.
$got = flock_deadline( $fh, LOCK_EX, 5 );
my $acquired_after = now() - $held_since;
die "did not acquire after release\n" unless $got;
die "acquired before the holder released\n"
    if $acquired_after < $HOLD - 0.05;
close $fh;

waitpid( $pid, 0 );
die "child failed\n" if $?;

# 3. Shared locks coexist; an exclusive request is refused meanwhile.
my ( $r1, $r2, $w ) = map { open_lockfile($path) } 1 .. 3;
flock_deadline( $r1, LOCK_SH, 1 ) && flock_deadline( $r2, LOCK_SH, 1 )
    or die "shared locks should coexist\n";
die "exclusive granted beside readers\n"
    if flock_deadline( $w, LOCK_EX, 0.1 );
close $_ for $r1, $r2, $w;

printf
"timed out after %.2fs; acquired %.2fs after holder locked; shared OK\n",
    $waited, $acquired_after;
