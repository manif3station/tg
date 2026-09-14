#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;

use D2TG::Config;
use D2TG::Poller;
use D2TG::Store;
use D2TG::Telegram;
use D2TG::Download;
use D2TG::Reply;

my ( $db_alias, @rest );
( $db_alias, @rest ) = D2TG::Config::extract_db_flag_or_die(@ARGV);
@ARGV = @rest;

# TGT-219 (found via a scheduled JOB-004 improvement hunt): matching
# cli/approve.pl/cli/reply.pl's own established --bot flag (Telegram's
# file_id values are bot-token-scoped, so a queued failure recorded
# under a non-default bot must be retried as that same bot). Leading
# position, same as D2TG::Reply::extract_bot_flag's every other caller.
# TGT-236 centralized the eval-wrap idiom itself into
# D2TG::Reply::extract_bot_flag_or_die.
my ( $bot_token, @after_bot ) = D2TG::Reply::extract_bot_flag_or_die(@ARGV);
@ARGV = @after_bot;
my $bot_key = defined $bot_token ? $bot_token : '';

# TGT-211 (found via a scheduled JOB-004 improvement hunt): argv-shape
# validation now runs BEFORE storage resolution, matching the majority
# sibling family (cli/whoami.pl, cli/text-only-replies.pl, cli/unread.pl,
# cli/status.pl) - previously this ran after, so a caller with BOTH a
# bad --db alias and malformed positional args got an inconsistent
# exit 1/storage-error instead of the exit 2/Usage: every majority
# sibling gives for the same class of double-invalid-input.
if ( @ARGV > 1 || ( @ARGV == 1 && $ARGV[0] ne '--all' && $ARGV[0] !~ /^\d+$/ ) ) {
    print STDERR "Usage: d2 tg.retry-download [--bot <token>] [--db <alias> | -d <alias>] [<id> | --all]\n";
    exit 2;
}

my $base_dir = D2TG::Config::resolve_alias_dir_or_die( alias => $db_alias );

D2TG::Config::require_existing_base_dir_or_die($base_dir);

# TGT-186 (found via a scheduled JOB-003 hourly bug hunt, reproduced live):
# this call was unwrapped, the same raw-crash/db-path-leak risk TGT-183
# already fixed for cli/poller.pl's own equivalent call - not
# byte-identical args (poller.pl passes admin_chat_id as an arrayref of
# every configured group's chat_id; this script passes a plain scalar),
# but the same eval/classify/refuse shape. Now goes through the shared
# D2TG::Poller::open_store_or_die helper (TGT-186) - prints a clean,
# scrubbed refusal and exits 1 on a storage-open failure instead of
# letting the raw Perl/DBI exception (which can embed the real db path)
# propagate.
my $store = D2TG::Poller::open_store_or_die(
    skill_root    => File::Spec->catdir( $Bin, '..' ),
    base_dir      => $base_dir,
    admin_chat_id => D2TG::Config::chat_id(),
);

if ( !@ARGV ) {
    my $queued = $store->failed_downloads( bot_key => $bot_key );
    if ( !@$queued ) {
        print "No failed downloads queued.\n";
        exit 0;
    }
    for my $row (@$queued) {
        print "[$row->{id}] chat_id=$row->{chat_id} message_id=$row->{message_id} "
          . "file_id=$row->{file_id} error=\"$row->{error}\" queued_at=$row->{created_at}\n";
    }
    exit 0;
}

my $attachments_dir = D2TG::Config::attachments_dir(
    default_root => File::Spec->catdir( $Bin, '..' ),
    base_dir      => $base_dir,
);

my $telegram = D2TG::Telegram->new( token => defined $bot_token ? $bot_token : D2TG::Config::token() );

my @to_retry;
if ( $ARGV[0] eq '--all' ) {
    @to_retry = @{ $store->failed_downloads( bot_key => $bot_key ) };
    if ( !@to_retry ) {
        print "No failed downloads queued.\n";
        exit 0;
    }
}
else {
    my $id = $ARGV[0];
    my ($row) = grep { $_->{id} == $id } @{ $store->failed_downloads( bot_key => $bot_key ) };
    if ( !$row ) {
        print STDERR "No queued failed download with id $id.\n";
        exit 1;
    }
    @to_retry = ($row);
}

my $exit_code = 0;
for my $row (@to_retry) {
    my ( $ok, $result_or_error, $still_queued ) =
      D2TG::Download::retry_failed_download( $telegram, $store, $row, $attachments_dir );

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

    # TGT-247 (found via a scheduled JOB-003 hourly bug hunt,
    # live-reproduced): $ok alone does not mean the retry fully
    # completed. D2TG::Download::retry_failed_download's own 3rd return
    # value, $still_queued (TGT-244), is true when the download itself
    # succeeded but the follow-up record_message write then failed - the
    # row is deliberately left in the failed_downloads queue (never
    # removed) and NO row was ever written into the messages table, so
    # D2TG::Store::get_attachment_path has nothing to return yet. Printing
    # the ordinary RETRY OK/GET ATTACHMENT WITH line in this state told
    # the caller to run a d2 tg.attachment command that is guaranteed to
    # fail ("no attachment recorded"), with no indication anything was
    # still incomplete - retry_failed_download's own STORE ERROR STDERR
    # line (from D2TG::Download itself) is the only place that gap was
    # ever visible before this fix.
    if ($still_queued) {
        print "RETRY PARTIAL [$row->{id}] chat_id=$row->{chat_id} message_id=$row->{message_id} - "
          . "download succeeded but the history record could not be written yet; "
          . "the entry remains queued (still queued) and will be retried automatically, "
          . "or retry again with d2 tg.retry-download $row->{id}\n";
        $exit_code = 1;
        next;
    }

    # TGT-146: never print $result_or_error here - on success it is
    # D2TG::Download::retry_failed_download's raw local filesystem path
    # return value. This line reaches the target project's
    # tira.policy.bridge as monitor-output, so a real path would leak
    # onto a shared board - the same never-expose-the-real-path
    # convention TGT-133 already established for D2TG::Poller's own
    # media-download success path and cli/attachment.pl.
    print "RETRY OK [$row->{id}] chat_id=$row->{chat_id} message_id=$row->{message_id} - "
      . "GET ATTACHMENT WITH: d2 tg.attachment $row->{chat_id} $row->{message_id}\n";
}

