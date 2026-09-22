use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use File::Temp qw(tempdir);
use File::Spec;
use Test::MandatoryDb qw(setup_mandatory_db_env);

require D2TG::Store;

# TGT-335 (found via a live JOB-004 improvement hunt): d2 tg.status
# reported poller liveness/heartbeat but nothing about queued
# failed_downloads/failed_transcriptions - a real degraded-but-alive
# state (auto-retry exhausted, TGT-221/246) was invisible without a
# separate d2 tg.unread call.

my $status_cli  = File::Spec->catfile( $Bin, '..', 'cli', 'status.pl' );
my $fake_db_dir = tempdir( CLEANUP => 1 );
setup_mandatory_db_env( $Bin, $fake_db_dir );
local %ENV = %ENV;
$ENV{D2TG_TOKEN}   = 'test-token';
$ENV{D2TG_CHAT_ID} = '12345';

{
    my $out = `$status_cli`;
    my $rc  = $? >> 8;
    is( $rc, 0, 'd2 tg.status exits 0 against an empty queue' );
    like( $out, qr/^queued failed downloads: 0$/m, 'd2 tg.status reports 0 queued failed downloads when the queue is empty (not omitted)' );
    like( $out, qr/^queued failed transcriptions: 0$/m, 'd2 tg.status reports 0 queued failed transcriptions when the queue is empty (not omitted)' );
}

{
    my $store = D2TG::Store->new(
        db_path       => File::Spec->catfile( $fake_db_dir, '.tira', 'telegram.messages.db' ),
        admin_chat_id => 12345,
    );
    $store->record_failed_download( 12345, 111, 'file-id-1', sender => 'ada', media_kind => 'photo', error => 'boom' );
    $store->record_failed_transcription( 12345, 222, 'file-id-2', sender => 'ada', error => 'boom' );
    $store->disconnect;

    my $out = `$status_cli`;
    my $rc  = $? >> 8;
    is( $rc, 0, 'd2 tg.status exits 0 with queued rows present' );
    like( $out, qr/^queued failed downloads: 1$/m, 'd2 tg.status reports the accurate queued-download count' );
    like( $out, qr/^queued failed transcriptions: 1$/m, 'd2 tg.status reports the accurate queued-transcription count' );
}

done_testing();
