#!/usr/bin/env perl
# System V counting semaphore shared by forked workers, with SEM_UNDO.
use strict;
use warnings;
use IPC::SysV qw(IPC_PRIVATE IPC_CREAT S_IRUSR S_IWUSR SEM_UNDO);
use IPC::Semaphore;
use POSIX qw(_exit);
use Time::HiRes qw(sleep);

my $sem = IPC::Semaphore->new(IPC_PRIVATE, 1, IPC_CREAT | S_IRUSR | S_IWUSR)
    or die "semget: $!";
my $owner = $$;
# Remove the kernel object on every exit path of the creating process.
END { $sem->remove if $sem && $$ == $owner }

defined($sem->setval(0, 2)) or die "SETVAL: $!";

my @pids;
for (1 .. 6) {
    defined(my $pid = fork()) or die "fork: $!";
    if (!$pid) {
        $sem->op(0, -1, SEM_UNDO) or _exit(1);   # acquire one permit
        sleep(0.05);
        $sem->op(0, 1, SEM_UNDO)  or _exit(2);   # release it
        _exit(0);                                # skip END in children
    }
    push @pids, $pid;
}

my $failed = 0;
for my $pid (@pids) {
    waitpid($pid, 0) == $pid or die "waitpid: $!";
    $failed = 1 if $?;
}
my $remaining = $sem->getval(0);
die "semaphore failed" if $failed || $remaining != 2;
print "permits restored\n";
