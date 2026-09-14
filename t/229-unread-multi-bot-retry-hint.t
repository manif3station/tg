use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use lib "$Bin/lib", "$Bin/../lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

use D2TG::Config;
use D2TG::Store;

# TGT-229 (found via a scheduled JOB-003 hourly bug hunt): cli/unread.pl
# lists queued failed_downloads unscoped across ALL bots but prints one
# static "RETRY WITH: d2 tg.retry-download --all" hint with no --bot
# flag, and never shows each row's own bot_key. In a multi-bot config,
# cli/retry-download.pl --all with no --bot only retrieves the
# default-bot sentinel's own queue (TGT-219) - a non-default-bot row is
# listed but the printed recovery instructions can never retry it. Same
# class of gap as TGT-217/TGT-220, both already fixed elsewhere.

my $unread_cli = File::Spec->catfile( $Bin, '..', 'cli', 'unread.pl' );

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my $db_path = D2TG::Config::state_db_path(
        default_root => File::Spec->catdir( $Bin, '..' ),
        base_dir     => D2TG::Config::resolve_alias_dir( alias => undef ),
    );
    my $store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 398296603 );

    my $bot_b_token = '987654321:BBOtherBotTokenLooksLikeThisxyz';
    $store->record_failed_download( 111, 55, 'fileA', sender => 'ada', media_kind => 'photo', error => 'boom' );
    $store->record_failed_download( 222, 66, 'fileB', sender => 'bob', media_kind => 'document', error => 'boom', bot_key => $bot_b_token );
    $store->disconnect;

    my $out = `$unread_cli 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'cli/unread exits 0 with queued failures present' );

    my $masked = D2TG::Config::masked_token($bot_b_token);
    like(
        $out,
        qr/RETRY WITH: d2 tg\.retry-download --all --bot \Q$masked\E/,
        'a correctly-scoped RETRY WITH hint is printed for the non-default bot present in the listing'
    );
    unlike( $out, qr/\Q$bot_b_token\E/, 'the raw non-default bot token is never printed, only its masked form' );
    like( $out, qr/RETRY WITH: d2 tg\.retry-download --all\n/, 'the plain default-bot hint is also still present for the default-bot row' );
}

# Regression: single-bot mode (only the default sentinel bot_key) must
# print exactly the original plain hint, unchanged.
{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my $db_path = D2TG::Config::state_db_path(
        default_root => File::Spec->catdir( $Bin, '..' ),
        base_dir     => D2TG::Config::resolve_alias_dir( alias => undef ),
    );
    my $store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 398296603 );
    $store->record_failed_download( 111, 55, 'fileA', sender => 'ada', media_kind => 'photo', error => 'boom' );
    $store->disconnect;

    my $out = `$unread_cli 2>&1`;

    like( $out, qr/Queued failed downloads.*RETRY WITH: d2 tg\.retry-download --all\):/s, 'single-bot mode keeps the original plain hint format unchanged' );
    unlike( $out, qr/--bot/, 'no --bot flag at all in single-bot mode' );
}

done_testing();
