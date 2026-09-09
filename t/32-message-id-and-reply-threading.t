use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use JSON::PP qw(decode_json);
use HTTP::Response;

require D2TG::Poller;
require D2TG::Telegram;
require D2TG::Reply;
require Fake::Telegram;
require Fake::Store;
require Fake::UA;

sub http_response {
    my (%args) = @_;
    my $res = HTTP::Response->new( $args{code} // 200, $args{message} // 'OK' );
    $res->header( 'Content-Type' => 'application/json; charset=utf-8' );
    $res->content( $args{content} ) if defined $args{content};
    return $res;
}

sub capture_stdout {
    my ($code) = @_;
    my $out = '';
    open my $fh, '>', \$out or die $!;
    my $old = select $fh;
    $code->();
    select $old;
    close $fh;
    return $out;
}

# --- D2TG::Poller: message_id surfaced in content line and REPLY WITH template ---
{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 500,
                message   => {
                    message_id => 777,
                    chat       => { id => 999 },
                    from       => { username => 'ada' },
                    text       => 'hello',
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $out, qr/NEW TG \[999\] ada: hello.*777/, 'the content line includes the message_id' );
    like( $out, qr/REPLY WITH: d2 tg\.reply 999 "\.\.\." --reply-to-message-id 777/, 'the REPLY WITH template includes --reply-to-message-id' );
}

# --- D2TG::Telegram: send_message/send_voice accept an optional reply_to_message_id ---
{
    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":1}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    $tg->send_message( 42, 'hi', undef, reply_to_message_id => 555 );
    my $sent = decode_json( $ua->{calls}[0]{req}->content );
    is( $sent->{reply_to_message_id}, 555, 'send_message includes reply_to_message_id when given' );
}

{
    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":1}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    $tg->send_message( 42, 'hi' );
    my $sent = decode_json( $ua->{calls}[0]{req}->content );
    ok( !exists $sent->{reply_to_message_id}, 'send_message omits reply_to_message_id when not given (unchanged behavior)' );
}

{
    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":1}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    require File::Temp;
    my ( $fh, $path ) = File::Temp::tempfile( SUFFIX => '.ogg', UNLINK => 1 );
    print $fh 'fake audio';
    close $fh;

    $tg->send_voice( 42, $path, reply_to_message_id => 555 );
    like( $ua->{calls}[0]{req}->content, qr/name="reply_to_message_id"\r\n\r\n555/, 'send_voice includes reply_to_message_id in its multipart body when given' );
}

{
    my $ua = Fake::UA->new( responses => [] );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    require File::Temp;
    my ( $fh, $path ) = File::Temp::tempfile( SUFFIX => '.ogg', UNLINK => 1 );
    print $fh 'fake audio';
    close $fh;

    eval { $tg->send_voice( 42, $path, reply_to_message_id => "555\r\nContent-Disposition: form-data; name=\"evil\"" ) };
    like( $@, qr/must be numeric/, 'send_voice rejects a non-numeric reply_to_message_id instead of injecting it into the multipart body' );
}

# --- D2TG::Reply: send_reply threads reply_to_message_id through to both calls ---
{
    my @send_message_args;
    my @send_voice_args;
    my $fake_telegram = bless {}, 'Fake::TelegramForReply';
    no strict 'refs';
    *{'Fake::TelegramForReply::send_voice'} = sub { shift; push @send_voice_args, [@_]; return { ok => 1 }; };
    *{'Fake::TelegramForReply::send_message'} = sub { shift; push @send_message_args, [@_]; return { ok => 1 }; };
    use strict 'refs';

    my $fake_synth = sub { return '/tmp/fake-voice.ogg' };
    open my $touch, '>', '/tmp/fake-voice.ogg' or die $!;
    close $touch;

    D2TG::Reply::send_reply(
        telegram             => $fake_telegram,
        chat_id              => 42,
        text                 => 'hi there',
        synthesize           => $fake_synth,
        reply_to_message_id  => 555,
    );

    is_deeply( { @{ $send_voice_args[0] }[ 2 .. $#{ $send_voice_args[0] } ] }, { reply_to_message_id => 555 }, 'send_reply passes reply_to_message_id through to send_voice' );
    is_deeply( { @{ $send_message_args[0] }[ 3 .. $#{ $send_message_args[0] } ] }, { reply_to_message_id => 555 }, 'send_reply passes reply_to_message_id through to send_message' );
}

done_testing();
