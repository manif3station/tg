use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempfile);
use JSON::PP qw(decode_json);
use HTTP::Response;

require D2TG::Telegram;

package Fake::UA;

sub new {
    my ( $class, %args ) = @_;
    return bless { responses => $args{responses} || [], calls => [] }, $class;
}

sub request {
    my ( $self, $req ) = @_;
    push @{ $self->{calls} }, { method => 'request', url => $req->uri->as_string, req => $req };
    return shift @{ $self->{responses} };
}

package main;

sub http_response {
    my (%args) = @_;
    my $res = HTTP::Response->new( $args{code} // 200, $args{message} // 'OK' );
    $res->header( 'Content-Type' => 'application/json; charset=utf-8' );
    $res->content( $args{content} ) if defined $args{content};
    return $res;
}

{
    my $ua = Fake::UA->new(
        responses => [
            http_response( content => '{"ok":true,"result":{"message_id":1}}' ),
            http_response( content => '{"ok":true,"result":{"message_id":2}}' ),
            http_response( content => '{"ok":true,"result":{"message_id":3}}' ),
        ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    my $text = 'x' x 10;
    my $results = $tg->send_message( 42, $text, 4 );

    is( scalar @{ $ua->{calls} }, 3, 'a 10-char message split at limit=4 makes 3 sendMessage calls' );
    like( $ua->{calls}[0]{url}, qr{/sendMessage$}, 'called the sendMessage endpoint' );
    is( scalar @$results, 3, 'send_message returns one result per chunk sent' );
}

{
    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":1}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    $tg->send_message( 42, 'hi' );
    my $sent = decode_json( $ua->{calls}[0]{req}->content );
    is( $sent->{chat_id}, 42,   'chat_id is sent correctly for a plain sendMessage' );
    is( $sent->{text},    'hi', 'text is sent correctly for a plain sendMessage' );
}

{
    my ( $fh, $path ) = tempfile( SUFFIX => '.ogg' );
    print {$fh} 'fake ogg bytes';
    close $fh;

    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":3}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    my $result = $tg->send_voice( 42, $path );

    is( scalar @{ $ua->{calls} }, 1, 'send_voice makes exactly one HTTP call' );
    like( $ua->{calls}[0]{url}, qr{/sendVoice$}, 'called the sendVoice endpoint' );
    like(
        $ua->{calls}[0]{req}->header('Content-Type'),
        qr{^multipart/form-data; boundary=},
        'send_voice uses a multipart/form-data content type'
    );
    like( $ua->{calls}[0]{req}->content, qr/fake ogg bytes/, 'the voice file bytes are included in the request body' );
    like( $ua->{calls}[0]{req}->content, qr/name="chat_id"/, 'the chat_id form field is included' );
    is( $result->{message_id}, 3, 'send_voice returns the mocked Telegram result' );

    unlink $path;
}

{
    my $ua = Fake::UA->new( responses => [] );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    eval { $tg->send_voice( 42, '/nonexistent/path/does-not-exist.ogg' ) };
    like( $@, qr/cannot read/, 'send_voice dies clearly when the voice file cannot be read' );
    is( scalar @{ $ua->{calls} }, 0, 'no HTTP call is made when the voice file is unreadable' );
}

done_testing();
