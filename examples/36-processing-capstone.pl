#!/usr/bin/env perl
use strict;
use warnings;
use DBI;
use File::Temp qw(tempdir);
use POSIX qw(_exit);
use Time::HiRes qw(time);

my $dir = tempdir(CLEANUP => 1);
my $source = "$dir/source.db";
my $target = "$dir/target.db";
my $n = 48;
my $window = 12;
my $workers = 3;

sub connect_db {
    my ($path) = @_;
    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=$path", '', '',
        {
            RaiseError => 1, PrintError => 0, AutoCommit => 1,
            sqlite_use_immediate_transaction => 1,
        },
    );
    $dbh->sqlite_busy_timeout(5000);
    return $dbh;
}

sub tx {
    my ($dbh, $code) = @_;
    $dbh->begin_work;
    my $result;
    my $ok = eval { $result = $code->(); $dbh->commit; 1 };
    return $result if $ok;
    my $error = $@;
    eval { $dbh->rollback unless $dbh->{AutoCommit} };
    die $error;
}

sub setup {
    my $db = connect_db($source);
    $db->do('PRAGMA journal_mode=WAL');
    for my $table (qw(job outbox)) {
        $db->do("CREATE TABLE $table (
            id INTEGER PRIMARY KEY, value INTEGER NOT NULL,
            state TEXT NOT NULL DEFAULT 'ready',
            attempt INTEGER NOT NULL DEFAULT 0,
            lease_until REAL NOT NULL DEFAULT 0)");
    }
    $db->do('CREATE TABLE result (
        id INTEGER PRIMARY KEY, value INTEGER NOT NULL)');
    $db->disconnect;
    my $sink = connect_db($target);
    $sink->do('PRAGMA journal_mode=WAL');
    $sink->do('CREATE TABLE effect (
        id INTEGER PRIMARY KEY, value INTEGER NOT NULL)');
    $sink->disconnect;
}

sub ingest {
    my ($db, $id, $value) = @_;
    tx($db, sub {
        $db->do(
            'INSERT INTO job (id,value) VALUES (?,?)
             ON CONFLICT(id) DO NOTHING',
            undef, $id, $value,
        );
        my ($stored) = $db->selectrow_array(
            'SELECT value FROM job WHERE id=?', undef, $id,
        );
        die "divergent input" unless $stored == $value;
    });
}

# Only fixed, internal table names are accepted.
sub claim {
    my ($db, $table) = @_;
    die "invalid queue" unless $table eq 'job' || $table eq 'outbox';
    return tx($db, sub {
        my $now = time();
        my $row = $db->selectrow_hashref(
            "SELECT id,value,attempt FROM $table
             WHERE state='ready'
                OR (state='running' AND lease_until<=?)
             ORDER BY id LIMIT 1", undef, $now,
        );
        return undef unless $row;
        ++$row->{attempt};
        $db->do(
            "UPDATE $table SET state='running',attempt=?,
             lease_until=? WHERE id=?",
            undef, $row->{attempt}, $now + 60, $row->{id},
        );
        return $row;
    });
}

sub finish {
    my ($db, $job) = @_;
    my $value = 2 * $job->{value};
    return tx($db, sub {
        my $changed = $db->do(
            q{UPDATE job SET state='done',lease_until=0
              WHERE id=? AND attempt=? AND state='running'},
            undef, $job->{id}, $job->{attempt},
        );
        return 0 unless $changed == 1;
        $db->do('INSERT INTO result VALUES (?,?)',
            undef, $job->{id}, $value);
        $db->do('INSERT INTO outbox (id,value) VALUES (?,?)',
            undef, $job->{id}, $value);
        return 1;
    });
}

sub deliver {
    my ($db, $sink, $job, $fail) = @_;
    tx($sink, sub {
        $sink->do(
            'INSERT INTO effect VALUES (?,?)
             ON CONFLICT(id) DO NOTHING',
            undef, $job->{id}, $job->{value},
        );
        my ($stored) = $sink->selectrow_array(
            'SELECT value FROM effect WHERE id=?',
            undef, $job->{id},
        );
        die "divergent event" unless $stored == $job->{value};
    });
    die "injected lost acknowledgement\n" if $fail;
    my $changed = $db->do(
        q{UPDATE outbox SET state='done',lease_until=0
          WHERE id=? AND attempt=? AND state='running'},
        undef, $job->{id}, $job->{attempt},
    );
    return $changed == 1;
}

