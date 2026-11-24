# Illustrative adapter contract; adapter functions are supplied by the caller.
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

sub remaining {
    my ($deadline) = @_;
    my $left = $deadline - clock_gettime(CLOCK_MONOTONIC);
    die "operation deadline exceeded" if $left <= 0;
    return $left;
}

sub process_request {
    my ( $admit, $store, $respond ) = @_;
    my $deadline = clock_gettime(CLOCK_MONOTONIC) + 2;
    my $job      = $admit->( remaining($deadline) );
    my $result   = $store->( $job, remaining($deadline) );
    return $respond->( $result, remaining($deadline) );
}
