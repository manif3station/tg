package D2TG::Poller::MediaGroup;

use strict;
use warnings;
use D2TG::Poller::Dispatch;
use D2TG::Poller::Format;

# TGT-343 (found via a scheduled JOB-004 improvement hunt): extracted
# out of D2TG::Poller::Dispatch, which crossed this project's own
# 500-line-per-module cap once this ticket's own code landed there -
# these two functions (album partitioning and album dispatch) are a
# genuinely separable concern from the rest of that module's
# per-update branch dispatch, matching the same reasoning that already
# split D2TG::Poller::Safe/D2TG::Poller::Format out of D2TG::Poller.pm
# itself. Full documentation lives in D2TG/Poller/MediaGroup.pod
# (REQ-028: POD in a separate file).

# A Telegram album is delivered as separate updates that all share the
# same message.media_group_id - Telegram groups every part together
# before delivery, so a bot polling at any normal interval already
# receives all of them in the same getUpdates batch. This pure
# partition step makes zero changes to handle_plain_update's own
# already-hardened access-control/dedup/offset-tracking logic.
#
# A lone update carrying a media_group_id is deliberately still
# standalone (not a 1-item "group") - Telegram's real Bot API never
# sends a genuine 1-part album, and treating a defensive/malformed
# single-part case as standalone keeps this helper's output shape
# simple: a "group" always means 2+ parts to actually combine.
sub partition_media_groups {
    my ($updates) = @_;

    my %by_group;
    for my $update (@$updates) {
        my $media_group_id = $update->{message}{media_group_id};
        push @{ $by_group{$media_group_id} }, $update if defined $media_group_id;
    }

    my @groups;
    my @standalone;
    my %group_emitted;

    for my $update (@$updates) {
        my $media_group_id = $update->{message}{media_group_id};

        if ( defined $media_group_id && @{ $by_group{$media_group_id} } > 1 ) {
            push @groups, $by_group{$media_group_id} unless $group_emitted{$media_group_id}++;
        }
        else {
            push @standalone, $update;
        }
    }

    return ( \@groups, \@standalone );
}

# Called once per media_group_id group formed by partition_media_groups
# (a real Telegram album - 2+ photos/documents sent together sharing
# one media_group_id). Runs D2TG::Poller::Dispatch::handle_plain_update
# on every member exactly as a standalone update would be, so access
# control, dedup, download, storage and offset-tracking are unchanged
# and fully reused - only passes group_collect_ref so each member's own
# individual stdout announce is suppressed, then prints ONE combined
# NEW TG MEDIA ALBUM line (naming every message_id collected) plus one
# GET ATTACHMENT WITH per part plus one shared reply template, instead
# of N separate announces.
#
# TGT-344 (found via a scheduled JOB-004 improvement hunt, reviewing
# TGT-343's own fresh diff): the combined announce/reply line below
# reads chat_id/sender only from the group's FIRST member - this
# assumes every member of a group shares one chat_id, the same way
# partition_media_groups's own comment already states its lone-group
# assumption explicitly. Live-tested: a defensive/malformed group
# whose members carried different chat_id values would silently
# misattribute later parts to the first part's chat in the summary/
# reply line - not a reachable defect, since Telegram's real Bot API
# guarantees media_group_id is scoped per-chat and never spans two
# chats, the same protocol guarantee the lone-group case already
# relies on.
sub handle_media_group_update {
    my ( $group, $offset_cap_ref, $telegram, $store, $bot_token, $download_media ) = @_;

    return unless @$group;

    my @collected;
    for my $update (@$group) {
        my $update_id = $update->{update_id};
        D2TG::Poller::Dispatch::handle_plain_update( $update, $update_id, $offset_cap_ref, $telegram, $store, $bot_token, undef, $download_media, \@collected );
    }

    return unless @collected;

    my $first_message = $group->[0]{message};
    my $chat_id        = $first_message->{chat}{id};
    my $sender         = D2TG::Poller::Format::compute_sender( $chat_id, $first_message );
    my $ts = D2TG::Poller::Format::timestamp_prefix($first_message);

    my $count      = scalar(@collected);
    my $media_kind = $collected[0]{media_kind};
    my $msg_ids    = join( ', ', map { "#$_->{message_id}" } grep { defined $_->{message_id} } @collected );
    my $msg_note   = length($msg_ids) ? " (msgs $msg_ids)" : '';

    print "$ts NEW TG MEDIA ALBUM [$chat_id] $sender: $count x $media_kind$msg_note\n";
    for my $item (@collected) {
        D2TG::Poller::Format::print_attachment_template( $item->{chat_id}, $item->{message_id} ) if defined $item->{message_id};
    }
    D2TG::Poller::Format::print_reply_template( $chat_id, $collected[0]{message_id}, $bot_token );

    return;
}

1;
