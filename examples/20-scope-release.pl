#!/usr/bin/env perl
# Release on every exit path: a scope guard owns the lock handle, so an
# exception inside the critical section still releases the flock.
use strict;
use warnings;
use Fcntl      qw(:DEFAULT :flock);
use File::Temp qw(tempdir);

package LockGuard {
    use Fcntl qw(:DEFAULT :flock);

    sub acquire {
        my ( $class, $path ) = @_;
        sysopen( my $fh, $path, O_CREAT | O_RDWR, 0600 ) or die "open: $!";
        flock( $fh, LOCK_EX )                            or die "flock: $!";
        return bless { fh => $fh, pid => $$ }, $class;
    }

    sub release {
        my ($self) = @_;
        my $fh     = delete $self->{fh} or return;    # idempotent
        close($fh) or warn "close: $!";    # closing drops the flock
    }

    # Only the creating process releases: a forked child inherits the open
    # file description, and its exit must not drop the parent's lock.
    sub DESTROY { my ($self) = @_; $self->release if $self->{pid} == $$ }
}

my $path = tempdir( CLEANUP => 1 ) . '/demo.lock';

sub locked_ok_without_waiting {
    sysopen( my $probe, $path, O_CREAT | O_RDWR, 0600 ) or die "open: $!";
    my $got = flock( $probe, LOCK_EX | LOCK_NB );
    close $probe;
    return $got;
}

# 1. Exception inside the critical section.
my $ok = eval {
    my $guard = LockGuard->acquire($path);
    die "simulated failure\n";
};
die "expected the failure to propagate\n"
    if $ok || $@ ne "simulated failure\n";
die "lock leaked after exception\n" unless locked_ok_without_waiting();

# 2. While held, an independent open file description must be refused.
{
    my $guard = LockGuard->acquire($path);
    die "exclusion failed\n" if locked_ok_without_waiting();
    $guard->release;    # explicit early release
    die "explicit release failed\n" unless locked_ok_without_waiting();
}
print "lock released on exception and on explicit release\n";
