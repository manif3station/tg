use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;
require Fake::Store;

package main;

# TGT-346 (found via a scheduled JOB-004 improvement hunt, reviewing
# TGT-343's own fresh MediaGroup.pm): handle_media_group_update's
# combined NEW TG MEDIA ALBUM line never surfaced any collected part's
# caption_note, even though the single-item (non-grouped) announce
# always includes it. Telegram typically attaches a caption to only
# one part of a real album - this proves the first non-empty caption
# found among the collected parts is surfaced in the grouped line.

use Test::Capture qw(capture_std);

{
    my $tg = Fake::Telegram->new(
        [
            { update_id => 600, message => { message_id => 700, chat => { id => 999 }, from => { username => 'ada' }, media_group_id => 'alb-cap', photo => [ { file_id => 'c1' } ], caption => 'look at this!' } },
            { update_id => 601, message => { message_id => 701, chat => { id => 999 }, from => { username => 'ada' }, media_group_id => 'alb-cap', photo => [ { file_id => 'c2' } ] } },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $download_media = sub { my ( $telegram, $file_id ) = @_; return "/tmp/$file_id.jpg"; };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    my $album_line_count = () = $out =~ /NEW TG MEDIA ALBUM/g;
    is( $album_line_count, 1, 'still exactly one grouped album line with a caption present' );
    like( $out, qr/NEW TG MEDIA ALBUM.*caption: look at this!/, 'the album line surfaces the caption from the part that carries it' );
    is( $err, '', 'nothing printed to stderr' );
}

{
    # No part carries a caption - the album line must not gain a bare
    # trailing " - caption: " with nothing after it.
    my $tg = Fake::Telegram->new(
        [
            { update_id => 610, message => { message_id => 710, chat => { id => 999 }, from => { username => 'ada' }, media_group_id => 'alb-nocap', photo => [ { file_id => 'n1' } ] } },
            { update_id => 611, message => { message_id => 711, chat => { id => 999 }, from => { username => 'ada' }, media_group_id => 'alb-nocap', photo => [ { file_id => 'n2' } ] } },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $download_media = sub { return '/tmp/x.jpg'; };

    my ( $out, undef ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    unlike( $out, qr/caption/, 'no caption text appears when no part carries one' );
}

done_testing();
