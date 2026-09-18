#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;

use D2TG::Config;
use D2TG::Config::Flags;
use D2TG::Poller::Safe;
use D2TG::Store;
use D2TG::Telegram;
use D2TG::Download;
use D2TG::Transcribe;
use D2TG::Transcribe::Retry;
use D2TG::Reply;
use D2TG::Reply::Args;

my ( $db_alias, @rest );
( $db_alias, @rest ) = D2TG::Config::Flags::extract_db_flag_or_die(@ARGV);
@ARGV = @rest;

# TGT-237: matching cli/retry-download.pl's own established --bot flag
# (Telegram's file_id values are bot-token-scoped, so a queued failure
# recorded under a non-default bot must be retried as that same bot).
my ( $bot_token, @after_bot ) = D2TG::Reply::Args::extract_bot_flag_or_die(@ARGV);
@ARGV = @after_bot;
my $bot_key = defined $bot_token ? $bot_token : '';

if ( @ARGV > 1 || ( @ARGV == 1 && $ARGV[0] ne '--all' && $ARGV[0] !~ /^\d+$/ ) ) {
    print STDERR "Usage: d2 tg.retry-transcription [--bot <token>] [--db <alias> | -d <alias>] [<id> | --all]\n";
    exit 2;
}

my $base_dir = D2TG::Config::resolve_and_require_base_dir_or_die( alias => $db_alias );

my $store = D2TG::Poller::Safe::open_store_or_die(
    skill_root    => File::Spec->catdir( $Bin, '..' ),
    base_dir      => $base_dir,
    admin_chat_id => D2TG::Config::chat_id(),
);

if ( !@ARGV ) {
    my $queued = $store->failed_transcriptions( bot_key => $bot_key );
    if ( !@$queued ) {
        print "No failed transcriptions queued.\n";
        exit 0;
    }
    for my $row (@$queued) {
        print "[$row->{id}] chat_id=$row->{chat_id} message_id=$row->{message_id} "
          . "file_id=$row->{file_id} error=\"$row->{error}\" queued_at=$row->{created_at}\n";
    }
    exit 0;
}

my $telegram = D2TG::Telegram->new( token => defined $bot_token ? $bot_token : D2TG::Config::token() );

my @to_retry;
if ( $ARGV[0] eq '--all' ) {
    @to_retry = @{ $store->failed_transcriptions( bot_key => $bot_key ) };
    if ( !@to_retry ) {
        print "No failed transcriptions queued.\n";
        exit 0;
    }
}
else {
    my $id = $ARGV[0];
    my ($row) = grep { $_->{id} == $id } @{ $store->failed_transcriptions( bot_key => $bot_key ) };
    if ( !$row ) {
        print STDERR "No queued failed transcription with id $id.\n";
        exit 1;
    }
    @to_retry = ($row);
}

my $exit_code = 0;
for my $row (@to_retry) {
    my ( $ok, $result_or_error, $still_queued ) =
      D2TG::Transcribe::Retry::retry_failed_transcription( $telegram, $store, $row );

    if ( !$ok ) {
        if ( D2TG::Config::is_expired_file_error($result_or_error) ) {
            print STDERR "RETRY EXPIRED [$row->{id}] chat_id=$row->{chat_id} message_id=$row->{message_id}: "
              . "Telegram reports this file_id as permanently gone (not merely a transient failure) - $result_or_error\n";
        }
        else {
            print STDERR "RETRY FAILED [$row->{id}] chat_id=$row->{chat_id} message_id=$row->{message_id}: $result_or_error\n";
        }
        $exit_code = 1;
        next;
    }

    # TGT-248 (found via a scheduled JOB-003 hourly bug hunt): $ok alone
    # does not mean the retry fully completed. retry_failed_transcription's
    # own 3rd return value, $still_queued, is true when the transcript
    # was genuinely recovered but the follow-up record_message write then
    # failed - the row stays queued (never removed) and NO row was ever
    # written into the messages table. Printing the ordinary RETRY OK
    # line in this state falsely claimed full success, mirroring the
    # exact bug TGT-247 already fixed in cli/retry-download.pl.
    if ($still_queued) {
        print "RETRY PARTIAL [$row->{id}] chat_id=$row->{chat_id} message_id=$row->{message_id} - "
          . "transcript recovered but the history record could not be written yet; "
          . "the entry remains queued (still queued) and will be retried automatically, "
          . "or retry again with d2 tg.retry-transcription $row->{id}\n";
        $exit_code = 1;
        next;
    }

    # TGT-146's own never-expose-the-real-path convention doesn't apply
    # here - a transcript is text, not a filesystem path, so it's safe
    # to print directly (matching NEW TG VOICE's own success-path line).
    my $safe_transcript = $result_or_error;
    $safe_transcript =~ s/[\r\n]+/ /g;
    print "RETRY OK [$row->{id}] chat_id=$row->{chat_id} message_id=$row->{message_id}: $safe_transcript\n";
}

