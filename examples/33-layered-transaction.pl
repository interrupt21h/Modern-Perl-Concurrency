#!/usr/bin/env perl
use strict;
use warnings;

{
    package Demo::Schema;
    use base 'DBIx::Class::Schema';
}
{
    package Demo::Item;
    use base 'DBIx::Class::Core';
    __PACKAGE__->table('item');
    __PACKAGE__->add_columns(
        id => { data_type => 'integer' },
        quantity => { data_type => 'integer' },
    );
    __PACKAGE__->set_primary_key('id');
}
{
    package Demo::Audit;
    use base 'DBIx::Class::Core';
    __PACKAGE__->table('audit');
    __PACKAGE__->add_columns(
        id => { data_type => 'integer' },
        item_id => { data_type => 'integer' },
    );
    __PACKAGE__->set_primary_key('id');
}

Demo::Schema->register_class(Item => 'Demo::Item');
Demo::Schema->register_class(Audit => 'Demo::Audit');
my $schema = Demo::Schema->connect(
    'dbi:SQLite:dbname=:memory:', '', '',
    { RaiseError => 1, PrintError => 0, AutoCommit => 1 },
);
$schema->storage->dbh->do(
    'CREATE TABLE item (id INTEGER PRIMARY KEY,
      quantity INTEGER NOT NULL CHECK(quantity >= 0))'
);
$schema->storage->dbh->do(
    'CREATE TABLE audit (id INTEGER PRIMARY KEY,
      item_id INTEGER NOT NULL)'
);
$schema->resultset('Item')->create({ id => 1, quantity => 10 });

# Repository method: participates in the caller's transaction.
sub reserve_one {
    my ($schema, $id) = @_;
    my $changed = $schema->resultset('Item')->search(
        { id => $id, quantity => { '>' => 0 } }
    )->update({ quantity => \'quantity - 1' });
    die "no stock" unless $changed == 1;
}

# Service boundary: commit the complete unit of work together.
sub reserve {
    my ($schema, $request_id, $fail) = @_;
    return $schema->txn_do(sub {
        reserve_one($schema, 1);
        die "injected failure\n" if $fail;
        $schema->resultset('Audit')->create(
            { id => $request_id, item_id => 1 }
        );
        return $request_id;
    });
}

my $ok = eval { reserve($schema, 100, 1); 1 };
die "expected rollback" if $ok;
die "wrong error: $@" unless $@ =~ /injected failure/;
die "partial stock update" unless
    $schema->resultset('Item')->find(1)->quantity == 10;
die "partial audit" if $schema->resultset('Audit')->count;

reserve($schema, 100, 0);
die "wrong stock" unless
    $schema->resultset('Item')->find(1)->quantity == 9;
die "missing audit" unless $schema->resultset('Audit')->count == 1;

$ok = eval { reserve($schema, 100, 0); 1 };
die "duplicate unexpectedly succeeded" if $ok;
die "duplicate changed stock" unless
    $schema->resultset('Item')->find(1)->quantity == 9;
die "duplicate audit" unless $schema->resultset('Audit')->count == 1;
print "rollback, commit and duplicate invariant verified\n";
