use strict;
use warnings;
use Fcntl      qw(:DEFAULT :flock);
use File::Temp qw(tempdir);
my $dir  = tempdir( CLEANUP => 1 );
my $path = "$dir/counter";
open( my $init, '>', $path ) or die $!;
print {$init} "0\n";
close($init) or die $!;
my @pids;

for ( 1 .. 4 ) {
    defined( my $pid = fork() ) or die "fork: $!";
    if ( !$pid ) {
        for ( 1 .. 100 ) {
            sysopen( my $fh, $path, O_RDWR ) or die $!;
            flock( $fh, LOCK_EX )            or die $!;
            my $n = <$fh>;
            seek( $fh, 0, 0 )  or die $!;
            truncate( $fh, 0 ) or die $!;
            print {$fh} $n + 1, "\n" or die $!;
            close($fh) or die $!;
        }
        require POSIX;
        POSIX::_exit(0);
    }
    push @pids, $pid;
}
for (@pids) { waitpid( $_, 0 ) == $_ && $? == 0 or die "child failed"; }
open( my $fh, '<', $path ) or die $!;
my $n = <$fh>;
die "lost update" unless $n == 400;
print $n;
