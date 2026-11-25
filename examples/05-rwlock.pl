use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep);
my $gate    : shared;
my $readers : shared = 0;
my $writer  : shared = 0;
my $waiting : shared = 0;
my $value   : shared = 0;
my $probe : shared;
my $active_readers : shared = 0;
my $active_writer : shared = 0;

sub acquire_read {
    lock($gate);
    cond_wait($gate) while $writer || $waiting;
    ++$readers;
}

sub release_read {
    lock($gate);
    --$readers;
    cond_broadcast($gate) unless $readers;
}

sub acquire_write {
    lock($gate);
    ++$waiting;
    cond_wait($gate) while $writer || $readers;
    --$waiting;
    $writer = 1;
}

sub release_write {
    lock($gate);
    $writer = 0;
    cond_broadcast($gate);
}

sub with_rw {
    my ( $write, $code ) = @_;
    $write ? acquire_write() : acquire_read();
    my $result;
    my $ok  = eval { $result = $code->(); 1 };
    my $err = $@;
    $write ? release_write() : release_read();
    die $err unless $ok;
    return $result;
}
my @t;
push @t, threads->create(
    sub {
        for (1 .. 500) {
            with_rw(1, sub {
                { lock($probe); die "writer overlap\n" if $active_writer || $active_readers; $active_writer = 1; }
                my $next = $value + 1;
                sleep(0.0001);
                $value = $next;
                { lock($probe); die "reader entered writer section\n" if $active_readers; $active_writer = 0; }
            });
        }
        return 1;
    }
) for 1 .. 2;
push @t, threads->create(
    sub {
        for ( 1 .. 500 ) {
            with_rw(0, sub {
                { lock($probe); die "reader overlapped writer\n" if $active_writer; ++$active_readers; }
                my $snapshot = $value;
                sleep(0.0001);
                die "value changed during read\n" if $snapshot != $value;
                { lock($probe); die "writer entered reader section\n" if $active_writer; --$active_readers; }
            });
        }
        return 1;
    }
) for 1 .. 4;
my @failures;
for my $worker (@t) {
    my $ok = $worker->join;
    push @failures, $worker->tid unless $ok && !$worker->error;
}
die "worker failure: @failures\n" if @failures;
die "unbalanced probe\n" if $active_readers || $active_writer;
die "lost update" unless $value == 1000;
print "value=$value\n";
