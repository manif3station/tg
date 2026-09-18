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

# TGT-311 (explicit user-requested architecture change, direct chat
# request 2026-09-18): the poller no longer prints a new text/voice
# message's own content inline - it prints only a FETCH WITH command
# template. d2 tg.fetch is the new command that actually shows the
# content, marking the message read as a side effect of a SUCCESSFUL
# fetch (mirroring cli/attachment.pl's own "only after success"
# invariant, and TGT-046's own send_reply precedent) - the agent never
# needs to run a separate mark-read command, fetching and marking read
# are one action.

my $fetch_cli = File::Spec->catfile( $Bin, '..', 'cli', 'fetch.pl' );

sub _run_capturing_stderr {
    my (@cmd) = @_;
    my $err_file = "/tmp/d2tg-311-stderr.$$";
    my $out = `@cmd 2>$err_file`;
    my $rc  = $? >> 8;
    my $err = do { open my $fh, '<', $err_file or die $!; local $/; <$fh> };
    unlink $err_file;
    return ( $out, $rc, $err );
}

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my $db_path = D2TG::Config::state_db_path(
        default_root => File::Spec->catdir( $Bin, '..' ),
        base_dir      => D2TG::Config::resolve_alias_dir( alias => undef ),
    );
    my $store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 398296603 );
    $store->record_message( 999, 42, 'ada', 'hello from ada' );
    ok( !$store->is_read( 999, 42 ), 'sanity: the message starts out unread' );
    $store->disconnect;

    my ( $out, $rc, $err ) = _run_capturing_stderr( $fetch_cli, 999, 42 );

    is( $rc, 0, 'd2 tg.fetch exits 0 for a real recorded message' );
    is( $out, "hello from ada\n", 'stdout is the stored message content' );

    my $store2 = D2TG::Store->new( db_path => $db_path, admin_chat_id => 398296603 );
    ok( $store2->is_read( 999, 42 ), 'the message is marked read as a side effect of a successful fetch' );
    $store2->disconnect;
}

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my ( $out, $rc, $err ) = _run_capturing_stderr( $fetch_cli, 999, 9999 );

    isnt( $rc, 0, 'd2 tg.fetch refuses clearly for an unrecorded (chat_id, message_id) - nothing to mark read' );
    like( $err, qr/no message recorded/i, 'the refusal names the problem' );
}

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my ( $out, $rc, $err ) = _run_capturing_stderr( $fetch_cli, 'not-a-number', 42 );

    is( $rc, 2, 'd2 tg.fetch refuses a non-numeric chat_id with exit 2 (Usage)' );
    like( $err, qr/Usage/, 'the refusal names the Usage form' );
}

done_testing();
