use strict;
use warnings;
use Test2::V0;
use FindBin;
my $dir = "$FindBin::Bin/..";
for my $case (
    ['36-processing-capstone.pl', qr/48 results, 48 effects, sum 2352/],
    ['38-retry-cancel.pl', qr/cancellation verified/],
) {
    my ($file, $pattern) = @$case;
    open my $fh, '-|', $^X, "$dir/$file" or die "spawn: $!";
    my $output = do { local $/; <$fh> };
    my $ok = close $fh;
    ok($ok, "$file exited successfully");
    like($output, $pattern, "$file reported its invariant");
}
done_testing;
