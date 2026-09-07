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
                update_id => 300,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, document => { file_id => 'doc1' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my @calls;
    my $download_media = sub { my ( $telegram, $file_id ) = @_; push @calls, $file_id; return '/tmp/doc1.bin'; };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    is_deeply( \@calls, ['doc1'], 'download_media was called with the document file_id' );
    like( $out, qr/999/,          'stdout names the chat id' );
    like( $out, qr{/tmp/doc1\.bin}, 'stdout carries the downloaded local path' );
    is( $err, '', 'nothing is printed to stderr on success' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 301,
                message   => {
                    chat => { id => 999 }, from => { username => 'ada' },
                    photo => [ { file_id => 'small' }, { file_id => 'medium' }, { file_id => 'large' } ],
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my @calls;
    my $download_media = sub { my ( $telegram, $file_id ) = @_; push @calls, $file_id; return '/tmp/photo.jpg'; };

    capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    is_deeply( \@calls, ['large'], 'the LAST (largest) PhotoSize entry is selected, not the first' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 302,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, document => { file_id => 'doc2' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $download_media = sub { die "network unreachable\n"; };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    unlike( $out, qr{/tmp}, 'no local-path line appears on stdout when download fails' );
    like( $err, qr/network unreachable/, 'the failure is reported on stderr' );
    like( $err, qr/999/, 'the stderr line names the chat id' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 303,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, document => { file_id => 'doc3' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store );    # no download_media given
    } );

    like( $out, qr/document/i, 'without download_media, the old MEDIA-line behavior is unchanged' );
}

done_testing();
