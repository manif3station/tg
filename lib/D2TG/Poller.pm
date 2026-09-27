package D2TG::Poller;

use strict;
use warnings;
use POSIX qw(strftime);
use D2TG::Poller::Format;
use D2TG::Poller::Safe;
use D2TG::Poller::Dispatch;

sub run_once {
    my ( $telegram, $offset, $store, %opts ) = @_;

    my $transcribe_voice = $opts{transcribe_voice};
    my $download_media   = $opts{download_media};
    my $bot_token        = $opts{bot_token};

    my ( $updates, $next_offset ) = $telegram->get_updates( offset => $offset );

    # TGT-178 (Michael's Q-011 ruling on TGT-176's message-loss
    # investigation): a store write failure inside a handler is
    # non-fatal, but the offset used to advance past the failed update
    # regardless - Telegram never redelivers an update once the offset
    # has moved past it, so that message's local history was
    # permanently, silently lost. Track the first update_id (in
    # iteration order, which is also the earliest, since Telegram
    # delivers updates in increasing update_id order) whose
    # record_message call failed; if any did, cap the returned offset
    # there below instead of the batch's own full next offset, so
    # Telegram redelivers that update (and everything after it in the
    # same batch) next cycle.
    my $offset_cap;

    # TGT-343 (found via a scheduled JOB-004 improvement hunt): a
    # Telegram album (2+ photos/documents sharing one media_group_id)
    # is grouped by partition_media_groups and dispatched once per
    # group via handle_media_group_update, instead of once per part -
    # see that function's own comment. Reactions/edited messages never
    # carry media_group_id (partition_media_groups leaves them
    # standalone unchanged) so their handling below is untouched.
    #
    # Iteration below still walks @$updates in its own original order
    # (never the separately-ordered $groups/$standalone lists) - a real
    # album's parts are always consecutive/near-consecutive update_ids
    # in practice, but preserving the ORIGINAL per-update_id order here
    # regardless is what keeps TGT-178's own offset_cap invariant
    # ("the first FAILED update_id in iteration order is also the
    # earliest, since Telegram delivers in increasing update_id order")
    # true even in a contrived/defensive input shape. A group is
    # dispatched once, at the position of its first-encountered member;
    # every later member of the same group is then skipped here (it was
    # already processed as part of that one dispatch).
    my ( $groups, undef ) = D2TG::Poller::Dispatch::partition_media_groups($updates);
    my %group_by_id = map { $_->[0]{message}{media_group_id} => $_ } @$groups;
    my %group_handled;

    for my $update (@$updates) {
        my $update_id = $update->{update_id};

        if ( my $reaction = $update->{message_reaction} ) {
            D2TG::Poller::Dispatch::handle_message_reaction( $reaction, $store, $bot_token );
            next;
        }

        if ( my $edited = $update->{edited_message} ) {
            D2TG::Poller::Dispatch::handle_edited_message( $edited, $update_id, \$offset_cap, $store, $bot_token );
            next;
        }

        my $media_group_id = $update->{message}{media_group_id};
        if ( defined $media_group_id && $group_by_id{$media_group_id} ) {
            next if $group_handled{$media_group_id}++;
            D2TG::Poller::Dispatch::handle_media_group_update(
                $group_by_id{$media_group_id}, \$offset_cap, $telegram, $store, $bot_token, $download_media
            );
            next;
        }

        D2TG::Poller::Dispatch::handle_plain_update(
            $update, $update_id, \$offset_cap, $telegram, $store, $bot_token,
            $transcribe_voice, $download_media
        );
    }

    # TGT-178: if any update's record_message call failed, cap the
    # returned offset there instead of the batch's own full next
    # offset - see $offset_cap's own comment above the loop.
    if ( defined $offset_cap && ( !defined $next_offset || $offset_cap < $next_offset ) ) {
        $next_offset = $offset_cap;
    }

    return ( $updates, $next_offset );
}

# TGT-259 originally kept 11 of D2TG::Poller::Format's 13 relocated
# functions forwarded here for every internal Poller.pm call site.
# TGT-276 moved run_once's own branch dispatch (the only internal
# caller of 10 of those 11) into D2TG::Poller::Dispatch, which calls
# D2TG::Poller::Format's bare functions directly - leaving only
# _bot_flag with a real caller left (t/226-bot-flag-helper-extracted.t,
# an external test). The other 10 are now permanently-uncallable dead
# code and were removed, matching TGT-259's own precedent for
# _stored_summary/_forward_origin_name ("the other three helpers have
# no caller outside police_world itself and get none").
sub _bot_flag { return D2TG::Poller::Format::bot_flag(@_) }

1;
