#!/usr/bin/env perl
# A reusable "run this code while holding a file lock" helper built on
# try/catch and defer. defer releases the lock however the block is left:
# normal return, return from inside try, or an exception.
# try/catch is stable from Perl 5.40; on 5.36-5.38 it is experimental, and
# defer is experimental through 5.44, hence the feature/warnings lines.
use v5.36;
use feature qw(try defer);
no warnings qw(experimental::try experimental::defer);
use Fcntl qw(:DEFAULT :flock);
use File::Temp qw(tempdir);

sub with_flock ($path, $code) {
    sysopen(my $fh, $path, O_CREAT | O_RDWR, 0600) or die "open $path: $!\n";
    flock($fh, LOCK_EX) or die "flock $path: $!\n";
    defer { close $fh }                    # closing the handle drops the lock

    try {
        return $code->();                  # returns from with_flock itself
    }
    catch ($e) {
        die "locked section on $path failed: $e";   # add context, rethrow
    }
}

my $path = tempdir(CLEANUP => 1) . '/report.lock';

sub lock_is_free {
    sysopen(my $probe, $path, O_CREAT | O_RDWR, 0600) or die "open: $!\n";
    my $free = flock($probe, LOCK_EX | LOCK_NB);
    close $probe;
    return $free;
}

# 1. Normal completion returns the block's value and releases the lock.
my $value = with_flock($path, sub {
    die "lock not exclusive\n" if lock_is_free();
    return 42;
});
die "wrong result: $value\n" unless $value == 42;
die "lock leaked after return\n" unless lock_is_free();

# 2. An exception propagates with context and still releases the lock.
my $ok = eval { with_flock($path, sub { die "disk full\n" }); 1 };
die "exception swallowed\n" if $ok;
die "missing context: $@" unless $@ =~ /^locked section on .* failed: disk full$/;
die "lock leaked after exception\n" unless lock_is_free();

# 3. Nested use on different files works; inner lock released first.
my $inner = "$path.inner";
my $nested = with_flock($path, sub { with_flock($inner, sub { 'nested' }) });
die "nested call failed\n" unless $nested eq 'nested';

say 'try/catch/defer released the lock on return, exception and nesting';
