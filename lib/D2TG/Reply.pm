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

    my $voice_path = $synth->( $text, %{ $args{tts_args} || {} } );

    my $voice_result = eval { $telegram->send_voice( $chat_id, $voice_path ) };
    my $send_voice_error = $@;
    unlink $voice_path if -e $voice_path;
    die $send_voice_error if $send_voice_error;

    my $text_result = $telegram->send_message( $chat_id, $text );

    return { text => $text_result, voice => $voice_result };
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

=head2 send_reply(telegram => $tg, chat_id => $id, text => $text, synthesize => \&coderef, tts_args => \%hash)

C<telegram> must respond to C<send_message($chat_id, $text)> and
C<send_voice($chat_id, $path)>. C<synthesize> is optional and defaults to
L<D2TG::TTS>'s C<synthesize>; tests inject a fake here instead. Returns a
hashref of C<{ text => ..., voice => ... }> with each call's raw result.

=cut
