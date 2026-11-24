sub finish {
    my ( $db, $job ) = @_;
    my $value = 2 * $job->{value};
    return tx(
        $db,
        sub {
            my $changed = $db->do(
                q{UPDATE job SET state='done',lease_until=0
              WHERE id=? AND attempt=? AND state='running'},
                undef, $job->{id}, $job->{attempt},
            );
            return 0 unless $changed == 1;
            $db->do( 'INSERT INTO result VALUES (?,?)',
                undef, $job->{id}, $value );
            $db->do( 'INSERT INTO outbox (id,value) VALUES (?,?)',
                undef, $job->{id}, $value );
            return 1;
        }
    );
}
