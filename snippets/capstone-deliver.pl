sub deliver {
    my ( $db, $sink, $job, $fail ) = @_;
    tx(
        $sink,
        sub {
            $sink->do(
                'INSERT INTO effect VALUES (?,?)
             ON CONFLICT(id) DO NOTHING',
                undef, $job->{id}, $job->{value},
            );
            my ($stored) = $sink->selectrow_array(
                'SELECT value FROM effect WHERE id=?',
                undef, $job->{id}, );
            die "divergent event" unless $stored == $job->{value};
        }
    );
    die "injected lost acknowledgement\n" if $fail;
    my $changed = $db->do(
        q{UPDATE outbox SET state='done',lease_until=0
          WHERE id=? AND attempt=? AND state='running'},
        undef, $job->{id}, $job->{attempt},
    );
    return $changed == 1;
}
