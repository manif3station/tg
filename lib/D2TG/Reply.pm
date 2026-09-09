package D2TG::Reply;

use strict;
use warnings;
use D2TG::TTS;
use D2TG::Config;
use Encode qw(decode);

sub send_reply {
    my (%args) = @_;

    my $telegram = $args{telegram} or die "D2TG::Reply::send_reply requires telegram\n";
    my $chat_id  = $args{chat_id};
    my $text     = $args{text};
    my $synth    = $args{synthesize} || \&D2TG::TTS::synthesize;

    my %opts = defined $args{reply_to_message_id}
      ? ( reply_to_message_id => $args{reply_to_message_id} )
      : ();

    # TGT-114: refuse a send whose exact text already went out to this
    # same chat/bot within a short window - a retried send_reply call
    # after a transient failure, or an agent accidentally re-running the
    # same d2 tg.reply command, previously had no way to avoid delivering
    # the identical message twice. Only checked when a store is given -
    # unchanged behavior for a caller that never opts into this feature.
    if ( $args{store} && $args{store}->is_recent_duplicate_reply( $chat_id, $text, bot_key => $args{bot_key} ) ) {
        die "D2TG::Reply::send_reply: refusing to send - this exact text was already sent to "
          . "chat_id $chat_id moments ago (duplicate within the dedup window)\n";
    }

    my $text_result = $telegram->send_message( $chat_id, $text, undef, %opts );

    # TGT-105: record the text send BEFORE synthesis/send_voice can
    # fail - a row with no matching voice_message_id yet IS the
    # after-the-fact text-only audit trail this ticket exists to
    # provide, for exactly the case TGT-083's own tradeoff describes:
    # a synthesis/send_voice failure here is reported loudly (the die
    # below), but if that's missed, this row is what a later checker
    # catches it with. Uses the LAST chunk's message_id when a long
    # reply auto-split into multiple messages (TGT-013's own
    # split_text_utf16) - the single-chunk case (by far the common one)
    # is unaffected. Only attempted when a store is actually given -
    # $telegram is only contractually required to respond to
    # send_message/send_voice (existing callers/tests use bare fakes
    # returning any shape they like when they don't care about this
    # feature), so this must never assume $text_result's own shape
    # unless a caller has opted in by passing store.
    my $text_message_id;
    if ( $args{store} ) {
        $text_message_id = eval { $text_result->[-1]{message_id} };
        $args{store}->record_sent_text( $chat_id, $text_message_id, bot_key => $args{bot_key}, text => $text )
          if defined $text_message_id;
    }

    my $voice_path = $synth->( $text, %{ $args{tts_args} || {} } );

    my $voice_result = eval { $telegram->send_voice( $chat_id, $voice_path, %opts ) };
    my $send_voice_error = $@;
    unlink $voice_path if -e $voice_path;
    die $send_voice_error if $send_voice_error;

    $args{store}->record_sent_voice( $chat_id, $text_message_id, $voice_result->{message_id}, bot_key => $args{bot_key} )
      if $args{store} && defined $text_message_id;

    $args{store}->mark_read( $chat_id, $args{reply_to_message_id} )
      if $args{store} && defined $args{reply_to_message_id};

    return { text => $text_result, voice => $voice_result };
}

sub resend_voice {
    my (%args) = @_;

    my $telegram = $args{telegram} or die "D2TG::Reply::resend_voice requires telegram\n";
    my $chat_id  = $args{chat_id};
    my $text     = $args{text};
    my $synth    = $args{synthesize} || \&D2TG::TTS::synthesize;
    my $text_message_id = $args{text_message_id};

    my %opts = defined $args{reply_to_message_id}
      ? ( reply_to_message_id => $args{reply_to_message_id} )
      : ();

    my $voice_path = $synth->( $text, %{ $args{tts_args} || {} } );

    my $voice_result = eval { $telegram->send_voice( $chat_id, $voice_path, %opts ) };
    my $send_voice_error = $@;
    unlink $voice_path if -e $voice_path;
    die $send_voice_error if $send_voice_error;

    # Codex review finding: without this, a successfully-recovered
    # reply (text already sent earlier, voice now resent here) stayed
    # unread forever - inviting later reprocessing/a duplicate full
    # reply, since nothing else ever marks it read for this recovery
    # path. Same guard as send_reply's own: only when both store and
    # reply_to_message_id are given, and only after send_voice has
    # actually succeeded.
    $args{store}->mark_read( $chat_id, $args{reply_to_message_id} )
      if $args{store} && defined $args{reply_to_message_id};

    # TGT-105: this is exactly what clears a send_reply-recorded
    # text-only flag once the missing voice half is actually recovered.
    $args{store}->record_sent_voice( $chat_id, $text_message_id, $voice_result->{message_id}, bot_key => $args{bot_key} )
      if $args{store} && defined $text_message_id;

    return { voice => $voice_result };
}

