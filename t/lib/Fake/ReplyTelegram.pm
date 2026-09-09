package Fake::ReplyTelegram;

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        sent_messages     => [],
        sent_voices       => [],
        call_order        => [],
        calls             => 0,
        fail_voice        => $args{fail_voice},
        shapeless         => $args{shapeless},
        text_message_id   => $args{text_message_id}   // 1,
        voice_message_id  => $args{voice_message_id}  // 2,
    }, $class;
}

sub send_message {
    my ( $self, $chat_id, $text ) = @_;
    $self->{calls}++;
    push @{ $self->{call_order} },    'send_message';
    push @{ $self->{sent_messages} }, { chat_id => $chat_id, text => $text };
    return { ok => 1 } if $self->{shapeless};
    return [ { message_id => $self->{text_message_id} } ];
}

sub send_voice {
    my ( $self, $chat_id, $path, %opts ) = @_;
    push @{ $self->{call_order} }, 'send_voice';
    die "sendVoice failed: network error\n" if $self->{fail_voice};
    push @{ $self->{sent_voices} }, { chat_id => $chat_id, path => $path, %opts };
    return { ok => 1 } if $self->{shapeless};
    return { message_id => $self->{voice_message_id} };
}

1;

=head1 NAME

Fake::ReplyTelegram - shared test double for D2TG::Reply's outbound send_message/send_voice shape

=head1 SYNOPSIS

    require Fake::ReplyTelegram;
    my $telegram = Fake::ReplyTelegram->new(
        fail_voice       => 0,     # die in send_voice if true
        shapeless        => 0,     # return a bare { ok => 1 } instead of the usual shapes
        text_message_id  => 1,     # message_id embedded in send_message's return
        voice_message_id => 2,     # message_id embedded in send_voice's return
    );

=head1 DESCRIPTION

TGT-121 (found via a scheduled improvement-hunt pass): this project
already fixed exactly this class of duplication once before for the
I<inbound> polling shape (TGT-018 extracted L<Fake::Telegram> for
C<get_updates>) - this module does the same for the I<outbound>
C<send_message>/C<send_voice> shape, which had been independently
reinvented as six near-identical packages across five test files
(C<t/14-reply.t>, C<t/37-message-read-status.t>,
C<t/78-resend-voice-only.t>, C<t/84-text-only-reply-audit.t>'s
C<Fake::ReplyTelegram>/C<Fake::ShapelessTelegram>, and
C<t/85-reply-dedup-window.t>).

Tracks every call in C<call_order> (an arrayref a test's own
C<synthesize> callback can also push onto, to assert the full
send/synthesize/send interleaving - see C<t/14>/C<t/78>'s own usage),
every sent text in C<sent_messages> and every sent voice note in
C<sent_voices> (chat_id/path, plus any extra C<%opts> such as
C<reply_to_message_id>), and a plain C<calls> counter (incremented on
each C<send_message>, for callers only checking a repeat wasn't sent).

C<fail_voice> makes C<send_voice> die, matching
L<D2TG::Reply/send_reply>'s TGT-083 ordering (text already sent by the
time voice fails). C<shapeless> makes both methods return a bare
C<{ ok => 1 }> instead of the normal Telegram-API-shaped return value
(an arrayref of hashrefs for C<send_message>, a bare hashref for
C<send_voice>) - covering C<send_reply>'s own defensive handling of a
non-standard response shape (found via C<t/32>'s own pre-existing
C<Fake::TelegramForReply>, which independently discovered the same
gap). C<text_message_id>/C<voice_message_id> customize the
C<message_id> embedded in the normal (non-shapeless) return shapes, for
callers that assert on a specific value.

=cut
