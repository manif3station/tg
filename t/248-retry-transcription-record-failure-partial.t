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

# TGT-248 (found via a scheduled JOB-003 hourly bug hunt): the exact
# TGT-247 bug class in retry_failed_transcription's own documented
# structural sibling. D2TG::Transcribe::Retry::retry_failed_transcription always
# returned (1, $transcript) once download+transcription succeeded,
# regardless of whether the follow-up record_message write then
# succeeded - unlike retry_failed_download, which gained a 3rd
# $still_queued return value in TGT-244/TGT-247 for exactly this case.
# When record_message fails (a transient locked/busy database), the row
# is correctly left queued in failed_transcriptions (never removed) -
# but the caller had no way to know that, and cli/retry-transcription.pl
# printed an unconditional "RETRY OK [...]: <transcript>" with exit 0
# even though nothing was ever written to D2TG::Store's message history.

sub fresh_db_path {
    my $dir = tempdir( CLEANUP => 1 );
    return File::Spec->catfile( $dir, 'store.sqlite' );
}

package Fake::DownloadTelegram;

sub new {
    my ( $class, %args ) = @_;
    return bless { file_path => $args{file_path} }, $class;
}

sub get_file {
    my ( $self, $file_id ) = @_;
    return $self->{file_path};
}

sub file_download_url {
    my ( $self, $file_path ) = @_;
    return "https://api.telegram.org/file/bottest-token/$file_path";
}

package Fake::UA;

sub new { my ( $class, %args ) = @_; return bless { responses => $args{responses} || [] }, $class; }
sub get { my ($self) = @_; return shift @{ $self->{responses} }; }

package main;

{
    # Download + transcription succeed, but record_message dies (e.g.
    # database locked). The row must stay queued, and the function must
    # NOT report an unqualified success - callers need a way to tell
    # this apart from a fully-completed retry.
    my $store = D2TG::Store->new( db_path => fresh_db_path(), admin_chat_id => 1 );
    my $id    = $store->record_failed_transcription(
        999, 88, 'CCDDpartial',
        sender => 'ada', error => 'ffmpeg conversion failed',
    );

    package Fake::Store::DyingRecordMessage;
    our @ISA = ('D2TG::Store');
    sub record_message { die "database is locked\n"; }
    package main;
    bless $store, 'Fake::Store::DyingRecordMessage';

    my ($row) = grep { $_->{id} == $id } @{ $store->failed_transcriptions };
    ok( $row, 'queued failed transcription row exists' );

    my $telegram = Fake::DownloadTelegram->new( file_path => 'voice/partial.ogg' );
    my $response = HTTP::Response->new( 200, 'OK' );
    $response->content('fake ogg bytes');
    my $ua = Fake::UA->new( responses => [$response] );

    no warnings 'redefine', 'once';
    local *D2TG::Transcribe::transcribe = sub { return 'a recovered but unrecorded transcript' };

    my $err = '';
    my ( $ok, $result, $still_queued );
    {
        open my $fh, '>', \$err or die $!;
        local *STDERR = $fh;
        ( $ok, $result, $still_queued ) =
          D2TG::Transcribe::Retry::retry_failed_transcription( $telegram, $store, $row, ua => $ua );
        close $fh;
    }

    ok( $ok, 'the low-level function still reports the transcript was genuinely recovered ($ok true)' );
    is( $result, 'a recovered but unrecorded transcript', 'the transcript itself is returned' );
    ok( $still_queued, 'a 3rd return value signals the record_message write failed, so the row is still queued (RED until fixed)' );

    my @still = grep { $_->{id} == $id } @{ $store->failed_transcriptions };
    is( scalar(@still), 1, 'the row is still present in failed_transcriptions - never removed on a partial failure' );

    ok( !$store->get_message( 999, 88 ), 'no message was ever recorded into history for this id' );

    like( $err, qr/STORE ERROR \[999\]: record_message failed/, 'record_message failure is logged non-fatally' );
}

{
    # Full success: record_message succeeds, row is removed, no
    # still-queued signal.
    my $store = D2TG::Store->new( db_path => fresh_db_path(), admin_chat_id => 1 );
    my $id    = $store->record_failed_transcription(
        999, 89, 'CCDDfull',
        sender => 'ada', error => 'ffmpeg conversion failed',
    );
    my ($row) = grep { $_->{id} == $id } @{ $store->failed_transcriptions };

    my $telegram = Fake::DownloadTelegram->new( file_path => 'voice/full.ogg' );
    my $response = HTTP::Response->new( 200, 'OK' );
    $response->content('fake ogg bytes');
    my $ua = Fake::UA->new( responses => [$response] );

    no warnings 'redefine', 'once';
    local *D2TG::Transcribe::transcribe = sub { return 'a fully recorded transcript' };

    my ( $ok, $result, $still_queued ) =
      D2TG::Transcribe::Retry::retry_failed_transcription( $telegram, $store, $row, ua => $ua );

    ok( $ok, 'success reported' );
    is( $result, 'a fully recorded transcript', 'transcript returned' );
    ok( !$still_queued, 'still_queued is false/undef on a fully-completed retry' );
    is_deeply( $store->failed_transcriptions, [], 'the queue row is removed once record_message succeeds' );
    ok( $store->get_message( 999, 89 ), 'the message is restored into history' );
}

done_testing();
