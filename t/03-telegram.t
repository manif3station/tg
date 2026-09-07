use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Telegram;

package Fake::UA;

sub new {
    my ( $class, %args ) = @_;
    return bless { responses => $args{responses} || [], calls => [] }, $class;
}

sub post {
    my ( $self, $url, $opts ) = @_;
    push @{ $self->{calls} }, { method => 'post', url => $url, opts => $opts };
    return shift @{ $self->{responses} };
}

package main;

{
    my $ua = Fake::UA->new(
        responses => [
            {
                success => 1,
                content => '{"ok":true,"result":['
                  . '{"update_id":100,"message":{"text":"hi"}},'
                  . '{"update_id":101,"message":{"text":"there"}}'
                  . ']}',
            },
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
            {
                success => 1,
                content => '{"ok":true,"result":{"file_path":"voice/file_1.oga"}}',
            },
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
            {
                success => 1,
                content => '{"ok":true,"result":{"id":42,"is_bot":true,"username":"d2tg_bot"}}',
            },
        ],
    );

    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );
    my $me = $tg->get_me;

    is( $me->{username}, 'd2tg_bot', 'get_me returns the mocked bot info' );
}

{
    my $ua = Fake::UA->new(
        responses => [
            {
                success => 1,
                content => '{"ok":false,"description":"Unauthorized"}',
            },
        ],
    );

    my $tg = D2TG::Telegram->new( token => 'bad-token', ua => $ua );
    eval { $tg->get_me };
    like( $@, qr/Unauthorized/, 'a non-ok Telegram response dies with the description' );
}

done_testing();
