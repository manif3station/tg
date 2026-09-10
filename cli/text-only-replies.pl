#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;

use D2TG::Config;
use D2TG::Store;

my ( $db_alias, @rest );
eval { ( $db_alias, @rest ) = D2TG::Config::extract_db_flag(@ARGV) };
if ($@) {
    print STDERR $@;
    exit 1;
}
@ARGV = @rest;

if (@ARGV) {
    print STDERR "Usage: d2 tg.text-only-replies [--db <alias> | -d <alias>]\n";
    exit 2;
}

my $base_dir = D2TG::Config::resolve_alias_dir_or_die( alias => $db_alias );

eval { D2TG::Config::require_existing_base_dir($base_dir) };
if ($@) {
    print STDERR $@;
    exit 1;
}

my $store = D2TG::Store->new(
    db_path => D2TG::Config::state_db_path(
        default_root => File::Spec->catdir( $Bin, '..' ),
        base_dir      => $base_dir,
    ),
    admin_chat_id => D2TG::Config::chat_id(),
);

my $flagged = $store->text_only_replies;

if ( !@$flagged ) {
    print "No text-only replies found.\n";
    exit 0;
}

for my $row (@$flagged) {
    my $bot_note = length( $row->{bot_key} // '' ) ? " bot=$row->{bot_key}" : '';
    print "[chat_id=$row->{chat_id}]$bot_note msg #$row->{text_message_id} sent ($row->{created_at}) "
      . "went out text-only - no voice note ever confirmed sent.\n";
}

exit 1;

=head1 NAME

text-only-replies - list any reply that went out as text-only, dispatched as C<d2 tg.text-only-replies>

=head1 SYNOPSIS

    d2 tg.text-only-replies [--db <alias> | -d <alias>]

=head1 DESCRIPTION

TGT-105 (user-supplied feature-gap analysis): TGT-083 deliberately
reordered L<D2TG::Reply/send_reply> to send text first, then
synthesize+send voice - a synthesis or C<send_voice> failure after that
point can leave a reply text-only, always reported loudly (non-zero
exit) at the moment it happens, per that ticket's own documented
tradeoff. If that loud failure is missed (the agent wasn't watching, the
error scrolled past), there was previously no way to find out later.

C<D2TG::Reply::send_reply> now records every text send via
L<D2TG::Store/record_sent_text> immediately after it succeeds, and
records the matching voice send via L<D2TG::Store/record_sent_voice>
once that also succeeds; a row still missing its voice half IS the
text-only condition (no separate boolean flag to fall out of sync).
C<D2TG::Reply::resend_voice> (TGT-109's own recovery path) clears the
flag the same way when a voice recovery succeeds.

Lists every currently-flagged reply across every configured bot (a
Codex review finding: C<sent_replies> is scoped by C<bot_key> the same
way C<allow_list>/C<pending> already are, TGT-098's own lesson, so one
bot's replies never mask or get confused with another's sharing the
same C<chat_id> in a group both bots are members of) - chat_id, the bot
key (omitted from the line for the common single-bot case, where it's
empty), the text message's own id, and when it was sent - or C<No
text-only replies found.> when clean. Exits 1 when anything is flagged
(0 when clean), matching this project's other after-the-fact checker
conventions, so this command is suitable for a periodic scheduled check
rather than only manual inspection. C<--db>/C<-d> (or C<D2TG_DB>)
resolves exactly as every other C<d2 tg.*> command's does.

B<Known limitation> (a Codex review finding, accepted rather than
solved here): the text-send and its store record are two separate
steps against two separate systems (Telegram's API and this skill's own
SQLite database) with no way to make them atomic. A process kill or a
database error in the narrow window between a successful C<sendMessage>
and C<record_sent_text> actually running would leave a genuinely-sent
text message with no row at all, invisible to this checker if its voice
half then also failed - the same best-effort tradeoff TGT-104's failed-
download queue documents for its own non-fatal queue write. This is not
a guarantee, only a substantial improvement over having no record at
all.

=cut
