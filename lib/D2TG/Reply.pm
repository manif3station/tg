package D2TG::Reply;

use strict;
use warnings;
use D2TG::TTS;

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

    return { text => $text_result, voice => $voice_result };
}

sub parse_cli_args {
    my (@args) = @_;

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

=head2 send_reply(telegram => $tg, chat_id => $id, text => $text, synthesize => \&coderef, tts_args => \%hash, reply_to_message_id => $id)

C<telegram> must respond to C<send_message($chat_id, $text, ...)> and
C<send_voice($chat_id, $path, ...)>. C<synthesize> is optional and defaults to
L<D2TG::TTS>'s C<synthesize>; tests inject a fake here instead. Returns a
hashref of C<{ text => ..., voice => ... }> with each call's raw result.

C<reply_to_message_id> (TGT-040) is optional; when given, it is passed
through to both C<send_voice> and C<send_message>, so the reply threads
natively under the original message in Telegram's UI instead of arriving
as a fresh, unthreaded message. Omitting it is unchanged from before
this ticket.

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

=cut
