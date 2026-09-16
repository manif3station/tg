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

# TGT-245 (found via a scheduled JOB-003 hourly bug hunt): TGT-232
# migrated the messages table to a (chat_id, message_id, bot_key)
# composite key and threaded bot_key through every record_message call
# site it enumerated (D2TG::Poller, cli/history.pl, cli/unread.pl,
# cli/attachment.pl, cli/reply.pl) - it never enumerated or updated
# D2TG::Download::retry_failed_download/retry_failed_transcription,
# which also call record_message. Both queue rows already carry their
# own bot_key (TGT-219/TGT-237), but neither retry function passed it
# through, so a successfully retried message in a multi-bot config was
# silently recorded under D2TG::Store::DEFAULT_BOT_KEY instead of the
# bot that actually received it.

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
    # retry_failed_download: a row queued under a non-default bot_key,
    # once successfully retried, must restore history under that SAME
    # bot_key - not the default sentinel.
    my $dir   = tempdir( CLEANUP => 1 );
    my $store = D2TG::Store->new( db_path => fresh_db_path(), admin_chat_id => 1 );
    my $id    = $store->record_failed_download(
        999, 55, 'AABBbotscoped',
        sender => 'ada', media_kind => 'document', caption_note => '',
        error  => 'HTTP request failed (status 500)', bot_key => 'bot-B-token',
    );

    my ($row) = grep { $_->{id} == $id } @{ $store->failed_downloads( bot_key => 'bot-B-token' ) };
    ok( $row, 'queued row is scoped to bot-B-token' );

    my $telegram = Fake::DownloadTelegram->new( file_path => 'documents/scoped.pdf' );
    my $response = HTTP::Response->new( 200, 'OK' );
    $response->content('scoped bytes');
    my $ua = Fake::UA->new( responses => [$response] );

    my ($ok) = D2TG::Download::retry_failed_download( $telegram, $store, $row, $dir, ua => $ua );
    ok( $ok, 'retry_failed_download reports success' );

    my $under_bot_b  = $store->get_message( 999, 55, bot_key => 'bot-B-token' );
    my $under_default = $store->get_message( 999, 55 );

    ok( $under_bot_b, 'the restored message is recorded under the ORIGINAL bot_key (bot-B-token)' );
    ok( !$under_default, 'the restored message is NOT recorded under the default bot_key sentinel' );
}

{
    # retry_failed_transcription: same guarantee.
    my $store = D2TG::Store->new( db_path => fresh_db_path(), admin_chat_id => 1 );
    my $id    = $store->record_failed_transcription(
        999, 56, 'CCDDbotscoped',
        sender => 'ada', error => 'ffmpeg conversion failed', bot_key => 'bot-B-token',
    );

    my ($row) = grep { $_->{id} == $id } @{ $store->failed_transcriptions( bot_key => 'bot-B-token' ) };
    ok( $row, 'queued transcription row is scoped to bot-B-token' );

    my $telegram = Fake::DownloadTelegram->new( file_path => 'voice/scoped.ogg' );
    my $response = HTTP::Response->new( 200, 'OK' );
    $response->content('fake ogg bytes');
    my $ua = Fake::UA->new( responses => [$response] );

    no warnings 'redefine', 'once';
    local *D2TG::Transcribe::transcribe = sub { return 'a recovered transcript' };

    my ($ok) = D2TG::Transcribe::Retry::retry_failed_transcription( $telegram, $store, $row, ua => $ua );
    ok( $ok, 'retry_failed_transcription reports success' );

    my $under_bot_b   = $store->get_message( 999, 56, bot_key => 'bot-B-token' );
    my $under_default = $store->get_message( 999, 56 );

    ok( $under_bot_b, 'the restored transcript message is recorded under the ORIGINAL bot_key (bot-B-token)' );
    ok( !$under_default, 'the restored transcript message is NOT recorded under the default bot_key sentinel' );
}

done_testing();
