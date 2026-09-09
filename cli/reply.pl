#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;

use D2TG::Config;
use D2TG::Telegram;
use D2TG::Reply;
use D2TG::Store;

my $db_alias;
my $bot_token;
my $voice_only = 0;
while (@ARGV) {
    if ( $ARGV[0] eq '--db' || $ARGV[0] eq '-d' ) {
        shift @ARGV;
        $db_alias = eval { D2TG::Config::shift_flag_value( \@ARGV, '--db/-d' ) };
        if ($@) {
            print STDERR $@;
            exit 1;
        }
    }
    elsif ( $ARGV[0] eq '--bot' ) {
        if ( @ARGV >= 2 ) {
            ( $bot_token, @ARGV ) = D2TG::Reply::extract_bot_flag(@ARGV);
        }
        else {
            # A bare trailing --bot with no value can't be consumed by
            # extract_bot_flag (it needs 2 elements) - shift it off
            # directly so the loop always makes forward progress instead
            # of spinning forever on the same unconsumed argument. Falls
            # through to the chat_id/text Usage check below, same as any
            # other malformed invocation.
            shift @ARGV;
        }
    }
    elsif ( $ARGV[0] eq '--voice-only' ) {

        # TGT-109 (live-experienced incident): TGT-083's text-first-
        # then-voice ordering means a voice-only failure after text
        # success has no clean recovery path - re-running this command
        # normally would duplicate the already-delivered text. --voice-
        # only skips send_message entirely, resending just the voice
        # half for a message whose text has already gone out.
        $voice_only = 1;
        shift @ARGV;
    }
    else {
        last;
    }
}

my $base_dir = eval { D2TG::Config::resolve_alias_dir( alias => $db_alias ) };
if ($@) {
    print STDERR $@;
    exit 1;
}

eval { D2TG::Config::require_existing_base_dir($base_dir) };
if ($@) {
    print STDERR $@;
    exit 1;
}

my ( $chat_id, $text, $reply_to_message_id ) = D2TG::Reply::parse_cli_args(@ARGV);

if ( !defined $chat_id
    || $chat_id !~ /^-?\d+$/
    || !length $text
    || ( defined $reply_to_message_id && $reply_to_message_id !~ /^\d+$/ ) )
{
    print STDERR "Usage: d2 tg.reply <chat_id> <text...> [--reply-to-message-id <id>]\n";
    exit 2;
}

