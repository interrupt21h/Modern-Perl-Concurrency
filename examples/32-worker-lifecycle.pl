#!/usr/bin/env perl
use strict;
use warnings;
use POSIX ();

{
    package Demo::Resources;
    use Moose;

    has factory => (is => 'ro', isa => 'CodeRef', required => 1);
    has resource => (is => 'rw', clearer => 'clear_resource');
    has owner_pid => (is => 'rw', isa => 'Int', default => 0);

    sub current {
        my ($self) = @_;
        if ($self->owner_pid != $$) {
            # Plain hash only: real clients need fork-safe handling.
            $self->clear_resource;
            $self->owner_pid($$);
        }
        if (!defined $self->resource) {
            $self->resource($self->factory->());
        }
        return $self->resource;
    }

    __PACKAGE__->meta->make_immutable;
}

my $created = 0;
my $resources = Demo::Resources->new(
    factory => sub { return { pid => $$, serial => ++$created } },
);
my $parent = $resources->current;
die "wrong parent owner" unless $parent->{pid} == $$;
my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    my $child = $resources->current;
    my $again = $resources->current;
    my $ok = $child->{pid} == $$ && $child->{serial} == 2
        && $again == $child;
    POSIX::_exit($ok ? 0 : 1);
}
waitpid($pid, 0) == $pid or die "waitpid: $!";
die "child invariant failed" if $? != 0;
die "parent resource changed" unless $resources->current == $parent;
print "child reinitialized resource; parent unchanged\n";
