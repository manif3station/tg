use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;
require Fake::Store;

package main;

# TGT-343 (found via a scheduled JOB-004 improvement hunt): a real
# Telegram album - N photos/documents sharing one media_group_id,
# delivered together in one getUpdates batch - used to surface as N
# separate NEW TG MEDIA lines and N separate REPLY WITH templates, one
# per part, since nothing grouped them. End-to-end test through the
# real run_once entrypoint (not just the unit-level partition/helper
# tests) proving the fix: exactly one grouped announce, every part
# still individually downloaded and stored.

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
            { update_id => 400, message => { message_id => 200, chat => { id => 999 }, from => { username => 'ada' }, media_group_id => 'alb-1', photo => [ { file_id => 'p1' } ] } },
            { update_id => 401, message => { message_id => 201, chat => { id => 999 }, from => { username => 'ada' }, media_group_id => 'alb-1', photo => [ { file_id => 'p2' } ] } },
            { update_id => 402, message => { message_id => 202, chat => { id => 999 }, from => { username => 'ada' }, media_group_id => 'alb-1', photo => [ { file_id => 'p3' } ] } },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my @calls;
    my $download_media = sub { my ( $telegram, $file_id ) = @_; push @calls, $file_id; return "/tmp/$file_id.jpg"; };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    is( scalar(@calls), 3, 'all 3 album parts were individually downloaded' );
    is_deeply( [ sort @calls ], [ 'p1', 'p2', 'p3' ], 'download_media was called with every part\'s own file_id' );

    my $album_line_count = () = $out =~ /NEW TG MEDIA ALBUM/g;
    is( $album_line_count, 1, 'exactly one grouped NEW TG MEDIA ALBUM line, not one per part' );

    my $individual_line_count = () = $out =~ /NEW TG MEDIA \[/g;
    is( $individual_line_count, 0, 'no individual NEW TG MEDIA line leaked through for any part' );

    like( $out, qr/3 x photo/, 'the grouped line names the count and media kind' );
    like( $out, qr/#200.*#201.*#202/s, 'the grouped line names every message_id in the album' );

    my $attachment_line_count = () = $out =~ /GET ATTACHMENT WITH: d2 tg\.attachment 999 \d+/g;
    is( $attachment_line_count, 3, 'one GET ATTACHMENT WITH line per part (each individually fetchable)' );

    my $reply_line_count = () = $out =~ /d2 tg\.reply/g;
    is( $reply_line_count, 1, 'exactly one REPLY WITH template for the whole album, not one per part' );

    is( $err, '', 'nothing printed to stderr on success' );

    for my $mid ( 200, 201, 202 ) {
        ok( $store->get_message( 999, $mid ), "part with message_id $mid was individually recorded in the store" );
    }
}

{
    # A single non-grouped photo (no media_group_id) must still behave
    # exactly as before this ticket - the pre-existing regression net
    # (t/09, t/18, etc.) already covers this in depth; this is a
    # lightweight confirmation it isn't accidentally routed through the
    # new group path.
    my $tg = Fake::Telegram->new(
        [ { update_id => 500, message => { message_id => 300, chat => { id => 999 }, from => { username => 'ada' }, photo => [ { file_id => 'solo' } ] } } ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $download_media = sub { return '/tmp/solo.jpg'; };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    unlike( $out, qr/ALBUM/, 'a lone photo with no media_group_id is never announced as an album' );
    like( $out, qr/NEW TG MEDIA \[999\]/, 'a lone photo still gets its own individual announce line' );
}

done_testing();
