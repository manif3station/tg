use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Time::HiRes qw(time);

require D2TG::Telegram;

package Fake::HangingUA;

sub new {
    my ( $class, %args ) = @_;
    return bless { timeout => $args{timeout} // 1 }, $class;
}

sub timeout { return $_[0]->{timeout} }

sub request {
    my ($self) = @_;
    sleep 30;    # simulate a connect() stuck far longer than the configured timeout
    die "should never get here";
}

package Fake::FastUA;

sub new {
    my ( $class, %args ) = @_;
    return bless { timeout => $args{timeout} // 1, response => $args{response} }, $class;
}

sub timeout { return $_[0]->{timeout} }

sub request {
    my ($self) = @_;
    return $self->{response};
}

package main;

{
    my $ua = Fake::HangingUA->new( timeout => 1 );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    my $start = time();
    eval { $tg->get_me };
    my $error   = $@;
    my $elapsed = time() - $start;

    ok( $elapsed < 10, "a request stuck far longer than the configured timeout is aborted well before its own 30s sleep finishes (took ${elapsed}s)" )
      or diag("elapsed was $elapsed seconds");
    like( $error, qr/timed out/i, '_call dies with a timeout-specific error when the underlying request hangs' );
}

{
    require HTTP::Response;
    my $res = HTTP::Response->new( 200, 'OK' );
    $res->header( 'Content-Type' => 'application/json' );
    $res->content('{"ok":true,"result":{"id":1,"username":"testbot"}}');

    my $ua = Fake::FastUA->new( timeout => 1, response => $res );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    my $result = $tg->get_me;
    is( $result->{username}, 'testbot', 'a fast, successful request is completely unaffected by the hard timeout wrapper' );
}

done_testing();