sub format_send_error {
    my ($error) = @_;

    return $error
      . "This looks like a transient network error - try running the same d2 tg.reply command again.\n"
      if D2TG::Config::is_transient_error($error);

    return $error;
}

sub extract_bot_flag {
    my (@args) = @_;

    my $bot_token;
    if ( @args >= 2 && $args[0] eq '--bot' ) {
        shift @args;
        $bot_token = D2TG::Config::shift_flag_value( \@args, '--bot' );
    }

    return ( $bot_token, @args );
}

sub parse_cli_args {
    my (@args) = @_;

    @args = map { decode( 'UTF-8', $_ ) } @args;

    my $reply_to_message_id;
    if ( @args >= 2 && $args[-2] eq '--reply-to-message-id' ) {
        ( undef, $reply_to_message_id ) = splice( @args, -2 );
    }

    my $chat_id = shift @args;
    my $text    = join( ' ', @args );

    return ( $chat_id, $text, $reply_to_message_id );
}

1;

=head1 NAME

D2TG::Reply - send a text + voice-note reply to a chat, never text-only

=head1 SYNOPSIS

    D2TG::Reply::send_reply(
        telegram => $telegram,
        chat_id  => $chat_id,
        text     => $text,
    );

=head1 DESCRIPTION

Wires L<D2TG::TTS> and L<D2TG::Telegram> together for the owner's "always
voice with text" reply rule. As of TGT-083 (a live, explicit user
request), the order is: send the text message first, THEN synthesize
the voice note, THEN send the voice note. This deliberately reverses
this module's own prior order (voice synthesized and sent first, text
only once voice succeeded) and the guarantee that came with it - before
TGT-083, a synthesis or C<send_voice> failure happened I<before>
C<send_message> was ever called, so a failure at either point could
never produce a text-only reply. Under the new order, C<send_message>
has already run by the time synthesis or C<send_voice> could fail;
C<send_reply> still dies loudly in that case (so C<cli/reply.pl> exits
non-zero and never claims success), but it can no longer prevent the
text from having already reached the user - Telegram messages can't be
unsent by this code. This is a deliberate, explicit reversal of the
prior rule, not a silent regression - see C<tg-skill-design.md>'s
"Reply design lessons" section and C<docs/POLICIES.md> for the full
incident history both fixes are built on. The synthesized temp file is
still removed after C<send_voice> is attempted, whether it succeeded or
not.

=head1 FUNCTIONS

=head2 send_reply(telegram => $tg, chat_id => $id, text => $text, synthesize => \&coderef, tts_args => \%hash, reply_to_message_id => $id, store => $store)

C<telegram> must respond to C<send_message($chat_id, $text, ...)> and
C<send_voice($chat_id, $path, ...)>. C<synthesize> is optional and defaults to
L<D2TG::TTS>'s C<synthesize>; tests inject a fake here instead. Returns a
hashref of C<{ text => ..., voice => ... }> with each call's raw result.

C<reply_to_message_id> (TGT-040) is optional; when given, it is passed
through to both C<send_voice> and C<send_message>, so the reply threads
natively under the original message in Telegram's UI instead of arriving
as a fresh, unthreaded message. Omitting it is unchanged from before
this ticket.

