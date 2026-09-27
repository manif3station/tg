use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Poller::MediaGroup;

# TGT-343 (found via a scheduled JOB-004 improvement hunt): a Telegram
# album (several photos/documents sent together) is delivered as
# separate updates that all share the same message.media_group_id -
# nothing in this codebase groups them, so each part surfaces as its
# own independent NEW TG MEDIA line and its own REPLY WITH template.
# This is the first increment toward fixing that: a pure helper that
# partitions a getUpdates batch into media_group_id clusters (order
# preserved) vs standalone updates, with zero changes yet to
# handle_plain_update's own already-hardened access-control/dedup/
# offset-tracking logic.

sub _update {
    my (%args) = @_;
    return {
        update_id => $args{update_id},
        message   => {
            message_id     => $args{update_id},
            media_group_id => $args{media_group_id},
            chat           => { id => 1 },
        },
    };
}

subtest 'no media_group_id anywhere: everything is standalone' => sub {
    my @updates = ( _update( update_id => 1 ), _update( update_id => 2 ) );
    my ( $groups, $standalone ) = D2TG::Poller::MediaGroup::partition_media_groups( \@updates );
    is( scalar(@$groups),     0, 'no groups formed' );
    is( scalar(@$standalone), 2, 'both updates are standalone' );
    is( $standalone->[0]{update_id}, 1, 'standalone order preserved (1st)' );
    is( $standalone->[1]{update_id}, 2, 'standalone order preserved (2nd)' );
};

subtest 'a single 3-part album is grouped together, order preserved' => sub {
    my @updates = (
        _update( update_id => 1, media_group_id => 'grp-A' ),
        _update( update_id => 2, media_group_id => 'grp-A' ),
        _update( update_id => 3, media_group_id => 'grp-A' ),
    );
    my ( $groups, $standalone ) = D2TG::Poller::MediaGroup::partition_media_groups( \@updates );
    is( scalar(@$groups),     1, 'exactly one group formed' );
    is( scalar(@$standalone), 0, 'nothing left standalone' );
    is( scalar( @{ $groups->[0] } ), 3, 'the group has all 3 parts' );
    is( $groups->[0][0]{update_id}, 1, 'group order preserved (1st part)' );
    is( $groups->[0][2]{update_id}, 3, 'group order preserved (3rd part)' );
};

subtest 'a mix of one album, one standalone message, and a second album is handled correctly' => sub {
    my @updates = (
        _update( update_id => 1, media_group_id => 'grp-A' ),
        _update( update_id => 2 ),
        _update( update_id => 3, media_group_id => 'grp-A' ),
        _update( update_id => 4, media_group_id => 'grp-B' ),
        _update( update_id => 5, media_group_id => 'grp-B' ),
    );
    my ( $groups, $standalone ) = D2TG::Poller::MediaGroup::partition_media_groups( \@updates );
    is( scalar(@$groups),     2, 'two distinct groups formed (grp-A, grp-B)' );
    is( scalar(@$standalone), 1, 'exactly one standalone update' );
    is( $standalone->[0]{update_id}, 2, 'the standalone update is the right one' );
    is( scalar( @{ $groups->[0] } ), 2, 'grp-A has its 2 parts' );
    is( scalar( @{ $groups->[1] } ), 2, 'grp-B has its 2 parts' );
};

subtest 'a lone update carrying a media_group_id (Telegram never sends a real 1-part album, but defensively) is treated as standalone, not a 1-item group' => sub {
    my @updates = ( _update( update_id => 1, media_group_id => 'grp-solo' ) );
    my ( $groups, $standalone ) = D2TG::Poller::MediaGroup::partition_media_groups( \@updates );
    is( scalar(@$groups),     0, 'no group formed for a lone media_group_id' );
    is( scalar(@$standalone), 1, 'treated as standalone instead' );
};

subtest 'updates with no message key (e.g. a bare edited_message/reaction update) are passed through as standalone untouched' => sub {
    my @updates = ( { update_id => 1 }, _update( update_id => 2 ) );
    my ( $groups, $standalone ) = D2TG::Poller::MediaGroup::partition_media_groups( \@updates );
    is( scalar(@$groups),     0, 'no group formed' );
    is( scalar(@$standalone), 2, 'both passed through as standalone' );
};

subtest 'a lone media_group_id interleaved with real standalone updates keeps original relative order' => sub {
    my @updates = (
        _update( update_id => 1 ),
        _update( update_id => 2, media_group_id => 'grp-solo' ),
        _update( update_id => 3 ),
    );
    my ( $groups, $standalone ) = D2TG::Poller::MediaGroup::partition_media_groups( \@updates );
    is( scalar(@$groups),     0, 'no group formed' );
    is( scalar(@$standalone), 3, 'all 3 are standalone' );
    is( $standalone->[0]{update_id}, 1, 'original position 1 preserved' );
    is( $standalone->[1]{update_id}, 2, 'the demoted lone-group update stays in its original position, not appended at the end' );
    is( $standalone->[2]{update_id}, 3, 'original position 3 preserved' );
};

done_testing();
