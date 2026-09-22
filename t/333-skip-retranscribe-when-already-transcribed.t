use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Store;
require D2TG::Download;
require D2TG::Transcribe;
require D2TG::Transcribe::Retry;

# TGT-333 (found via a live JOB-004 improvement hunt): retry_failed_transcription
# used to re-download and re-transcribe the same audio from scratch on
# EVERY retry attempt, even when a prior attempt already transcribed it
# successfully and only the bookkeeping record_message write kept
# failing (e.g. database locked). D2TG::Download::retry_failed_download
# already got the equivalent fix in TGT-196 (persist local_path, skip
# download_file on a future retry) - this mirrors that for transcription,
# the single most expensive step in this whole pipeline.

sub fresh_db_path {
    my $dir = tempdir( CLEANUP => 1 );
    return File::Spec->catfile( $dir, 'store.sqlite' );
}

package Fake::Store::DyingRecordMessage;
our @ISA = ('D2TG::Store');
sub record_message { die "database is locked\n"; }
package main;

{
    # A row that already has a persisted transcript (a prior retry
    # succeeded at transcribing but record_message failed) must skip
    # download_file/transcribe entirely on the next retry - only
    # record_message is retried.
    my $store = D2TG::Store->new( db_path => fresh_db_path(), admin_chat_id => 1 );
    my $id    = $store->record_failed_transcription(
        999, 88, 'CCDDskip',
        sender => 'ada', error => 'database is locked',
    );
    $store->mark_failed_transcription_transcribed( $id, 'already recovered transcript' );

    my ($row) = grep { $_->{id} == $id } @{ $store->failed_transcriptions };
    ok( $row, 'queued failed transcription row exists' );
    is( $row->{transcript}, 'already recovered transcript', 'the persisted transcript round-trips through failed_transcriptions' );

    bless $store, 'Fake::Store::DyingRecordMessage';

    my $download_called   = 0;
    my $transcribe_called = 0;
    no warnings 'redefine', 'once';
    local *D2TG::Download::download_file = sub { $download_called++; return 'should-not-be-used.ogg' };
    local *D2TG::Transcribe::transcribe  = sub { $transcribe_called++; return 'should not be reached' };

    my $err = '';
    my ( $ok, $result, $still_queued );
    {
        open my $fh, '>', \$err or die $!;
        local *STDERR = $fh;
        ( $ok, $result, $still_queued ) =
          D2TG::Transcribe::Retry::retry_failed_transcription( undef, $store, $row );
        close $fh;
    }

    is( $download_called,   0, 'download is never re-attempted when a transcript is already persisted' );
    is( $transcribe_called, 0, 'whisper is never re-invoked when a transcript is already persisted' );
    ok( $ok,                 'the already-persisted transcript is still reported as success' );
    is( $result, 'already recovered transcript', 'the persisted transcript is returned, not re-generated' );
    ok( $still_queued, 'record_message failing again leaves the row still queued' );

    my ($still) = grep { $_->{id} == $id } @{ $store->failed_transcriptions };
    is( $still->{transcript}, 'already recovered transcript', 'the persisted transcript survives another failed retry unchanged' );
}

{
    # A first-time failure (no transcript persisted yet) must still go
    # through the normal download+transcribe path.
    my $store = D2TG::Store->new( db_path => fresh_db_path(), admin_chat_id => 1 );
    my $id    = $store->record_failed_transcription(
        999, 90, 'CCDDfresh',
        sender => 'ada', error => 'ffmpeg conversion failed',
    );
    my ($row) = grep { $_->{id} == $id } @{ $store->failed_transcriptions };
    ok( !defined $row->{transcript}, 'a freshly-queued row has no persisted transcript yet' );
}

done_testing();
