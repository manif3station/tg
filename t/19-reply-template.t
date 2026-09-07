use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;
require Fake::Store;

package main;

sub capture_std {
    my ($code) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $out_fh, '>', \$out or die $!;
    my $old_out = select $out_fh;
    local *STDERR;
    open STDERR, '>', \$err or die $!;
    $code->();
    select $old_out;
    return ( $out, $err );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 400,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, text => 'hello' },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );

    my ($out) = capture_std( sub { D2TG::Poller::run_once( $tg, undef, $store ); } );

    like( $out, qr/REPLY WITH: d2 tg\.reply 999/, 'a text message is followed by a REPLY WITH template naming the chat id' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 401,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, voice => { file_id => 'v1' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $transcribe_voice = sub { return 'hello there'; };

    my ($out) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, transcribe_voice => $transcribe_voice );
    } );

    like( $out, qr/REPLY WITH: d2 tg\.reply 999/, 'a successfully transcribed voice message gets a REPLY WITH template too' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 402,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, document => { file_id => 'd1' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $download_media = sub { return '/tmp/doc.bin'; };

    my ($out) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    like( $out, qr/REPLY WITH: d2 tg\.reply 999/, 'a successfully downloaded document gets a REPLY WITH template too' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 403,
                message   => { chat => { id => 111 }, from => { username => 'stranger' }, text => 'hi' },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );

    my ($out) = capture_std( sub { D2TG::Poller::run_once( $tg, undef, $store ); } );

    unlike( $out, qr/REPLY WITH/, 'a pending-notification line never gets a REPLY WITH template' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 404,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, voice => { file_id => 'v2' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $transcribe_voice = sub { die "whisper unavailable\n"; };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, transcribe_voice => $transcribe_voice );
    } );

    unlike( $out, qr/REPLY WITH/, 'a transcription-error line never gets a REPLY WITH template' );
    unlike( $err, qr/REPLY WITH/, '...on stdout or stderr' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 405,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, document => { file_id => 'd2' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $download_media = sub { die "network unreachable\n"; };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    unlike( $out, qr/REPLY WITH/, 'a media-download-error line never gets a REPLY WITH template' );
    unlike( $err, qr/REPLY WITH/, '...on stdout or stderr' );
}

done_testing();
