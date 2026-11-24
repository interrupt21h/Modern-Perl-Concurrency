#!/usr/bin/env perl
use strict;
use warnings;
use DBI;
use File::Temp qw(tempdir);

my $dir = tempdir(CLEANUP => 1);
sub connect_db {
    my ($path) = @_;
    return DBI->connect(
        "dbi:SQLite:dbname=$path", '', '',
        { RaiseError => 1, PrintError => 0, AutoCommit => 1 },
    );
}

my $db = connect_db("$dir/source.db");
my $sink = connect_db("$dir/sink.db");
$db->do('CREATE TABLE record (
    id TEXT PRIMARY KEY, amount INTEGER NOT NULL)');
$db->do('CREATE TABLE outbox (
    id TEXT PRIMARY KEY, amount INTEGER NOT NULL,
    sent INTEGER NOT NULL DEFAULT 0)');
$sink->do('CREATE TABLE effect (
    id TEXT PRIMARY KEY, amount INTEGER NOT NULL)');

sub transaction {
    my ($dbh, $work) = @_;
    $dbh->begin_work;
    my $ok = eval { $work->(); $dbh->commit; 1 };
    return if $ok;
    my $error = $@;
    eval { $dbh->rollback unless $dbh->{AutoCommit} };
    die $error;
}

sub ingest {
    my ($dbh, $id, $amount, $fail) = @_;
    transaction($dbh, sub {
        $dbh->do(
            'INSERT INTO record VALUES (?, ?)
             ON CONFLICT(id) DO NOTHING',
            undef, $id, $amount,
        );
        my ($stored) = $dbh->selectrow_array(
            'SELECT amount FROM record WHERE id = ?', undef, $id
        );
        die "input ID reused with different payload"
            unless defined $stored && $stored == $amount;
        $dbh->do(
            'INSERT INTO outbox (id, amount) VALUES (?, ?)
             ON CONFLICT(id) DO NOTHING',
            undef, $id, $amount,
        );
        die "before source commit\n" if $fail;
    });
}

# Single relay: concurrent relays also need attempt-based claims.
sub relay_one {
    my ($db, $sink, $fail) = @_;
    my $event = $db->selectrow_hashref(
        'SELECT id, amount FROM outbox
         WHERE sent = 0 ORDER BY id LIMIT 1'
    );
    return 0 unless $event;
    transaction($sink, sub {
        $sink->do(
            'INSERT INTO effect VALUES (?, ?)
             ON CONFLICT(id) DO NOTHING',
            undef, $event->{id}, $event->{amount},
        );
        my ($stored) = $sink->selectrow_array(
            'SELECT amount FROM effect WHERE id = ?',
            undef, $event->{id},
        );
        die "event payload mismatch"
            unless defined $stored && $stored == $event->{amount};
    });
    die "after sink commit\n" if $fail;
    $db->do('UPDATE outbox SET sent = 1 WHERE id = ?',
        undef, $event->{id});
    return 1;
}

my $ok = eval { ingest($db, 'input:001', 42, 1); 1 };
die "expected injected failure" if $ok;
die "wrong failure: $@" unless $@ =~ /before source commit/;
die "partial source commit" if
    $db->selectrow_array('SELECT COUNT(*) FROM record')
    || $db->selectrow_array('SELECT COUNT(*) FROM outbox');

ingest($db, 'input:001', 42, 0);
ingest($db, 'input:001', 42, 0);
$ok = eval { ingest($db, 'input:001', 99, 0); 1 };
die "expected payload conflict" if $ok;
die "wrong conflict: $@" unless $@ =~ /different payload/;

$ok = eval { relay_one($db, $sink, 1); 1 };
die "expected relay failure" if $ok;
die "wrong failure: $@" unless $@ =~ /after sink commit/;
die "source should remain pending" unless
    $db->selectrow_array('SELECT sent FROM outbox') == 0;

relay_one($db, $sink, 0) or die "missing pending event";
die "unexpected pending work" if relay_one($db, $sink, 0);
die "duplicate effect" unless
    $sink->selectrow_array('SELECT COUNT(*) FROM effect') == 1;
die "wrong effect" unless
    $sink->selectrow_array('SELECT SUM(amount) FROM effect') == 42;
die "duplicate source" unless
    $db->selectrow_array('SELECT COUNT(*) FROM record') == 1;
print "source rollback, replay and ambiguous delivery verified\n";