sub parallel {
    my ($count, $work) = @_;
    my @pids;
    for (1 .. $count) {
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if (!$pid) {
            my $ok = eval { $work->(); 1 };
            warn $@ unless $ok;
            _exit($ok ? 0 : 1);
        }
        push @pids, $pid;
    }
    my $failed = 0;
    for my $pid (@pids) {
        my $waited = waitpid($pid, 0);
        $failed = 1 if $waited != $pid || $? != 0;
    }
    die "worker failed" if $failed;
}

sub drain_jobs {
    parallel($workers, sub {
        my $db = connect_db($source);
        while (my $job = claim($db, 'job')) {
            finish($db, $job) or die "unexpected stale attempt";
        }
        $db->disconnect;
    });
}

sub drain_outbox {
    parallel($workers, sub {
        my $db = connect_db($source);
        my $sink = connect_db($target);
        while (my $job = claim($db, 'outbox')) {
            deliver($db, $sink, $job, 0)
                or die "unexpected stale delivery";
        }
        $sink->disconnect;
        $db->disconnect;
    });
}

setup();
my $db = connect_db($source);
ingest($db, 1, 1);
ingest($db, 1, 1);
my $ok = eval { ingest($db, 1, 999); 1 };
die "divergent input accepted" if $ok || $@ !~ /divergent input/;
$db->disconnect;
undef $db;

# Actual worker termination after a durable claim.
my $pid = fork();
die "fork: $!" unless defined $pid;
if (!$pid) {
    my $child = connect_db($source);
    my $job = claim($child, 'job');
    _exit($job && $job->{id} == 1 ? 17 : 1);
}
waitpid($pid, 0) == $pid or die "waitpid";
die "crash fixture failed" unless $? == (17 << 8);

$db = connect_db($source);
my $stale = $db->selectrow_hashref(
    'SELECT id,value,attempt FROM job WHERE id=1',
);
# Advance the persisted deadline explicitly for deterministic recovery.
$db->do('UPDATE job SET lease_until=0 WHERE id=1');
my $new = claim($db, 'job');
die "claim not reclaimed" unless $new->{attempt} > $stale->{attempt};
die "stale completion accepted" if finish($db, $stale);
finish($db, $new) or die "new completion rejected";
$db->disconnect;
undef $db;

for (my $start = 2; $start <= $n; $start += $window) {
    my $end = $start + $window - 1;
    $end = $n if $end > $n;
    $db = connect_db($source);
    for my $id ($start .. $end) {
        ingest($db, $id, $id);
    }
    my ($pending) = $db->selectrow_array(
        q{SELECT COUNT(*) FROM job WHERE state<>'done'},
    );
    die "admission bound exceeded" if $pending > $window;
    $db->disconnect;
    undef $db;
    drain_jobs();
}

$db = connect_db($source);
my $sink = connect_db($target);
my $event = claim($db, 'outbox');
$ok = eval { deliver($db, $sink, $event, 1); 1 };
die "failure injection missing"
    if $ok || $@ !~ /injected lost acknowledgement/;
$db->do('UPDATE outbox SET lease_until=0 WHERE id=?',
    undef, $event->{id});
$sink->disconnect;
$db->disconnect;
undef $sink;
undef $db;
drain_outbox();

$db = connect_db($source);
$sink = connect_db($target);
ingest($db, 1, 1);
my $expected = $n * ($n + 1);
my ($count, $sum) = $db->selectrow_array(
    'SELECT COUNT(*),SUM(value) FROM result',
);
die "result invariant" unless $count == $n && $sum == $expected;
my ($effects, $total) = $sink->selectrow_array(
    'SELECT COUNT(*),SUM(value) FROM effect',
);
die "delivery invariant" unless $effects == $n && $total == $expected;
for my $table (qw(job outbox)) {
    my ($pending) = $db->selectrow_array(
        "SELECT COUNT(*) FROM $table WHERE state<>'done'",
    );
    die "unfinished $table" if $pending;
}
print "capstone: $count results, $effects effects, sum $sum\n";
$sink->disconnect;
$db->disconnect;
