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
    unlink $path;
    return $path;
}

{
    my $db = fresh_db_path();
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );

    is( $store->get_offset, undef, 'a brand-new store has no persisted offset' );
}

{
    my $db = fresh_db_path();
    my $store1 = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );
    $store1->set_offset(12345);
    undef $store1;

    my $store2 = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );
    is( $store2->get_offset, 12345, 'the offset persists across a new Store instance on the same db' );
}

{
    my $db = fresh_db_path();
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );
    $store->set_offset(1);
    $store->set_offset(2);

    is( $store->get_offset, 2, 'set_offset overwrites the previous value rather than accumulating rows' );
}

done_testing();