C<store> (TGT-046) is optional; when given I<together with>
C<reply_to_message_id>, that message is marked read
(L<D2TG::Store/mark_read>) only after both sends have actually
succeeded - a failed synthesis or a failed C<send_voice>/C<send_message>
call dies before C<mark_read> is ever reached, so a message is never
marked read for a reply that didn't actually go out. Omitting C<store>,
or omitting C<reply_to_message_id>, leaves read status untouched -
unchanged from before this ticket.

C<store> also (TGT-105) records the text-only audit trail: the text
send via L<D2TG::Store/record_sent_text> as soon as C<send_message>
returns (independent of C<reply_to_message_id> - unlike C<mark_read>
above, this happens whenever C<store> is given at all), and the voice
send via L<D2TG::Store/record_sent_voice> once that also succeeds. The
message_id extracted from C<send_message>'s own return is wrapped in
C<eval> and the whole attempt skipped if it can't be found - a caller's
C<telegram> double that returns some other shape (existing tests that
never pass C<store> and never asked for this feature) must never be
broken by it. C<bot_key> (Codex review finding, same ticket) is
optional and defaults to the empty-string single-bot sentinel
(C<D2TG::Store::DEFAULT_BOT_KEY>) when omitted - pass the same bot
identity TGT-098's C<allow_list>/C<pending> scoping already uses, so a
Telegram group shared by more than one configured bot never lets one
bot's text-only audit trail collide with another's.

C<store> also (TGT-114) gates a de-duplication check: before calling
C<send_message> at all, C<L<D2TG::Store/is_recent_duplicate_reply>>
checks whether this exact C<text> was already sent to this C<chat_id>
(and C<bot_key>) within the last few seconds - if so, C<send_reply>
dies immediately, before touching Telegram at all, rather than
delivering the identical message a second time. This closes a real gap:
a retried C<send_reply> call after a transient failure, or an agent
accidentally re-running the same C<d2 tg.reply> command, previously had
no way to avoid sending the same text twice. Only checked when C<store>
is given - unchanged behavior for a caller that never opts in.

=head2 resend_voice(telegram => $tg, chat_id => $id, text => $text, synthesize => \&coderef, tts_args => \%hash, reply_to_message_id => $id, store => $store, bot_key => $key, text_message_id => $id)

TGT-109 (live-experienced incident): recovers from the specific failure
shape C<send_reply>'s TGT-083 text-first-then-voice ordering can leave
behind - text delivered successfully, then synthesis or C<send_voice>
fails. Re-running C<send_reply> in that situation would duplicate the
already-delivered text; C<resend_voice> synthesizes and sends I<only>
the voice half, never calling C<send_message> at all. Same fail-loud
behavior as C<send_reply> (a synthesis or C<send_voice> failure still
dies, temp file still cleaned up either way). Returns C<{ voice => ... }>
- no C<text> key, since none was ever sent by this call.

C<store> (Codex review finding, same day): without this, a successfully
-recovered reply stayed unread forever, since nothing else ever marks it
read for this recovery path - inviting later reprocessing or a duplicate
full reply. Same guard as C<send_reply>'s own: given I<together with>
C<reply_to_message_id>, the message is marked read only after
C<send_voice> has actually succeeded.

