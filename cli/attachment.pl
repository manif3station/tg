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
use D2TG::Reply;
use D2TG::Reply::Args;

my ( $db_alias, @rest );
( $db_alias, @rest ) = D2TG::Config::Flags::extract_db_flag_or_die(@ARGV);
@ARGV = @rest;

# TGT-233 (fast-follow from TGT-232's own scope decision): TGT-232 made
# D2TG::Store's messages table bot_key-aware, but this script had no
# --bot flag at all - matching cli/retry-download.pl's own established
# leading-position convention. TGT-236 centralized the eval-wrap idiom
# itself into D2TG::Reply::Args::extract_bot_flag_or_die.
my ( $bot_token, @after_bot ) = D2TG::Reply::Args::extract_bot_flag_or_die(@ARGV);
@ARGV = @after_bot;
my $bot_key = defined $bot_token ? $bot_token : '';

# TGT-211 (found via a scheduled JOB-004 improvement hunt): argv-shape
# validation now runs BEFORE storage resolution, matching the majority
# sibling family (cli/whoami.pl, cli/text-only-replies.pl, cli/unread.pl,
# cli/status.pl) - previously this ran after, so a caller with BOTH a
# bad --db alias and malformed positional args got an inconsistent
# exit 1/storage-error instead of the exit 2/Usage: every majority
# sibling gives for the same class of double-invalid-input.
if ( @ARGV != 2 || $ARGV[0] !~ /^-?\d+$/ || $ARGV[1] !~ /^\d+$/ ) {
    print STDERR "Usage: d2 tg.attachment [--bot <token>] <chat_id> <message_id> [--db <alias> | -d <alias>]\n";
    exit 2;
}
my ( $chat_id, $message_id ) = @ARGV;

my $base_dir = D2TG::Config::resolve_and_require_base_dir_or_die( alias => $db_alias );

# TGT-186 (found via a scheduled JOB-003 hourly bug hunt, reproduced live):
# this call was unwrapped, the same raw-crash/db-path-leak risk TGT-183
# already fixed for cli/poller.pl's own equivalent call - not
# byte-identical args (poller.pl passes admin_chat_id as an arrayref of
# every configured group's chat_id; this script passes a plain scalar),
# but the same eval/classify/refuse shape. Now goes through the shared
# D2TG::Poller::Safe::open_store_or_die helper (TGT-186) - prints a clean,
# scrubbed refusal and exits 1 on a storage-open failure instead of
# letting the raw Perl/DBI exception (which can embed the real db path)
# propagate.
my $store = D2TG::Poller::Safe::open_store_or_die(
    skill_root    => File::Spec->catdir( $Bin, '..' ),
    base_dir      => $base_dir,
    admin_chat_id => D2TG::Config::chat_id(),
);

# TGT-293 (found via a user-requested comprehensive bug/improvement
# sweep): this call ran unwrapped - the same raw-crash/db-path-leak
# risk TGT-183/186/195 already fixed for other call sites in this
# project, just never swept this widely.
my $local_path = eval { $store->get_attachment_path( $chat_id, $message_id, bot_key => $bot_key ) };
D2TG::Poller::Safe::die_store_error( $@, 'get_attachment_path' ) if $@;
if ( !defined $local_path ) {
    print STDERR "d2 tg.attachment: no attachment recorded for chat $chat_id message $message_id\n";
    exit 1;
}

# TGT-134: a recorded local_path never expires from the database, but
# an existing path pointing at a directory (never legitimately recorded
# by this skill, but worth rejecting explicitly rather than silently
# printing nothing - open() on a directory succeeds, only reading from
# it fails) gets its own message before ever attempting to read it.
# Re-checked on the already-open filehandle below too (a Codex review
# finding: this pre-check and the open() are two separate syscalls, so
# the path could change in between - re-testing -f on the filehandle
# itself, not the path, closes that race for good).
if ( -e $local_path && !-f $local_path ) {
    print STDERR "d2 tg.attachment: the stored attachment path is not a regular file\n";
    exit 1;
}

open my $fh, '<', $local_path
  or do {
    # TGT-134: D2TG::Download::prune_vault runs after every poll cycle
    # and evicts the oldest-mtime attachments once the vault exceeds its
    # byte cap - the file a local_path names can disappear at any later
    # time, even though the database record of it never expires.
    # Classified from open()'s own errno (a Codex review finding: a
    # plain -e/-f pre-check can misreport an unrelated permissions
    # failure - e.g. an unsearchable parent directory - as "pruned",
    # since that also makes -e false without the file actually being
    # gone) rather than a separate existence check.
    if ( $!{ENOENT} ) {
        print STDERR "d2 tg.attachment: the stored attachment no longer exists on disk "
          . "(likely pruned by D2TG::Download::prune_vault's own byte-cap eviction - "
          . "fetching is only reliable for attachments still within the vault's retained set)\n";
    }
    else {
        print STDERR "d2 tg.attachment: cannot open the stored attachment: $!\n";
    }
    exit 1;
  };

