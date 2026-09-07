use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;
require Fake::Store;

package main;

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

for my $case (
    [ photo    => { photo    => [ { file_id => 'abc' } ] } ],
    [ document => { document => { file_id => 'def' } } ],
    [ voice    => { voice    => { file_id => 'ghi' } } ],
  )
{
    my ( $kind, $media_field ) = @$case;

    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 100,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, %$media_field },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );

    my $out = capture_stdout( sub {
        D2TG::Poller::run_once( $tg, undef, $store );
    } );

    like( $out, qr/999/,  "$kind: stdout names the chat id" );
    like( $out, qr/$kind/i, "$kind: stdout names the media type" );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 101,
                message   => { chat => { id => 111 }, from => { username => 'stranger' }, voice => { file_id => 'xyz' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );

    my $out = capture_stdout( sub {
        D2TG::Poller::run_once( $tg, undef, $store );
    } );

    unlike( $out, qr/voice/i, 'a non-allow-listed sender\'s media does not get a media-type line' );
    like( $out, qr/111/, 'instead the pending notification appears, naming the chat id' );
    is_deeply( $store->{pending}, [111], 'and the sender was recorded pending' );
}

done_testing();
