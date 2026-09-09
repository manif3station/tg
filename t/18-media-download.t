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
                message   => { message_id => 100, chat => { id => 999 }, from => { username => 'ada' }, document => { file_id => 'doc1' } },
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
    unlike( $out, qr{/tmp/doc1\.bin}, 'stdout never carries the real downloaded local path (TGT-133)' );
    like( $out, qr{GET ATTACHMENT WITH: d2 tg\.attachment 999 100}, 'stdout instead advises the attachment-fetch command (TGT-133)' );
    is( $err, '', 'nothing is printed to stderr on success' );

    my $stored = $store->get_message( 999, 100 );
    unlike( $stored->{summary}, qr{/tmp}, 'the stored summary never carries the real local path either (TGT-133)' );
    is( $store->get_attachment_path( 999, 100 ), '/tmp/doc1.bin', 'the real local path is retrievable only via get_attachment_path' );
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

{
    # TGT-092 (live production incident): a photo/document's caption was
    # never read or printed at all, causing a real miscommunication -
    # Michael sent a photo with a caption describing a problem, and the
    # agent monitoring the bridge never saw it.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 304,
                message   => {
                    message_id => 111,
                    chat       => { id => 999 }, from => { username => 'ada' },
                    document   => { file_id => 'doc4' },
                    caption    => 'please fix the thing described here',
                },
            },
        ],
    );
    my $store           = Fake::Store->new( allowed => [999] );
    my $download_media  = sub { return '/tmp/doc4.bin'; };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    like( $out, qr/please fix the thing described here/, 'a caption on a document message is printed on stdout (TGT-092)' );

    my $stored = $store->get_message( 999, 111 );
    like( $stored->{summary}, qr/please fix the thing described here/, 'the caption is also included in the stored summary' );
}

{
    # No caption present - unchanged from before.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 305,
                message   => {
                    message_id => 112,
                    chat       => { id => 999 }, from => { username => 'ada' },
                    document   => { file_id => 'doc5' },
                },
            },
        ],
    );
    my $store          = Fake::Store->new( allowed => [999] );
    my $download_media = sub { return '/tmp/doc5.bin'; };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    unlike( $out, qr/caption/i, 'no caption text/label appears when the message carries no caption' );
}

done_testing();
