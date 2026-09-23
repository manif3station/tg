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

# TGT-311: matching cli/attachment.pl's own established --bot flag
# (D2TG::Store's messages table is bot_key-aware, TGT-232).
my ( $bot_token, @after_bot ) = D2TG::Reply::Args::extract_bot_flag_or_die(@ARGV);
@ARGV = @after_bot;
my $bot_key = defined $bot_token ? $bot_token : '';

# TGT-211's own established ordering: argv-shape validation runs
# BEFORE storage resolution, matching the majority sibling family.
if ( @ARGV != 2 || $ARGV[0] !~ /^-?\d+$/ || $ARGV[1] !~ /^\d+$/ ) {
    print STDERR "Usage: d2 tg.fetch [--bot <token>] <chat_id> <message_id> [--db <alias> | -d <alias>]\n";
    exit 2;
}
my ( $chat_id, $message_id ) = @ARGV;

my $base_dir = D2TG::Config::resolve_and_require_base_dir_or_die( alias => $db_alias );

# TGT-186's own established shape: goes through the shared
# D2TG::Poller::Safe::open_store_or_die helper - prints a clean,
# scrubbed refusal and exits 1 on a storage-open failure instead of
# letting the raw Perl/DBI exception (which can embed the real db
# path) propagate.
my $store = D2TG::Poller::Safe::open_store_or_die(
    skill_root    => File::Spec->catdir( $Bin, '..' ),
    base_dir      => $base_dir,
    admin_chat_id => D2TG::Config::chat_id(),
);

# TGT-293's own established shape: eval-wrapped, classified via
# D2TG::Poller::Safe::classify_store_error. TGT-314: the classify/print/
# exit shape itself now lives in D2TG::Poller::Safe::die_store_error.
my $message = eval { $store->get_message( $chat_id, $message_id, bot_key => $bot_key ) };
D2TG::Poller::Safe::die_store_error( $@, 'get_message' ) if $@;
if ( !defined $message ) {
    print STDERR "d2 tg.fetch: no message recorded for chat $chat_id message $message_id\n";
    exit 1;
}

print "$message->{summary}\n";

# TGT-311: read is marked only now, after the content was actually
# successfully retrieved and shown - mirroring D2TG::Reply::send_reply's
# own TGT-046 "only after success" invariant, so a message is never
# marked read for a fetch that didn't actually show anything. This is
# the whole point of this command: fetching and marking read are one
# action, not two - the agent never runs a separate mark-read step.
# TGT-336 (Q-021 answered by Michael): a mark_read failure at this point
# is different from a genuine fetch failure - the content above was
# already successfully shown. Exits 3 (not the shared die_store_error's
# 1) so a caller can tell "nothing was ever shown" apart from "shown,
# only the trailing housekeeping write failed" without re-parsing STDERR.
eval { $store->mark_read( $chat_id, $message_id, bot_key => $bot_key ) };
if ($@) {
    my $reason = D2TG::Poller::Safe::classify_store_error($@);
    print STDERR "STORE ERROR: mark_read failed - $reason\n";
    exit 3;
}

exit 0;

=head1 NAME

fetch - show a stored text/voice message's content and mark it read, dispatched as C<d2 tg.fetch>

=head1 SYNOPSIS

    d2 tg.fetch [--bot <token>] <chat_id> <message_id> [--db <alias> | -d <alias>]

=head1 DESCRIPTION

TGT-311 (explicit user-requested architecture change to the core
message-intake flow, direct chat request 2026-09-18): C<d2 tg.poller>
no longer prints a new text or successfully-transcribed-voice
message's own content inline in its stdout announcement - it prints
only chat_id/message_id and a C<FETCH WITH: d2 tg.fetch ...> command
template (alongside the existing C<REPLY WITH> template). This command
is the deliberate, explicit step that actually reveals the content.

Looks up the stored C<summary> for the given C<(chat_id, message_id)>
pair via L<D2TG::Store/get_message> and prints it to stdout, then
marks that message read via L<D2TG::Store/mark_read> - in that order,
so a message is only ever marked read once its content has actually
been successfully shown, matching C<D2TG::Reply::send_reply>'s own
TGT-046 "only after success" precedent. Fetching and marking read are
deliberately one action, not two - there is no separate command to
mark a message read.

C<--db>/C<-d> (or C<D2TG_DB>) resolves exactly as every other
C<d2 tg.*> command's does; the resolved base directory must already
exist (TGT-090). C<--bot <token>> scopes the lookup to that bot's own
recorded row, matching C<d2 tg.attachment>'s established convention;
omitting it acts on the single-bot sentinel. C<chat_id>/C<message_id>
must both be given and numeric (exit 2, Usage message, otherwise) -
C<chat_id> may be negative (a Telegram group/channel id). This check
runs before C<--db> storage resolution (TGT-211's own established
ordering), so a caller giving both a bad C<--db> and malformed
positional args gets a consistent exit 2/Usage rather than an exit
1/storage-error.

Refuses (exit 1, clear STDERR message) if no message is recorded for
that pair - nothing is ever marked read in that case, since there was
nothing to show. Both the C<get_message> lookup and the C<mark_read>
call are C<eval>-wrapped and classified via
C<D2TG::Poller::Safe::classify_store_error> - a locked/busy database
at either used to be able to die raw; now it prints a clean
C<STORE ERROR: ... failed - REASON> refusal instead.

TGT-336 (Q-021 answered by Michael, found via a live JOB-004 improvement
hunt): a C<mark_read> failure is reported with its own distinct exit
code, C<3>, not the same C<1> a genuine "nothing recorded" failure uses
- the content was already successfully shown by the time C<mark_read>
runs, so a caller checking only the exit code can now tell "fetch
genuinely failed, nothing shown" (still C<1>) apart from "content was
shown, only the trailing read-marking write failed" (C<3>).

This command intentionally does not handle photos/documents - those
already have their own fetch step, C<cli/attachment.pl>, which gained
this same mark-read-on-success behavior in the same ticket.

=cut
