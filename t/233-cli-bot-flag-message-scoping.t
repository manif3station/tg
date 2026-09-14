use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempfile tempdir);
use lib "$Bin/lib", "$Bin/../lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

use D2TG::Config;
use D2TG::Store;

# TGT-233 (fast-follow from TGT-232's own scope decision): TGT-232 made
# D2TG::Store's messages table bot_key-aware, but cli/history.pl,
# cli/unread.pl, and cli/attachment.pl had no --bot flag at all, so
# they could never actually make use of that scoping - always
# operating on the default-bot sentinel's own messages. Adds --bot
# <token> to all 3, matching cli/retry-download.pl's own established
# leading-position, eval-wrapped extract_bot_flag convention.

my $history_cli    = File::Spec->catfile( $Bin, '..', 'cli', 'history.pl' );
my $unread_cli      = File::Spec->catfile( $Bin, '..', 'cli', 'unread.pl' );
my $attachment_cli = File::Spec->catfile( $Bin, '..', 'cli', 'attachment.pl' );

sub seed_store {
    my ($db_dir) = @_;
    my $db_path = D2TG::Config::state_db_path(
        default_root => File::Spec->catdir( $Bin, '..' ),
        base_dir     => D2TG::Config::resolve_alias_dir( alias => undef ),
    );
    my $store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 398296603 );
    return $store;
}

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my $bot_b_token = '987654321:BBOtherBotTokenLooksLikeThisxyz';
    my $store       = seed_store($fake_db_dir);
    $store->record_message( 111, 55, 'ada', 'from bot A' );
    $store->record_message( 111, 66, 'bob', 'from bot B', bot_key => $bot_b_token );
    $store->disconnect;

    my $out_a = `$history_cli 2>&1`;
    like( $out_a, qr/from bot A/, 'cli/history with no --bot shows the default-bot message (unchanged behavior)' );
    unlike( $out_a, qr/from bot B/, 'cli/history with no --bot does not show the other bot\'s message' );

    my $out_b = `$history_cli --bot $bot_b_token 2>&1`;
    like( $out_b, qr/from bot B/, 'cli/history --bot <token> shows that bot\'s own message' );
    unlike( $out_b, qr/from bot A/, 'cli/history --bot <token> does not show the default bot\'s message' );
}

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my $bot_b_token = '987654321:BBOtherBotTokenLooksLikeThisxyz';
    my $store       = seed_store($fake_db_dir);
    $store->record_message( 111, 55, 'ada', 'from bot A' );
    $store->record_message( 111, 66, 'bob', 'from bot B', bot_key => $bot_b_token );
    $store->disconnect;

    my $out_a = `$unread_cli 2>&1`;
    like( $out_a, qr/from bot A/, 'cli/unread with no --bot shows the default-bot message (unchanged behavior)' );
    unlike( $out_a, qr/from bot B/, 'cli/unread with no --bot does not show the other bot\'s message' );

    my $out_b = `$unread_cli --bot $bot_b_token 2>&1`;
    like( $out_b, qr/from bot B/, 'cli/unread --bot <token> shows that bot\'s own message' );
    unlike( $out_b, qr/from bot A/, 'cli/unread --bot <token> does not show the default bot\'s message' );
}

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my $bot_b_token = '987654321:BBOtherBotTokenLooksLikeThisxyz';
    my $store       = seed_store($fake_db_dir);

    my ( $fh_a, $path_a ) = tempfile( SUFFIX => '.jpg', UNLINK => 1 );
    print {$fh_a} 'default bot bytes';
    close $fh_a;
    my ( $fh_b, $path_b ) = tempfile( SUFFIX => '.jpg', UNLINK => 1 );
    print {$fh_b} 'other bot bytes';
    close $fh_b;

    $store->record_message( 111, 55, 'ada', 'photo', local_path => $path_a );
    $store->record_message( 111, 55, 'bob', 'photo', local_path => $path_b, bot_key => $bot_b_token );
    $store->disconnect;

    my $out_default = `$attachment_cli 111 55 2>/dev/null`;
    is( $out_default, 'default bot bytes', 'cli/attachment with no --bot returns the default bot\'s own attachment (unchanged behavior)' );

    my $out_scoped = `$attachment_cli --bot $bot_b_token 111 55 2>/dev/null`;
    is( $out_scoped, 'other bot bytes', 'cli/attachment --bot <token> returns that bot\'s own attachment' );
}

done_testing();
