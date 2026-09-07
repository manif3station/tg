use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Store;

{
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => [ 1234, 4567, 7890 ] );

    ok( $store->is_allowed(1234), 'first chat_id in an arrayref admin_chat_id is seeded allowed' );
    ok( $store->is_allowed(4567), 'second chat_id in an arrayref admin_chat_id is seeded allowed' );
    ok( $store->is_allowed(7890), 'third chat_id in an arrayref admin_chat_id is seeded allowed' );
    ok( !$store->is_allowed(9999), 'a chat_id not in the arrayref is not seeded allowed' );
}

{
    # Existing scalar usage (unchanged behavior).
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );

    ok( $store->is_allowed(999), 'a plain scalar admin_chat_id still works exactly as before' );
}

done_testing();
