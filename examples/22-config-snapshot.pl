#!/usr/bin/env perl
# Publishing immutable configuration snapshots to reader threads.
# The writer builds each version privately, then swaps one shared reference
# under a lock. Readers grab the current reference and may use it freely:
# a published structure is never modified, so it is always self-consistent.
use strict;
use warnings;
use threads;
use threads::shared;

my $gate   : shared;    # protects the $config reference
my $stop   : shared = 0;
my $config : shared = shared_clone( make_config(1) );

sub make_config {
    my ($v) = @_;
    return {
        version => $v,
        limits  => { min => $v, max => $v * 10 },
        hosts   => [ map { "app$_-v$v" } 1 .. 3 ],
    };
}

# Writer: build and clone outside the lock, swap inside it.
sub publish {
    my ($new) = @_;
    my $copy = shared_clone($new);    # expensive part, lock not held
    lock($gate);
    $config = $copy;    # readers see old or new, never partial
}

# Readers: hold the lock only long enough to read one reference.
sub current {
    lock($gate);
    return $config;
}

# A reader that needs to modify its view takes a private deep copy.
sub private_copy {
    my ($d) = @_;
    return { map { $_ => private_copy( $d->{$_} ) } keys %$d }
        if ref $d eq 'HASH';
    return [ map { private_copy($_) } @$d ] if ref $d eq 'ARRAY';
    return $d;
}

sub consistent {
    my ($c) = @_;
    my $v = $c->{version};
    return
           $c->{limits}{min} == $v
        && $c->{limits}{max} == $v * 10
        && @{ $c->{hosts} } == 3
        && $c->{hosts}[2] eq "app3-v$v";
}

my @readers = map {
    threads->create(
        sub {
            my ( $reads, $last ) = ( 0, 0 );
            until ($stop) {
                my $c = current();
                die "torn snapshot at version $c->{version}\n"
                    unless consistent($c);
                die "version went backwards\n" if $c->{version} < $last;
                $last = $c->{version};

                my $mine = private_copy($c);    # safe to mutate
                $mine->{limits}{max} = -1;
                die "private edit leaked\n" unless consistent( current() );
                ++$reads;
            }
            return $reads;
        }
    );
} 1 .. 4;

publish( make_config($_) ) for 2 .. 500;
{ lock($stop); $stop = 1; }

my $total = 0;
for my $thr (@readers) {
    my $reads = $thr->join;
    die 'reader failed: ' . ( $thr->error // 'no result' )
        unless defined $reads;
    $total += $reads;
}
die "final version wrong\n" unless current()->{version} == 500;
print "500 versions published, $total consistent snapshots read\n";
