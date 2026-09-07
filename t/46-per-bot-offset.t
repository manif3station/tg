use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Store;

{
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );

    is( $store->get_offset('secret-token-1'), undef, 'no offset yet for a given bot key' );

    $store->set_offset( 100, 'secret-token-1' );
    $store->set_offset( 200, 'secret-token-2' );

    is( $store->get_offset('secret-token-1'), 100, 'bot 1 gets its own persisted offset' );
    is( $store->get_offset('secret-token-2'), 200, 'bot 2 gets its own, independent persisted offset' );
}

{
    # Existing single-bot usage (no bot key at all) is completely unchanged.
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );

    is( $store->get_offset, undef, 'no offset yet (plain single-bot usage)' );
    $store->set_offset(42);
    is( $store->get_offset, 42, 'plain single-bot get/set_offset still works exactly as before' );
}

{
    # The raw token must never appear in plaintext in the underlying meta table.
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );

    $store->set_offset( 100, '123456789:AAVeryRealLookingSecretBotTokenAAAAAA' );

    my $rows = $store->{dbh}->selectall_arrayref('SELECT key, value FROM meta');
    my $found_plaintext = grep { $_->[0] =~ /AAVeryRealLookingSecretBotToken/ || ( defined $_->[1] && $_->[1] =~ /AAVeryRealLookingSecretBotToken/ ) } @$rows;
    ok( !$found_plaintext, 'the raw bot token never appears in plaintext in the meta table - only a hashed key' );
}

done_testing();
