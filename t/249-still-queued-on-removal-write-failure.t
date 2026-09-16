use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use HTTP::Response;
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Store;
require D2TG::Download;
require D2TG::Transcribe;
require D2TG::Transcribe::Retry;

# TGT-249 (found via a scheduled JOB-003 hourly bug hunt): retry_failed_download
# and retry_failed_transcription's own $still_queued 3rd return value
# (TGT-244/TGT-248) is computed by unconditionally assuming the queue-row
# removal write (remove_failed_download / remove_failed_transcription)
# succeeded, once record_message has succeeded - it never inspects
# D2TG::Poller::store_write_safe's own (ok, value) result for that call.
# If record_message succeeds but the removal write itself then hits a
# transient failure (a locked/busy database - the exact scenario
# store_write_safe exists to guard against), the row is NOT actually
# removed, yet $still_queued is still reported as false/0, so
# cli/retry-download.pl / cli/retry-transcription.pl print an
# unqualified RETRY OK and exit 0 even though the row is still sitting
# in failed_downloads/failed_transcriptions.

sub fresh_db_path {
    my $dir = tempdir( CLEANUP => 1 );
    return File::Spec->catfile( $dir, 'store.sqlite' );
}

package Fake::DownloadTelegram;

sub new {
    my ( $class, %args ) = @_;
    return bless { file_path => $args{file_path} }, $class;
}

sub get_file          { my ( $self, $file_id ) = @_; return $self->{file_path}; }
sub file_download_url { my ( $self, $file_path ) = @_; return "https://api.telegram.org/file/bottest-token/$file_path"; }

package Fake::UA;

sub new { my ( $class, %args ) = @_; return bless { responses => $args{responses} || [] }, $class; }
sub get { my ($self) = @_; return shift @{ $self->{responses} }; }

package main;

{
    # retry_failed_download: record_message succeeds, but
    # remove_failed_download itself then dies (transient DB failure).
    # The row is genuinely still in failed_downloads - $still_queued
    # must be true, not false.
    my $store = D2TG::Store->new( db_path => fresh_db_path(), admin_chat_id => 1 );
    my $id    = $store->record_failed_download(
        999, 77, 'AABBstillq',
        sender => 'ada', media_kind => 'document', caption_note => '', error => 'transient',
    );

    package Fake::Store::DyingRemoveFailedDownload;
    our @ISA = ('D2TG::Store');
    sub remove_failed_download { die "database is locked\n"; }
    package main;
    bless $store, 'Fake::Store::DyingRemoveFailedDownload';

    my ($row) = grep { $_->{id} == $id } @{ $store->failed_downloads };
    ok( $row, 'queued failed download row exists' );

    my $dir      = tempdir( CLEANUP => 1 );
    my $telegram = Fake::DownloadTelegram->new( file_path => 'documents/still-queued.pdf' );
    my $response = HTTP::Response->new( 200, 'OK' );
    $response->content('recovered file bytes');
    my $ua = Fake::UA->new( responses => [$response] );

    my $err = '';
    my ( $ok, $result, $still_queued );
    {
        open my $fh, '>', \$err or die $!;
        local *STDERR = $fh;
        ( $ok, $result, $still_queued ) =
          D2TG::Download::retry_failed_download( $telegram, $store, $row, $dir, ua => $ua );
        close $fh;
    }

    ok( $ok, 'the download itself genuinely succeeded ($ok true)' );
    like( $result, qr/\.pdf$/, 'the newly downloaded local path is returned' );
    ok( $still_queued,
        'still_queued is true when remove_failed_download itself fails after a successful record_message (RED until fixed)' );

    my @still = grep { $_->{id} == $id } @{ $store->failed_downloads };
    is( scalar(@still), 1, 'the row is genuinely still present in failed_downloads - the removal write never actually succeeded' );

    like( $err, qr/STORE ERROR \[999\]: remove_failed_download failed - database is locked/,
        'the removal failure is logged non-fatally, classified' );
}

{
    # retry_failed_transcription: record_message succeeds, but
    # remove_failed_transcription itself then dies.
    my $store = D2TG::Store->new( db_path => fresh_db_path(), admin_chat_id => 1 );
    my $id    = $store->record_failed_transcription(
        999, 78, 'CCDDstillq',
        sender => 'ada', error => 'ffmpeg conversion failed',
    );

    package Fake::Store::DyingRemoveFailedTranscription;
    our @ISA = ('D2TG::Store');
    sub remove_failed_transcription { die "database is locked\n"; }
    package main;
    bless $store, 'Fake::Store::DyingRemoveFailedTranscription';

    my ($row) = grep { $_->{id} == $id } @{ $store->failed_transcriptions };
    ok( $row, 'queued failed transcription row exists' );

    my $telegram = Fake::DownloadTelegram->new( file_path => 'voice/still-queued.ogg' );
    my $response = HTTP::Response->new( 200, 'OK' );
    $response->content('fake ogg bytes');
    my $ua = Fake::UA->new( responses => [$response] );

    no warnings 'redefine', 'once';
    local *D2TG::Transcribe::transcribe = sub { return 'a recovered transcript, row not actually removed' };

    my $err = '';
    my ( $ok, $result, $still_queued );
    {
        open my $fh, '>', \$err or die $!;
        local *STDERR = $fh;
        ( $ok, $result, $still_queued ) =
          D2TG::Transcribe::Retry::retry_failed_transcription( $telegram, $store, $row, ua => $ua );
        close $fh;
    }

    ok( $ok, 'the transcript itself was genuinely recovered ($ok true)' );
    is( $result, 'a recovered transcript, row not actually removed', 'the transcript is returned' );
    ok( $still_queued,
        'still_queued is true when remove_failed_transcription itself fails after a successful record_message (RED until fixed)' );

    my @still = grep { $_->{id} == $id } @{ $store->failed_transcriptions };
    is( scalar(@still), 1, 'the row is genuinely still present in failed_transcriptions - the removal write never actually succeeded' );

    like( $err, qr/STORE ERROR \[999\]: remove_failed_transcription failed - database is locked/,
        'the removal failure is logged non-fatally, classified' );
}

done_testing();