C<text_message_id>/C<bot_key> (TGT-105): when given together with
C<store>, a successful C<send_voice> here clears the text-only audit
flag C<send_reply> recorded for that C<(bot_key, chat_id,
text_message_id)>, via L<D2TG::Store/record_sent_voice> - the caller
(C<cli/reply.pl>'s C<--voice-only>) is expected to look up the correct
C<text_message_id> itself (typically the most recent still-flagged
C<D2TG::Store/text_only_replies> row for that chat and bot), since the
operator running a recovery command isn't asked for it directly.
Omitting either leaves the audit trail untouched, same as omitting
C<store> entirely.

=head2 format_send_error($error)

Given a C<send_reply> failure's C<$@> text, returns it unchanged unless
L<D2TG::Config/is_transient_error> says it looks transient (a network
timeout or a 5xx response - TGT-097 moved this classification into a
shared predicate, also used by C<D2TG::Poller::run_once_safe>), in which
case an explicit retry instruction is appended (TGT-096, a live user
request: a real C<sendVoice> timeout looked identical to a permanent
failure to the calling agent, with no signal that retrying would likely
succeed). C<cli/reply.pl> wraps its C<send_reply> call in C<eval> and
routes any failure through this before printing to STDERR - a permanent
failure (bad token, invalid chat id) is never given a misleading retry
suggestion.

=head2 extract_bot_flag(@args)

Parses a leading C<--bot <token>> pair off the front of C<@args> (TGT-057),
returning C<($bot_token, @remaining_args)>. C<$bot_token> is C<undef> when
C<--bot> isn't the first argument (or C<@args> is too short to hold both
the flag and its value) - C<cli/reply.pl> falls back to C<D2TG::Config::token>
(C<D2TG_TOKEN>) in that case, unchanged from before this ticket. Leading,
not whole-list, for the same collision-avoidance reason as
C<D2TG::Config::extract_db_flag> and C<--reply-to-message-id>'s
trailing-only recognition (TGT-042): free reply text passed as multiple
unquoted shell words could otherwise contain the literal token C<--bot>
and be misread as the flag.

When C<--bot> I<is> present with at least one more argument following
it, that value is validated via L<D2TG::Config/shift_flag_value>
(TGT-074, same bug class as TGT-071's C<--db> fix): dies with C<--bot
requires a value> if it's missing, empty, or itself flag-like, instead
of silently returning another flag's own name as the bot token (e.g.
C<extract_bot_flag('--bot','--db','myalias',...)> previously returned
C<'--db'> as the token). A bare trailing C<--bot> with I<no> value at
all (C<@args> too short) is unaffected here - C<cli/reply.pl>'s own caller
already handles that case directly (TGT-068).

=head2 parse_cli_args(@ARGV)

Parses C<cli/reply.pl>'s raw argument list into C<($chat_id, $text,
$reply_to_message_id)> (TGT-042). C<--reply-to-message-id <id>> is
recognized I<only> in the trailing position - the last two elements of
the argument list, matching exactly how the poller's own C<REPLY WITH>
template (TGT-040) always appends it. This is deliberately narrower than
scanning the whole argument list for that token: reply text passed as
multiple unquoted shell words could otherwise legitimately contain the
literal string C<--reply-to-message-id> (e.g. discussing the flag
itself), which a whole-list scan would misinterpret as the flag and
silently corrupt the text. C<$reply_to_message_id> is C<undef> when the
flag isn't given (or isn't trailing) - unchanged from before this
ticket. Does not validate that C<$chat_id> or C<$reply_to_message_id>
are numeric; C<cli/reply.pl> does that itself before using the parsed
result.

Decodes every argument as UTF-8 before doing anything else (TGT-073, a
real bug found by a scheduled hourly bug-hunt): C<@ARGV> is always raw
bytes - Perl never decodes it as UTF-8 on its own - so non-ASCII reply
text (accents, CJK, Cyrillic, emoji) previously reached
L<D2TG::Telegram>'s C<encode_json> call as un-decoded bytes, which
C<JSON::PP::encode_json> treats as Latin-1 codepoints and re-encodes as
UTF-8, double-encoding every multi-byte character into mojibake (e.g.
C<h\x{e9}llo> arrived on Telegram as C<hÃ©llo>). Decoding here, once,
before C<$chat_id>/C<$reply_to_message_id> are even split off, fixes it
at the single chokepoint every C<cli/reply.pl> invocation passes through -
C<$chat_id>/C<$reply_to_message_id> are always plain ASCII digits, so
decoding them as UTF-8 is a harmless no-op. Only C<cli/reply.pl> reaches
this function via raw C<@ARGV>; no other C<cli/*> command's own
argv (C<--since>/C<--until> ISO timestamps, chat/message ids) carries
free-form user text through a similar chokepoint, so this is the only
place that needed the fix. A caller that ever passed an
I<already-decoded> wide-character Perl string here (rather than raw
bytes, which is what real C<@ARGV> always is) could in principle see
C<decode> mis-handle it - not a concern for the actual C<cli/reply.pl>
invocation path today, since C<@ARGV> is never pre-decoded.

=cut
