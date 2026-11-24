#!/usr/bin/env perl
# MySQL named advisory lock on a pinned, non-reconnecting session.
use strict;
use warnings;
use DBI;

my $dbh = DBI->connect(
    $ENV{DB_DSN},
    $ENV{DB_USER},
    $ENV{DB_PASS},
    {
        RaiseError           => 1,
        PrintError           => 0,
        AutoCommit           => 1,
        mysql_auto_reconnect =>
            0,    # reconnecting would silently drop the lock
    }
);

my $name = 'app:billing:customer:42';
die "lock name exceeds 64 characters\n" if length $name > 64;

# 1 = acquired, 0 = timed out, NULL = error.
my ($got) =
    $dbh->selectrow_array( 'SELECT GET_LOCK(?, ?)', undef, $name, 5 );
die "GET_LOCK error\n" unless defined $got;
die "lock timeout\n"   unless $got == 1;

my $ok = eval {

    # Protected work must run on this same session.
    my ($holder) =
        $dbh->selectrow_array( 'SELECT IS_USED_LOCK(?)', undef, $name );
    my ($self) = $dbh->selectrow_array('SELECT CONNECTION_ID()');
    die "lock not held by this session\n" unless $holder == $self;
    1;
};
my $err = $@;

# 1 = released, 0 = held by another session, NULL = no such lock.
my $released = eval {
    my ($r) =
        $dbh->selectrow_array( 'SELECT RELEASE_LOCK(?)', undef, $name );
    defined($r) && $r == 1;
};
my $release_err = $@;
$dbh->disconnect;
die "release failed: $release_err; work: $err" unless $released;
die $err                                       unless $ok;
print "advisory lock acquired, verified and released\n";
