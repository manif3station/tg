use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;
require Fake::Store;

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

# TGT-161 (found via a scheduled hourly bug hunt): D2TG::Poller::_media_kind
# only recognizes photo/document/voice, so a video message (no caption, no
# plain text) fails run_once's own "next unless text or media_kind" guard
# and is silently dropped - not printed, not queued pending, not recorded,
# no stderr line, offset still advances. This asserts the fix: a video
# message is announced and recorded exactly like an undownloaded
# photo/document already is.

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 800,
                message   => {
                    message_id => 10,
                    date       => 1_700_000_000,
                    chat       => { id => 444 },
                    from       => { username => 'dana' },
                    video      => { file_id => 'videofile' },
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [444] );
    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $out, qr/NEW TG MEDIA \[444\] dana: video/,
        'a plain video message (no caption) is announced, not silently dropped' );

    ok( $store->get_message( 444, 10 ),
        'the video message is recorded in the store, matching the existing photo/document/voice fallback behavior' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 801,
                message   => {
                    message_id => 11,
                    date       => 1_700_000_000,
                    chat       => { id => 444 },
                    from       => { username => 'dana' },
                    video      => { file_id => 'videofile2' },
                    caption    => 'look at this',
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [444] );
    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $out, qr/NEW TG MEDIA \[444\] dana: video - caption: look at this/,
        'a video message WITH a caption includes the caption exactly as photo/document already do' );
}

{
    # An unapproved sender's video must still go through the ordinary
    # pending-approval path, exactly like a text/photo/document message
    # already does - a media kind reaching the fallback branch is not a
    # bypass of access control.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 802,
                message   => {
                    message_id => 12,
                    date       => 1_700_000_000,
                    chat       => { id => 555 },
                    from       => { username => 'eve' },
                    video      => { file_id => 'videofile3' },
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [] );
    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $out, qr/NEW TG PENDING \[555\] awaiting approval/,
        'an unapproved sender\'s video message queues pending approval, same as any other message kind' );
    unlike( $out, qr/NEW TG MEDIA/,
        'an unapproved sender\'s video is never announced as content' );
}

{
    # Video has no download path at all - it must always take the
    # generic fallback branch and never invoke download_media, even
    # when that callback is supplied (unlike photo/document, which use
    # it when given).
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 803,
                message   => {
                    message_id => 13,
                    date       => 1_700_000_000,
                    chat       => { id => 444 },
                    from       => { username => 'dana' },
                    video      => { file_id => 'videofile4' },
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [444] );
    my @calls;
    my $download_media = sub { my ( $telegram, $file_id ) = @_; push @calls, $file_id; return '/tmp/should-not-happen.mp4'; };
    my $out = capture_stdout(
        sub { D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media ) } );

    is_deeply( \@calls, [], 'download_media is never called for a video, even when supplied' );
    like( $out, qr/NEW TG MEDIA \[444\] dana: video/,
        'the video is still announced via the generic fallback, regardless of download_media being given' );
}

done_testing();
