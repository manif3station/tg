package D2TG::Reply;

use strict;
use warnings;
use D2TG::TTS;
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

    my $voice_path = $synth->( $text, %{ $args{tts_args} || {} } );

    my $voice_result = eval { $telegram->send_voice( $chat_id, $voice_path, %opts ) };
    my $send_voice_error = $@;
    unlink $voice_path if -e $voice_path;
    die $send_voice_error if $send_voice_error;

    my $text_result = $telegram->send_message( $chat_id, $text, undef, %opts );

    $args{store}->mark_read( $chat_id, $args{reply_to_message_id} )
      if $args{store} && defined $args{reply_to_message_id};

    return { text => $text_result, voice => $voice_result };
}

sub extract_bot_flag {
    my (@args) = @_;

    my $bot_token;
    if ( @args >= 2 && $args[0] eq '--bot' ) {
        ( undef, $bot_token ) = splice( @args, 0, 2 );
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
voice with text" reply rule: synthesizes the voice note first, then sends
the voice note, and only sends the text message once the voice note has
actually been delivered. If synthesis dies, or C<send_voice> itself
fails, C<send_reply> dies too and C<send_message> is never called - so a
failure at either point never produces a text-only reply. The
synthesized temp file is removed after C<send_voice> is attempted,
whether it succeeded or not.

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

=head2 extract_bot_flag(@args)

Parses a leading C<--bot <token>> pair off the front of C<@args> (TGT-057),
returning C<($bot_token, @remaining_args)>. C<$bot_token> is C<undef> when
C<--bot> isn't the first argument (or C<@args> is too short to hold both
the flag and its value) - C<cli/reply> falls back to C<D2TG::Config::token>
(C<D2TG_TOKEN>) in that case, unchanged from before this ticket. Leading,
not whole-list, for the same collision-avoidance reason as
C<D2TG::Config::extract_db_flag> and C<--reply-to-message-id>'s
trailing-only recognition (TGT-042): free reply text passed as multiple
unquoted shell words could otherwise contain the literal token C<--bot>
and be misread as the flag.

=head2 parse_cli_args(@ARGV)

Parses C<cli/reply>'s raw argument list into C<($chat_id, $text,
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
are numeric; C<cli/reply> does that itself before using the parsed
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
at the single chokepoint every C<cli/reply> invocation passes through -
C<$chat_id>/C<$reply_to_message_id> are always plain ASCII digits, so
decoding them as UTF-8 is a harmless no-op. Only C<cli/reply> reaches
this function via raw C<@ARGV>; no other C<cli/*> command's own
argv (C<--since>/C<--until> ISO timestamps, chat/message ids) carries
free-form user text through a similar chokepoint, so this is the only
place that needed the fix. A caller that ever passed an
I<already-decoded> wide-character Perl string here (rather than raw
bytes, which is what real C<@ARGV> always is) could in principle see
C<decode> mis-handle it - not a concern for the actual C<cli/reply>
invocation path today, since C<@ARGV> is never pre-decoded.

=cut
