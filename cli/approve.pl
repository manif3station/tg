#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;

use D2TG::Config;
use D2TG::Store;
use D2TG::Reply;

my ( $db_alias, @rest );
eval { ( $db_alias, @rest ) = D2TG::Config::extract_db_flag(@ARGV) };
if ($@) {
    print STDERR $@;
    exit 1;
}
@ARGV = @rest;

my ( $bot_key, @after_bot );
eval { ( $bot_key, @after_bot ) = D2TG::Reply::extract_bot_flag(@ARGV) };
if ($@) {
    print STDERR $@;
    exit 1;
}
@ARGV = @after_bot;
$bot_key = '' unless defined $bot_key;

my $base_dir = D2TG::Config::resolve_alias_dir_or_die( alias => $db_alias );

eval { D2TG::Config::require_existing_base_dir($base_dir) };
if ($@) {
    print STDERR $@;
    exit 1;
}

if ( @ARGV != 1 || $ARGV[0] !~ /^-?\d+$/ ) {
    print STDERR "Usage: d2 tg.approve <chat_id> [--db <alias> | -d <alias>] [--bot <token>]\n";
    exit 2;
}

my $chat_id = $ARGV[0];

my $store = D2TG::Store->new(
    db_path => D2TG::Config::state_db_path(
        default_root => File::Spec->catdir( $Bin, '..' ),
        base_dir      => $base_dir,
    ),
    admin_chat_id => D2TG::Config::chat_id(),
);

if ( $store->approve( $chat_id, $bot_key ) ) {
    print "Approved $chat_id\n";
    exit 0;
}

if ( $store->is_allowed( $chat_id, $bot_key ) ) {
    print STDERR "$chat_id is already allowed - nothing to do\n";
}
else {
    print STDERR "$chat_id was never pending (never sent a message) - nothing to approve\n";
}
exit 1;

=head1 NAME

approve - move a pending chat id into the allow-list, dispatched as C<d2 tg.approve>

=head1 SYNOPSIS

    d2 tg.approve <chat_id> [--db <alias> | -d <alias>] [--bot <token>]

=head1 DESCRIPTION

C<--db <alias>>/C<-d <alias>> (TGT-051, or C<D2TG_DB=<alias>> as a
fallback) resolves the same way C<d2 tg.poller>'s does - see
L<D2TG::Config/resolve_alias_dir>. The resolved directory (or a
C<TIRA_HOME> fallback) must already exist - refuses to start otherwise
rather than creating it (TGT-090, see L<D2TG::Config/require_existing_base_dir>).

C<--bot <token>> (TGT-098) scopes the approval to that bot, using
L<D2TG::Reply/extract_bot_flag> - the same leading-position shape
C<cli/reply.pl>'s own C<--bot> uses (TGT-057). Omitting it approves
under the empty-string sentinel, matching every existing single-bot
install's behavior exactly - only a multi-bot setup where a Telegram
GROUP is shared by more than one of this skill's own configured bots
needs C<--bot> at all, since only then can the same C<chat_id> mean two
different bots' access (TGT-098: a group chat's id is the same for every
bot that's a member, unlike a private chat's, which Telegram allocates
uniquely per bot).

Moves C<chat_id> from L<D2TG::Store>'s C<pending> table into its
C<allow_list>, scoped to C<--bot>'s value (or the empty-string
single-bot sentinel). Prints C<Approved N> and exits 0 on success. If
nothing changed, exits 1 with a message on STDERR distinguishing the two
ways that can happen: the chat id is already allowed under this bot
(nothing to do), or it was never pending under this bot at all (never
messaged this specific bot, so there's nothing to approve).

=cut
