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

# TGT-239 (found via a scheduled JOB-003 hourly bug hunt): cli/unread.pl
# lists queued failed_downloads (TGT-204/229) but never surfaced
# failed_transcriptions - a structural sibling queue added by TGT-237 -
# so a failed voice transcription was invisible to d2 tg.unread and
# could silently expire via TGT-238's own 30-day eviction with zero
# visibility.

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
    $store->record_failed_transcription( 111, 42, 'voice-file-1', sender => 'ada', error => 'whisper crashed' );
    $store->disconnect;

    my $out = `$unread_cli 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'cli/unread exits 0 with a queued failed transcription present' );
    like( $out, qr/Queued failed transcriptions/, 'a failed_transcriptions section header is printed' );
    like( $out, qr/\[111\] msg #42 ada:.*whisper crashed/, 'the row names chat_id/message_id/sender/error' );
    like( $out, qr/RETRY WITH: d2 tg\.retry-transcription --all/, 'the recovery hint names d2 tg.retry-transcription' );
}

# Multi-bot scoping: mirrors TGT-229's own failed_downloads convention.
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
    $store->record_failed_transcription( 111, 55, 'voice-a', sender => 'ada', error => 'boom' );
    $store->record_failed_transcription( 222, 66, 'voice-b', sender => 'bob', error => 'boom', bot_key => $bot_b_token );
    $store->disconnect;

    my $out = `$unread_cli 2>&1`;
    my $masked = D2TG::Config::masked_token($bot_b_token);
    like(
        $out,
        qr/RETRY WITH: d2 tg\.retry-transcription --all --bot \Q$masked\E/,
        'a correctly-scoped RETRY WITH hint is printed for the non-default bot present in the transcription listing'
    );
    unlike( $out, qr/\Q$bot_b_token\E/, 'the raw non-default bot token is never printed, only its masked form' );
}

# Both queues together: both sections appear, in order.
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
    $store->record_failed_download( 111, 10, 'file-a', sender => 'ada', media_kind => 'photo', error => 'dl-boom' );
    $store->record_failed_transcription( 111, 20, 'voice-a', sender => 'ada', error => 'tr-boom' );
    $store->disconnect;

    my $out = `$unread_cli 2>&1`;
    like( $out, qr/Queued failed downloads.*Queued failed transcriptions/s, 'both sections appear, downloads before transcriptions' );
}

# Regression: no queued failures of either kind, and no unread messages,
# is byte-identical to the pre-fix baseline.
{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my $out = `$unread_cli 2>&1`;
    is( $out, "No unread messages.\n", 'empty store output is unchanged from the pre-fix baseline' );
}

done_testing();
