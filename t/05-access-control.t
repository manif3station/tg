use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempfile);

require D2TG::Store;

sub fresh_db_path {
    my ( $fh, $path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    close $fh;
    unlink $path;    # D2TG::Store must create the schema itself
    return $path;
}

{
    my $db = fresh_db_path();
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );

    ok( $store->is_allowed(999), 'the admin chat id is auto-seeded into allow_list' );
    ok( !$store->is_allowed(111), 'an unrelated chat id is not allowed by default' );
}

{
    my $db = fresh_db_path();
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );

    $store->add_pending(111);
    ok( !$store->is_allowed(111), 'a pending sender is still not allowed' );
    is( scalar $store->pending_chat_ids, 1, 'the pending chat id is recorded' );
    is( ( $store->pending_chat_ids )[0], 111, 'the recorded pending id matches' );
}

{
    my $db = fresh_db_path();
    my $store1 = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );
    $store1->add_pending(111);
    undef $store1;

    my $store2 = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );
    ok( $store2->is_allowed(999), 'admin allow-list persists across a new Store instance on the same db' );
    is( scalar $store2->pending_chat_ids, 1, 'pending record persists across a new Store instance' );
}

{
    my $db = fresh_db_path();
    D2TG::Store->new( db_path => $db, admin_chat_id => 999 );
    my $again = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );

    ok( $again->is_allowed(999), 're-seeding the same admin id twice does not error' );
}

done_testing();
