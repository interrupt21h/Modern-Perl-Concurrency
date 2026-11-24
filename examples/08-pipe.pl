use strict;
use warnings;
use POSIX qw(_exit);
pipe(my $reader, my $writer) or die $!;
defined(my $pid = fork()) or die $!;
if (!$pid) {
    close $reader;
    print {$writer} "$_\n" for 1..100;
    close($writer) or _exit(1);
    _exit(0);
}
close $writer;
my $sum = 0;
$sum += $_ while <$reader>;
close $reader;
waitpid($pid, 0);
die "failed" if $? || $sum != 5050;
print "sum=$sum\n";