# TGT-134 (Codex review finding): re-check on the already-open handle,
# not the path - the pre-open -f check above and this open() are two
# separate syscalls, so the path could in principle change in between
# (e.g. replaced by a directory). Testing -f on $fh itself is race-free.
if ( !-f $fh ) {
    print STDERR "d2 tg.attachment: the stored attachment path is not a regular file\n";
    close $fh;
    exit 1;
}

binmode $fh;
binmode STDOUT;
local $/;
print scalar <$fh>;
close $fh;

# TGT-311: read is marked only now, after the attachment's bytes were
# actually successfully streamed - mirroring cli/fetch.pl's own "only
# after success" placement (itself matching D2TG::Reply::send_reply's
# TGT-046 precedent). Fetching and marking read are one action, not
# two - the agent never runs a separate mark-read step for a media
# message either.
eval { $store->mark_read( $chat_id, $message_id, bot_key => $bot_key ) };
D2TG::Poller::Safe::die_store_error( $@, 'mark_read' ) if $@;

exit 0;

=head1 NAME

attachment - stream a downloaded attachment's raw bytes to stdout, dispatched as C<d2 tg.attachment>

=head1 SYNOPSIS

    d2 tg.attachment [--bot <token>] <chat_id> <message_id> [--db <alias> | -d <alias>]

=head1 DESCRIPTION

C<--db <alias>>/C<-d <alias>> (TGT-051, or C<D2TG_DB=<alias>> as a
fallback) resolves the same way C<d2 tg.poller>'s does - see
L<D2TG::Config/resolve_alias_dir>. The resolved directory (or a
C<TIRA_HOME> fallback) must already exist - refuses to start otherwise
rather than creating it (TGT-090).

C<--bot <token>> (TGT-233) scopes the lookup to that bot's own recorded
row, matching C<d2 tg.retry-download>'s established C<--bot>
convention; omitting it preserves the default-bot lookup below
unchanged.

TGT-133: looks up C<local_path> for the given C<(chat_id, message_id)>
pair via L<D2TG::Store/get_attachment_path> and writes its raw bytes
to stdout - the real on-disk path is never printed anywhere, matching
this project's own Tira board convention (C<tira.attachment.get>).
Refuses (exit 1, clear STDERR message) if no attachment is recorded for
that pair, or if the stored path can no longer be opened. C<chat_id>
and C<message_id> must both be given and numeric (exit 2, Usage
message, otherwise) - C<chat_id> may be negative (a Telegram group/
channel id). This check now runs before C<--db> storage resolution
(TGT-211, found via a scheduled improvement hunt) - matching the
majority sibling family (C<cli/whoami.pl>, C<cli/text-only-replies.pl>,
C<cli/unread.pl>, C<cli/status.pl>), so a caller giving both a bad
C<--db> and malformed positional args gets a consistent exit 2/Usage
rather than an exit 1/storage-error.

TGT-134: fetching is not permanently guaranteed - C<local_path> never
expires from the database, but the file it names can be evicted at any
later time by L<D2TG::Download/prune_vault>'s own byte-cap eviction
(run after every poll cycle by C<cli/poller.pl>) if this attachment is
old and nobody re-fetched it (a dedup hit refreshes its mtime, TGT-054,
protecting anything actually re-used). An C<open> failure whose errno is
C<ENOENT> (checked via C<%!>, not a separate pre-check - a plain C<-e>
test can misreport an unrelated permissions failure, e.g. an
unsearchable parent directory, as "gone") names pruning as the likely
cause; a path that exists but isn't a regular file gets its own message
before C<open> is ever attempted, and again immediately after a
successful C<open> (a Codex review finding: the pre-open check and
C<open> are two separate syscalls, so the path could in principle
change in between - re-testing C<-f> on the open filehandle itself,
not the path, closes that race); any other C<open> failure (e.g. a
genuine permissions problem) falls back to the generic message naming
C<$!>.

The C<get_attachment_path> lookup itself (TGT-293, found via a
user-requested comprehensive bug/improvement sweep) is C<eval>-wrapped
and classified via C<D2TG::Poller::Safe::classify_store_error> - a
locked/busy database at that call used to die raw, printing a raw
Perl/DBI exception (potentially embedding the real db_path) to STDERR
instead of a clean C<STORE ERROR: ... failed - REASON> refusal.

TGT-311 (explicit user-requested architecture change to the core
message-intake flow): once the attachment's bytes have actually been
successfully streamed to stdout, this command also marks the message
read via L<D2TG::Store/mark_read> - matching C<cli/fetch.pl>'s own
identical "only after success" placement (itself matching
C<D2TG::Reply::send_reply>'s TGT-046 precedent). Fetching an attachment
and marking its message read are one action, not two.

=cut
