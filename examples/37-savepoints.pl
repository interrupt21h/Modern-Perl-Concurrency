#!/usr/bin/env perl
use strict;
use warnings;
use DBI;
{

    package Demo::SavepointSchema;
    use base 'DBIx::Class::Schema';
}
{

    package Demo::SavepointRow;
    use base 'DBIx::Class::Core';
    __PACKAGE__->table('lab_savepoint');
    __PACKAGE__->add_columns( id => { data_type => 'integer' } );
    __PACKAGE__->set_primary_key('id');
}
Demo::SavepointSchema->register_class( Row => 'Demo::SavepointRow' );

# DB_DSN is optional and must designate the disposable laboratory.
my $dsn    = $ENV{DB_DSN} || 'dbi:SQLite:dbname=:memory:';
my $schema = Demo::SavepointSchema->connect(
    $dsn,
    $ENV{DB_USER} // '',
    $ENV{DB_PASS} // '',
    {
        RaiseError     => 1,
        PrintError     => 0,
        AutoCommit     => 1,
        auto_savepoint => 1
    },
);
my $dbh = $schema->storage->dbh;
$dbh->do('DROP TABLE IF EXISTS lab_savepoint');
my $engine = $dsn =~ /^dbi:mysql:/i ? ' ENGINE=InnoDB' : '';
$dbh->do("CREATE TABLE lab_savepoint (id INTEGER PRIMARY KEY)$engine");
my $rows = $schema->resultset('Row');
$schema->txn_do(
    sub {
        $rows->create( { id => 1 } );
        my $ok = eval {
            $schema->txn_do(
                sub {
                    $rows->create( { id => 2 } );
                    die "inner rollback\n";
                }
            );
            1;
        };
        die "expected savepoint rollback"
            if $ok || $@ !~ /inner rollback/;
        $rows->create( { id => 3 } );
    }
);
die "savepoint invariant"
    unless $rows->count == 2 && !$rows->find(2);
my $ok = eval {
    $schema->txn_do(
        sub {
            # Materialize the outer DBI transaction with real work before
            # the nested SAVEPOINT (SQLite may defer issuing BEGIN).
            $rows->create( { id => 5 } );
            $schema->txn_do( sub { $rows->create( { id => 4 } ) } );
            die "outer rollback\n";
        }
    );
    1;
};
die "outer rollback invariant"
    if $ok || $@ !~ /outer rollback/;
die "outer transaction leaked a row"
    if $rows->find(4) || $rows->find(5) || $rows->count != 2;
$dbh->do('DROP TABLE lab_savepoint');
print "nested rollback and outer commit ownership verified\n";
