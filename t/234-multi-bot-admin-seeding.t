use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Store;

# TGT-234: cli/poller.pl's real multi-bot startup calls
# D2TG::Store->new(admin_chat_id => [ map { $_->{chat_id} } @$groups ]) -
# a flat list of chat ids with no bot_key info at all. But
# D2TG::Poller::run_once's is_allowed check in multi-bot mode passes the
# REAL bot token as bot_key. _seed_admin always seeded under
# DEFAULT_BOT_KEY ('') unless told otherwise, so the admin's own chat_id
# never matched under any real bot token - locking the admin out.

{
    # Reproduces a real 2-group, 2-bot poller startup: each group's
    # chat_id must be seeded allowed under EACH of its own bot tokens,
    # not the '' sentinel.
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new(
        db_path       => $db,
        admin_chat_id => [
            { chat_id => 1111, bot_key => 'tokenA' },
            { chat_id => 2222, bot_key => 'tokenB' },
        ],
    );

    ok( $store->is_allowed( 1111, 'tokenA' ), 'chat 1111 is allowed under its own real bot token' );
    ok( $store->is_allowed( 2222, 'tokenB' ), 'chat 2222 is allowed under its own real bot token' );
    ok( !$store->is_allowed( 1111, '' ), 'chat 1111 is NOT seeded under the default sentinel in multi-bot mode' );
    ok( !$store->is_allowed( 2222, 'tokenA' ), 'chat 2222 is not cross-seeded under the wrong bot token' );
}

{
    # One chat_id shared by two bots in the same group (single --chat_id,
    # multiple --bot values) - both real tokens must be seeded.
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new(
        db_path       => $db,
        admin_chat_id => [
            { chat_id => 5555, bot_key => 'tokenX' },
            { chat_id => 5555, bot_key => 'tokenY' },
        ],
    );

    ok( $store->is_allowed( 5555, 'tokenX' ), 'shared chat_id allowed under first bot token' );
    ok( $store->is_allowed( 5555, 'tokenY' ), 'shared chat_id allowed under second bot token' );
}

{
    # Back-compat: existing scalar/plain-arrayref callers (single-bot
    # mode, and t/45's own pre-existing usage) must be unaffected.
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => [ 1234, 4567 ] );

    ok( $store->is_allowed(1234), 'plain scalar chat_id in arrayref still seeds under the default sentinel' );
    ok( $store->is_allowed(4567), 'second plain scalar chat_id also still seeds under the default sentinel' );
}

{
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );

    ok( $store->is_allowed(999), 'a bare scalar admin_chat_id still works exactly as before' );
}

done_testing();