exit $exit_code;

=head1 NAME

retry-download - list and retry queued failed media downloads, dispatched as C<d2 tg.retry-download>

=head1 SYNOPSIS

    d2 tg.retry-download [--bot <token>] [--db <alias> | -d <alias>]
    d2 tg.retry-download [--bot <token>] [--db <alias> | -d <alias>] <id>
    d2 tg.retry-download [--bot <token>] [--db <alias> | -d <alias>] --all

=head1 DESCRIPTION

C<--bot <token>> (TGT-219, found via a scheduled improvement hunt)
scopes both listing and retrying to that bot, using
L<D2TG::Reply/extract_bot_flag> - the same leading-position shape
C<cli/reply.pl>/C<cli/approve.pl>'s own C<--bot> use. Telegram's own
C<file_id> values are bot-token-scoped, so a failure queued under a
non-default bot in a multi-bot config must be retried as that same
bot; omitting it acts on the single-bot sentinel, matching every
existing single-bot install's behavior exactly.

TGT-104 (user-supplied feature-gap analysis): a transient inbound photo/
document download failure (a network hiccup mid-transfer, a momentary
server error) used to be reported once (a C<MEDIA DOWNLOAD ERROR> line
from C<cli/poller.pl>) and forgotten - no way to retry it later.
C<cli/poller.pl> now attempts to persist each such failure (chat_id,
message_id, file_id, sender, media kind, caption, the original error) to
L<D2TG::Store>'s C<failed_downloads> queue - a database-write failure
there is itself non-fatal, matching the download failure it's recording
- keyed uniquely by C<(chat_id, message_id)> so Telegram's own
at-least-once delivery redelivering the same failed update refreshes the
existing row instead of duplicating it; this command reads and acts on
that queue.

With no positional argument, lists every currently-queued failed
download - id, chat_id, message_id, file_id, the original error, and
when it was queued - or C<No failed downloads queued.> when empty.
Argv-shape validation (a leftover argument, or a value that's neither
numeric nor C<--all>) now runs before C<--db> storage resolution
(TGT-211, found via a scheduled improvement hunt) - matching the
majority sibling family, so a caller giving both a bad C<--db> and a
malformed positional argument gets a consistent exit 2/Usage rather
than an exit 1/storage-error.

With a numeric C<id>, retries exactly that queued entry via
L<D2TG::Download/retry_failed_download> - re-downloads using its saved
C<file_id>, and on success restores the message into L<D2TG::Store>'s
own history via C<record_message> (a Codex review caught that a retry
success originally only deleted the queue row, leaving nothing for
C<d2 tg.history>/C<d2 tg.unread> to ever show for a recovered file)
before removing the entry from the queue. Prints C<RETRY OK> on
success, naming the C<d2 tg.attachment> fetch command rather than the
real local filesystem path (TGT-146 - an earlier version of this line
printed the raw path directly, leaking it onto the target project's
C<tira.policy.bridge> as monitor-output; matches TGT-133's own
never-expose-the-real-path convention). With C<--all>, does the same
for every currently-queued entry in turn - one failure does not stop
the rest from being attempted.

A retry failure is reported on STDERR and the entry stays queued (it is
never removed on failure, only on success) so the operator can retry
again later or investigate. If the failure looks like Telegram's own
shape for a permanently-gone C<file_id> (L<D2TG::Config/is_expired_file_error> -
"file is no longer available"/"wrong file_id"), the STDERR line says
C<RETRY EXPIRED> - deliberately NOT for "file is temporarily
unavailable" (a Codex review caught an earlier draft treating that
wording as permanent too, when it describes a real transient condition
that can still succeed later) - so an operator staring at a queue full
of failures can tell which ones are worth retrying again and which are
genuinely, permanently gone.

C<--db>/C<-d> (or C<D2TG_DB>) and C<D2TG_TOKEN> resolve exactly as every
other C<d2 tg.*> command's do.

TGT-247 (found via a scheduled JOB-003 hourly bug hunt, live-reproduced
in a C<developer-dashboard:latest> container): C<RETRY OK> is only ever
printed once a retry is genuinely fully complete. Before this fix, the
retry loop discarded C<retry_failed_download>'s 3rd return value
(C<$still_queued>, TGT-244) entirely - so when the download itself
succeeded but the follow-up C<record_message> write then failed (a
transient locked/busy database), this script still printed the ordinary
C<RETRY OK .../GET ATTACHMENT WITH: d2 tg.attachment ...> line, even
though that exact command is guaranteed to fail (C<D2TG::Store::get_attachment_path>
reads C<local_path> from the C<messages> table, which was never written
in this case) and the row was, in fact, still sitting in the
C<failed_downloads> queue (never removed). This case now prints
C<RETRY PARTIAL> instead - naming the row as still queued for a future
automatic or manual (C<d2 tg.retry-download E<lt>idE<gt>>) retry - and
sets a non-zero exit code, rather than falsely claiming full success.

=cut