exit $exit_code;

=head1 NAME

retry-transcription - list and retry queued failed voice transcriptions, dispatched as C<d2 tg.retry-transcription>

=head1 SYNOPSIS

    d2 tg.retry-transcription [--bot <token>] [--db <alias> | -d <alias>]
    d2 tg.retry-transcription [--bot <token>] [--db <alias> | -d <alias>] <id>
    d2 tg.retry-transcription [--bot <token>] [--db <alias> | -d <alias>] --all

=head1 DESCRIPTION

TGT-237 (found via a scheduled JOB-003 hourly bug hunt): a failed
voice transcription used to be reported once (a C<TRANSCRIBE ERROR>
line to STDERR from C<cli/poller.pl>) and permanently lost - no queue,
no retry, unlike photo/document downloads (L<D2TG::Store/failed_downloads>,
TGT-104). C<cli/poller.pl> now persists each such failure (chat_id,
message_id, the Telegram C<file_id>, sender, the original error) to
L<D2TG::Store>'s C<failed_transcriptions> queue - a database-write
failure there is itself non-fatal, matching the transcription failure
it's recording; this command reads and acts on that queue.

C<--bot <token>> scopes both listing and retrying to that bot, matching
C<d2 tg.retry-download>'s own established convention - Telegram's own
C<file_id> values are bot-token-scoped, so a failure queued under a
non-default bot in a multi-bot config must be retried as that same
bot; omitting it acts on the single-bot sentinel.

With no positional argument, lists every currently-queued failed
transcription - id, chat_id, message_id, file_id, the original error,
and when it was queued - or C<No failed transcriptions queued.> when
empty. Argv-shape validation (a leftover argument, or a value that's
neither numeric nor C<--all>) runs before C<--db> storage resolution,
matching C<cli/retry-download.pl>'s own established ordering.

With a numeric C<id>, retries exactly that queued entry via
L<retry_failed_transcription()|D2TG::Transcribe::Retry/retry_failed_transcription($telegram, $store, $row, ua =E<gt> $optional_client)> - re-downloads the voice
file using its saved C<file_id> (transiently, never landing in the
shared attachments vault, matching C<cli/poller.pl>'s own
C<$transcribe_voice> coderef) and re-attempts transcription; on
success, restores the message into L<D2TG::Store>'s own history via
C<record_message> before removing the queue entry. Prints C<RETRY OK>
naming the recovered transcript text directly (unlike
C<retry-download.pl>'s C<RETRY OK>, which deliberately never prints a
real local filesystem path - a transcript is text, not a path, so no
equivalent leak risk exists here). With C<--all>, does the same for
every currently-queued entry in turn - one failure does not stop the
rest.

A retry failure is reported on STDERR and the entry stays queued (never
removed on failure). If the failure looks like Telegram's own shape
for a permanently-gone C<file_id> (L<D2TG::Config/is_expired_file_error>),
the STDERR line says C<RETRY EXPIRED> instead of C<RETRY FAILED>,
matching C<retry-download.pl>'s own established distinction.

C<--db>/C<-d> (or C<D2TG_DB>) and C<D2TG_TOKEN> resolve exactly as
every other C<d2 tg.*> command's do.

TGT-248 (found via a scheduled JOB-003 hourly bug hunt): C<RETRY OK> is
only ever printed once a retry is genuinely fully complete - the exact
same fix TGT-247 already made in C<cli/retry-download.pl>. Before this
fix, this script discarded C<retry_failed_transcription>'s 3rd return
value entirely, so when the transcript was genuinely recovered but the
follow-up C<record_message> write then failed (a transient locked/busy
database), it still printed the ordinary C<RETRY OK ...: <transcript>>
line and exited 0, even though nothing was written to
L<D2TG::Store>'s message history and the row was, in fact, still sitting
in the C<failed_transcriptions> queue (never removed). This case now
prints C<RETRY PARTIAL> instead - naming the row as still queued for a
future automatic or manual (C<d2 tg.retry-transcription E<lt>idE<gt>>)
retry - and sets a non-zero exit code, rather than falsely claiming full
success.

=cut
