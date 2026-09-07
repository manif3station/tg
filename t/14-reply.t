use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempfile);

require D2TG::Reply;

package Fake::Telegram;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        sent_messages => [],
        sent_voices   => [],
        fail_voice    => $args{fail_voice},
    }, $class;
}

sub send_message {
    my ( $self, $chat_id, $text ) = @_;
    push @{ $self->{sent_messages} }, { chat_id => $chat_id, text => $text };
    return [ { message_id => 1 } ];
}

sub send_voice {
    my ( $self, $chat_id, $path ) = @_;
    die "sendVoice failed: network error\n" if $self->{fail_voice};
    push @{ $self->{sent_voices} }, { chat_id => $chat_id, path => $path };
    return { message_id => 2 };
}

package main;

{
    my ( $fh, $voice_path ) = tempfile( SUFFIX => '.ogg' );
    print {$fh} 'fake voice bytes';
    close $fh;

    my $telegram    = Fake::Telegram->new;
    my $synth_calls = 0;
    my $synthesize  = sub { $synth_calls++; return $voice_path; };

    D2TG::Reply::send_reply(
        telegram   => $telegram,
        chat_id    => 99,
        text       => 'hello there',
        synthesize => $synthesize,
    );

    is( $synth_calls, 1, 'synthesize is called exactly once' );
    is( scalar @{ $telegram->{sent_voices} }, 1, 'exactly one voice note was sent' );
    is( $telegram->{sent_voices}[0]{path}, $voice_path, 'the voice note uses the synthesized path' );
    is( scalar @{ $telegram->{sent_messages} }, 1, 'exactly one text message was sent' );
    is( $telegram->{sent_messages}[0]{text}, 'hello there', 'the sent text matches the reply text' );
    ok( !-e $voice_path, 'the synthesized temp voice file is cleaned up after a successful send' );
}

{
    my $telegram   = Fake::Telegram->new;
    my $synthesize = sub { die "boom: tts unavailable\n"; };

    eval {
        D2TG::Reply::send_reply(
            telegram   => $telegram,
            chat_id    => 99,
            text       => 'hello there',
            synthesize => $synthesize,
        );
    };

    like( $@, qr/boom: tts unavailable/, 'a synthesize failure propagates out of send_reply' );
    is( scalar @{ $telegram->{sent_messages} }, 0, 'no text message is sent when synthesis fails - never text-only' );
    is( scalar @{ $telegram->{sent_voices} }, 0, 'no voice note is sent when synthesis fails' );
}

{
    my ( $fh, $voice_path ) = tempfile( SUFFIX => '.ogg' );
    print {$fh} 'fake voice bytes';
    close $fh;

    my $telegram   = Fake::Telegram->new( fail_voice => 1 );
    my $synthesize = sub { return $voice_path; };

    eval {
        D2TG::Reply::send_reply(
            telegram   => $telegram,
            chat_id    => 99,
            text       => 'hello there',
            synthesize => $synthesize,
        );
    };

    like( $@, qr/sendVoice failed/, 'a send_voice failure propagates out of send_reply' );
    is( scalar @{ $telegram->{sent_messages} }, 0,
        'no text message is sent when send_voice itself fails - never a text-only partial reply' );
    ok( !-e $voice_path, 'the synthesized temp voice file is still cleaned up when send_voice fails' );
}

done_testing();