my $telegram = D2TG::Telegram->new( token => $bot_token // D2TG::Config::token() );

my $store = D2TG::Store->new(
    db_path => D2TG::Config::state_db_path(
        default_root => File::Spec->catdir( $Bin, '..' ),
        base_dir      => $base_dir,
    ),
    admin_chat_id => D2TG::Config::chat_id(),
);

my $bot_key = $bot_token // '';

if ($voice_only) {

    # TGT-105: find the most recent still-flagged text-only send for
    # THIS bot (Codex review finding: scoped by bot_key too, mirroring
    # TGT-098's own multi-bot isolation lesson - a shared chat_id across
    # bots must never let one bot's recovery select and clear another
    # bot's still-genuinely-text-only flag) and chat, if any, so a
    # successful recovery here clears that audit-trail flag - the
    # operator running --voice-only doesn't know (and isn't asked for)
    # that earlier send's own message_id.
    my ($latest_text_only) =
      sort { $b->{text_message_id} <=> $a->{text_message_id} }
      grep { $_->{chat_id} == $chat_id }
      @{ $store->text_only_replies( bot_key => $bot_key ) };

    eval {
        D2TG::Reply::resend_voice(
            telegram             => $telegram,
            chat_id              => $chat_id,
            text                 => $text,
            reply_to_message_id  => $reply_to_message_id,
            store                => $store,
            bot_key              => $bot_key,
            text_message_id      => $latest_text_only ? $latest_text_only->{text_message_id} : undef,
        );
    };
    if ($@) {
        print STDERR D2TG::Reply::format_send_error($@);
        exit 1;
    }

    print "Resent voice-only to $chat_id\n";
}
else {
    eval {
        D2TG::Reply::send_reply(
            telegram             => $telegram,
            chat_id              => $chat_id,
            text                 => $text,
            reply_to_message_id  => $reply_to_message_id,
            store                => $store,
            bot_key              => $bot_key,
        );
    };
    if ($@) {
        print STDERR D2TG::Reply::format_send_error($@);
        exit 1;
    }

    print "Replied to $chat_id\n";
}

=head1 NAME

reply - send a text + voice-note reply to a chat, dispatched as C<d2 tg.reply>

=head1 SYNOPSIS

    d2 tg.reply [--db <alias> | -d <alias>] [--bot <token>] [--voice-only] <chat_id> <text...> [--reply-to-message-id <id>]

=head1 DESCRIPTION

C<--voice-only> (TGT-109, a live-experienced incident) skips
C<send_message> entirely and resends only a synthesized voice note for
C<text>, via L<D2TG::Reply/resend_voice> - recovers from the specific
case where an earlier C<d2 tg.reply> already delivered the text but then
failed synthesizing or sending the voice half (TGT-083's text-first
ordering makes this possible); running the plain command again in that
situation would duplicate the already-sent text. Recognized in the same
leading position as C<--db>/C<-d>/C<--bot>, in any order relative to
them. Prints C<Resent voice-only to <chat_id>> on success instead of the
normal C<Replied to <chat_id>>; a failure is still reported through
L<D2TG::Reply/format_send_error> exactly like the normal path.

C<--db <alias>>/C<-d <alias>> (TGT-051, or C<D2TG_DB=<alias>> as a
fallback) is recognized only in the I<leading> position - the very
first one or two arguments, before C<chat_id> - unlike
L<D2TG::Config/extract_db_flag>'s whole-list scan used by the other
C<cli/tg.*> entrypoints. This is deliberate, for the same reason
C<--reply-to-message-id> is trailing-only (TGT-042): a whole-list scan
here could misinterpret reply text that happens to contain the literal
token C<--db> as multiple unquoted shell words. Resolution otherwise
matches C<d2 tg.poller>'s - see L<D2TG::Config/resolve_alias_dir>. The
resolved directory (or a C<TIRA_HOME> fallback) must already exist -
refuses to start otherwise rather than creating it (TGT-090, see
L<D2TG::Config/require_existing_base_dir>). C<--bot
<token>> (TGT-057) is recognized the same leading way, in either order
relative to C<--db>/C<-d>, and sends via that token instead of
C<D2TG_TOKEN> - required to reply to a message received under C<d2
tg.poller>'s multi-bot mode (TGT-049) by a bot other than the one
C<D2TG_TOKEN> names; the poller's own C<REPLY WITH> template already
fills this in when it applies. See L<D2TG::Reply/extract_bot_flag>. A
bare trailing C<--bot> with no value following it is shifted off
directly (TGT-068) rather than left for C<extract_bot_flag> (which needs
two elements to consume anything) - falls through to the C<chat_id>/text
C<Usage> check below like any other malformed invocation, instead of
looping forever on the same unconsumed argument (a real, live-reproduced
hang before this fix). C<--bot> immediately followed by another flag
(e.g. C<--bot --db myalias>) is also rejected (TGT-074, same bug class
as C<--db>'s own fix below): C<extract_bot_flag> dies with C<--bot
requires a value> instead of silently treating that flag's own name as
the bot token - see L<D2TG::Reply/extract_bot_flag>'s own POD for the
exact predicate.

C<--db>/C<-d>'s own shifted value is validated (TGT-071, same bug class
as TGT-068/069/070): if it's missing, empty, or itself looks like a flag
(starts with C<->) - e.g. a bare trailing C<--db>, or C<--db> immediately
followed by C<--bot> - the command dies with C<--db/-d requires a value>
instead of silently treating that flag's own name as the alias and
failing later with a misleading C<Unknown --db/-d alias '--bot'>. This
validation is delegated to L<D2TG::Config/shift_flag_value> (TGT-072).

A C<send_reply> failure (TGT-096) is caught and routed through
L<D2TG::Reply/format_send_error> before being printed to STDERR - a
transient-shaped failure (a network timeout or a 5xx status) gets an
explicit instruction telling the calling agent to retry the same
command; a permanent failure (bad token, invalid chat id) is reported
as before, with no misleading retry suggestion.

Thin CLI wrapper around L<D2TG::Reply>'s C<send_reply>: synthesizes a
voice note for C<text> (via L<D2TG::TTS>, cloud gTTS) and sends both a
text message and the voice note to C<chat_id> via L<D2TG::Telegram>. If
synthesis fails, the command dies before sending anything - never a
text-only reply.

C<chat_id> is validated as a numeric value (matching C<d2 tg.approve>'s
own guard, TGT-027) before anything else runs; a non-numeric first
argument prints the same C<Usage> message and exits 2, without
constructing L<D2TG::Telegram> or attempting any network call.

C<--reply-to-message-id <id>> (TGT-040) is optional and is recognized
only in the I<trailing> position - the very last two arguments, matching
exactly how the poller's own C<REPLY WITH> template always prints it
(TGT-042: recognizing it anywhere in the argument list would make free
reply text ambiguous with the flag itself whenever that text is passed
as multiple unquoted shell words containing the literal token
C<--reply-to-message-id>). When given, both the voice and text sends
carry Telegram's own C<reply_to_message_id>, so the reply threads
natively under the original message in Telegram's UI instead of arriving
as a fresh, unthreaded message. See L<D2TG::Reply/parse_cli_args>.
Omitting it is unchanged from before TGT-040 - no C<reply_to_message_id>
is sent.

When C<--reply-to-message-id> is given, that message is also marked read
in L<D2TG::Store> (TGT-046) once the reply has actually been sent
successfully - never for a reply that failed.

=cut
