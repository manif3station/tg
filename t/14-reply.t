use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use File::Temp qw(tempfile);

require D2TG::Reply;
require Fake::ReplyTelegram;

# TGT-083 (live user request): send_reply's order was reversed - text is
# now sent FIRST, then the voice note is synthesized, then sent. This is
# a deliberate, explicit reversal of this project's own prior rule (see
# tg-skill-design.md's "Reply design lessons" section) that text must
# never be sent without voice - under the new order, a synthesis or
# send_voice failure AFTER the text has already gone out can no longer
# prevent a text-only outcome (Telegram messages can't be unsent), but
# send_reply still dies/propagates the failure loudly so the operator
# knows to follow up, rather than silently reporting success.

package main;

{
    my ( $fh, $voice_path ) = tempfile( SUFFIX => '.ogg' );
    print {$fh} 'fake voice bytes';
    close $fh;

    my $telegram    = Fake::ReplyTelegram->new;
    my $synth_calls = 0;
    my $synthesize  = sub {
        $synth_calls++;
        push @{ $telegram->{call_order} }, 'synthesize';
        return $voice_path;
    };

    D2TG::Reply::send_reply(
        telegram   => $telegram,
        chat_id    => 99,
        text       => 'hello there',
        synthesize => $synthesize,
    );

    is_deeply( $telegram->{call_order}, [ 'send_message', 'synthesize', 'send_voice' ],
        'send_reply calls send_message, then synthesize, then send_voice, in that exact order (TGT-083)'
    );
    is( $synth_calls, 1, 'synthesize is called exactly once' );
    is( scalar @{ $telegram->{sent_voices} }, 1, 'exactly one voice note was sent' );
    is( $telegram->{sent_voices}[0]{path}, $voice_path, 'the voice note uses the synthesized path' );
    is( scalar @{ $telegram->{sent_messages} }, 1, 'exactly one text message was sent' );
    is( $telegram->{sent_messages}[0]{text}, 'hello there', 'the sent text matches the reply text' );
    ok( !-e $voice_path, 'the synthesized temp voice file is cleaned up after a successful send' );
}

{
    my $telegram   = Fake::ReplyTelegram->new;
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
    is( scalar @{ $telegram->{sent_messages} }, 1,
        'the text message HAS already been sent when synthesis fails (TGT-083: new order, text sent first) - the failure is still reported loudly, but text is no longer prevented' );
    is( scalar @{ $telegram->{sent_voices} }, 0, 'no voice note is sent when synthesis fails' );
}

{
    my ( $fh, $voice_path ) = tempfile( SUFFIX => '.ogg' );
    print {$fh} 'fake voice bytes';
    close $fh;

    my $telegram   = Fake::ReplyTelegram->new( fail_voice => 1 );
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
    is( scalar @{ $telegram->{sent_messages} }, 1,
        'the text message HAS already been sent when send_voice fails (TGT-083: new order) - still reported as a failure via die, but the text portion already reached the user' );
    ok( !-e $voice_path, 'the synthesized temp voice file is still cleaned up when send_voice fails' );
}

done_testing();
