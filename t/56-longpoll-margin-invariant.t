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
    push @{ $self->{calls} }, $req;
    return shift @{ $self->{responses} };
}

package main;

sub http_response {
    my (%args) = @_;
    my $res = HTTP::Response->new( $args{code} // 200, $args{message} // 'OK' );
    $res->header( 'Content-Type' => 'application/json; charset=utf-8' );
    $res->content( $args{content} // '{"ok":true,"result":[]}' );
    return $res;
}

# TGT-067: get_updates' default long-poll timeout must derive from
# DEFAULT_HARD_TIMEOUT via an explicit margin constant, not a bare
# literal - so the margin TGT-066 fixed a live incident over can never
# silently drift apart again if either value changes in the future.
ok( D2TG::Telegram::DEFAULT_LONG_POLL_MARGIN(), 'DEFAULT_LONG_POLL_MARGIN constant exists' );

is( D2TG::Telegram::DEFAULT_HARD_TIMEOUT() - D2TG::Telegram::DEFAULT_LONG_POLL_MARGIN(), 30,
    'the hard timeout minus the margin constant equals 30 - the relationship is now a code-level invariant' );

{
    my $ua = Fake::UA->new( responses => [ http_response() ] );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    $tg->get_updates( offset => 1 );

    my $req  = $ua->{calls}[0];
    my $body = $req->content;
    like( $body, qr/"timeout":30/, 'get_updates with no explicit timeout still requests 30 - unchanged behavior' );
}

done_testing();
