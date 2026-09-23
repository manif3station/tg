#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;

use D2TG::Config;
use D2TG::Config::Flags;
use D2TG::Reply::Args;

my ( $db_alias, @rest );
( $db_alias, @rest ) = D2TG::Config::Flags::extract_db_flag_or_die(@ARGV);
@ARGV = @rest;

# TGT-340 (found via a live, user-requested adversarial improvement
# hunt): every other d2 tg.* command that scopes an operation to a
# specific bot already uses this same leading-position, eval-wrapped
# extract_bot_flag_or_die convention - this command was the one
# sanity-check command left without any way to ask about a bot other
# than D2TG_TOKEN in a multi-bot install.
my ( $bot_token, @after_bot ) = D2TG::Reply::Args::extract_bot_flag_or_die(@ARGV);
@ARGV = @after_bot;

if (@ARGV) {
    print STDERR "Usage: d2 tg.whoami [--bot <token>] [--db <alias> | -d <alias>]\n";
    exit 2;
}

my $base_dir = D2TG::Config::resolve_and_require_base_dir_or_die( alias => $db_alias );

my $skill_root = File::Spec->catdir( $Bin, '..' );
my $version    = D2TG::Config::skill_version( default_root => $skill_root );

my $state_db_path   = D2TG::Config::state_db_path( default_root => $skill_root, base_dir => $base_dir );
my $attachments_dir = D2TG::Config::attachments_dir( default_root => $skill_root, base_dir => $base_dir );

my $chat_id = D2TG::Config::chat_id();

print "d2tg version: $version\n";
print "token: " . D2TG::Config::masked_token( $bot_token // D2TG::Config::token() ) . "\n";
print "chat_id: " . ( defined $chat_id && length $chat_id ? $chat_id : '(not set)' ) . "\n";
print "storage: $state_db_path\n";
print "attachments: $attachments_dir\n";

exit 0;

=head1 NAME

whoami - report which token/chat/storage a d2 tg.* invocation is actually configured for, dispatched as C<d2 tg.whoami>

=head1 SYNOPSIS

    d2 tg.whoami [--bot <token>] [--db <alias> | -d <alias>]

=head1 DESCRIPTION

C<--db>/C<-d> is resolved via L<D2TG::Config::Flags/extract_db_flag> (TGT-124,
found via a scheduled improvement-hunt fixing a hand-rolled duplicate
loop), the same shared helper every other C<d2 tg.*> command uses.

C<--bot <token>> (TGT-340, found via a live, user-requested adversarial
improvement hunt) reports that specific token's own masked value
instead of C<D2TG_TOKEN>'s - matching L<D2TG::Reply::Args/extract_bot_flag>'s
established leading-position convention, already used by
C<cli/fetch.pl>/C<cli/attachment.pl>/C<cli/history.pl>/C<cli/unread.pl>/
C<cli/approve.pl>/C<cli/retry-download.pl>/C<cli/retry-transcription.pl>.
Before this, a multi-bot install (TGT-049) had no way to confirm a
non-default bot's own token via this command - only ever
C<D2TG_TOKEN>. C<chat_id> is unaffected either way, since it is a
single global env var, not a per-bot value. Omitting C<--bot> is
byte-for-byte unchanged from before this ticket.

TGT-115 (user-supplied feature-gap analysis): with several projects on
this host each running their own installed copy of this skill under
different Developer Dashboard path aliases, there was no cheap way to
confirm which project's bot token/chat id/storage location a given
shell's env vars actually resolve to, short of either reading
C<D2TG_TOKEN>/C<D2TG_CHAT_ID>/C<D2TG_DB> by hand or risking a real
C<d2 tg.poller> startup (or a live C<d2 tg.reply> send) just to find
out.

Prints the installed C<VERSION>, the masked token
(L<D2TG::Config/masked_token> - never the raw token), the configured
C<chat_id> (or C<(not set)>), and the resolved storage/attachments
location (L<D2TG::Config/state_db_path>/C<attachments_dir>) - the exact
same resolution every other C<d2 tg.*> command uses via C<--db>/C<-d>/
C<D2TG_DB> (or a C<TIRA_HOME> fallback). Makes no HTTP request at all
(never loads L<D2TG::Telegram>) - safe to run at any time, including
with a completely unconfigured/misconfigured token, as the first sanity
check before trusting anything else this skill reports.

C<--db>/C<-d> (or C<D2TG_DB>) resolves exactly as every other C<d2 tg.*>
command's does; the resolved base directory must already exist
(TGT-090), same as elsewhere.

The token is always masked (a Codex review confirmed C<chat_id> is
NOT masked, and the resolved paths are printed in full) - deliberate:
C<chat_id> and filesystem paths are operational metadata, not secrets
on the same level as a bot token. Printing an unmasked C<chat_id>
follows C<cli/poller.pl>'s own existing startup-line precedent
(TGT-045); the resolved storage/attachments paths are new information
this command adds beyond what that precedent covers, not something
already exposed elsewhere - a second Codex review pass caught that an
earlier draft overstated the comparison as "no more sensitive overall"
when it only actually holds for the token/chat_id half. Still, this
output can end up in shell scrollback or captured logs like any other
command's - avoid pasting it somewhere the storage path or chat_id
shouldn't be seen, the same caution that already applies to any
`d2 tg.*` command's own output.
C<masked_token>'s own short-token behavior (TGT-138: a token of length
<= 8 is shown as the fixed placeholder C<(short token, not shown)>,
never shown as-is) is pre-existing D2TG::Config design already relied
on by C<cli/status.pl> and C<cli/poller.pl> - unchanged by this
ticket, which only reports whatever C<masked_token> already returns.

=cut
