use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
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
            http_response(
                content => '{"ok":true,"result":['
                  . '{"update_id":100,"message":{"text":"hi"}},'
                  . '{"update_id":101,"message":{"text":"there"}}'
                  . ']}',
            ),
        ],
    );

    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );
    my ( $updates, $next_offset ) = $tg->get_updates(offset => 5);

    is( scalar @$updates, 2, 'get_updates returns both mocked updates' );
    is( $updates->[0]{update_id}, 100, 'first update parsed correctly' );
    is( $next_offset, 102, 'next offset is one past the highest update_id' );
    is( scalar @{ $ua->{calls} }, 1, 'exactly one HTTP call was made' );
    like( $ua->{calls}[0]{url}, qr{/getUpdates$}, 'called the getUpdates endpoint' );
}

{
    my $ua = Fake::UA->new(
        responses => [
            http_response( content => '{"ok":true,"result":{"file_path":"voice/file_1.oga"}}' ),
        ],
    );

    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );
    my $file_path = $tg->get_file('AABB123');

    is( $file_path, 'voice/file_1.oga', 'get_file returns the mocked file_path' );
    like( $ua->{calls}[0]{url}, qr{/getFile$}, 'called the getFile endpoint' );
}

{
    my $ua = Fake::UA->new(
        responses => [
            http_response( content => '{"ok":true,"result":{"id":42,"is_bot":true,"username":"d2tg_bot"}}' ),
        ],
    );

    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );
    my $me = $tg->get_me;

    is( $me->{username}, 'd2tg_bot', 'get_me returns the mocked bot info' );
}

{
    my $ua = Fake::UA->new(
        responses => [
            http_response( content => '{"ok":false,"description":"Unauthorized"}' ),
        ],
    );

    my $tg = D2TG::Telegram->new( token => 'bad-token', ua => $ua );
    eval { $tg->get_me };
    like( $@, qr/Unauthorized/, 'a non-ok Telegram response dies with the description' );
    unlike( $@, qr/bad-token/, 'the error does not leak the bot token' );
}

{
    my $ua = Fake::UA->new(
        responses => [
            http_response( code => 429, message => 'Too Many Requests' ),
        ],
    );

    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );
    eval { $tg->get_me };
    like( $@, qr/429/,               'an HTTP transport failure dies naming the status' );
    unlike( $@, qr/test-token/,      'the error does not leak the bot token' );
}

{
    my $ua = Fake::UA->new(
        responses => [
            http_response( content => 'not json at all' ),
        ],
    );

    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );
    eval { $tg->get_me };
    like( $@, qr/not valid JSON/, 'a malformed response dies with a clear message' );
}

{
    my $ua = Fake::UA->new(
        responses => [
            http_response( content => '{"ok":true,"result":[]}' ),
        ],
    );

    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );
    my ( $updates, $next_offset ) = $tg->get_updates( offset => 7 );

    is( scalar @$updates, 0, 'an empty update list is returned as an empty array' );
    is( $next_offset, 7, 'offset is unchanged when no updates arrived' );
}

{
    my $ua = Fake::UA->new(
        responses => [
            http_response( content => '{"ok":true,"result":{}}' ),
        ],
    );

    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );
    my $file_path = $tg->get_file('missing-file');

    is( $file_path, undef, 'get_file returns undef when file_path is absent' );
}

{
    my $tg = D2TG::Telegram->new( token => 'test-token' );
    is(
        $tg->file_download_url('voice/file_1.oga'),
        'https://api.telegram.org/file/bottest-token/voice/file_1.oga',
        'file_download_url builds the correct download URL'
    );
}

done_testing();
