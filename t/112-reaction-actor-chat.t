use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use Fake::Telegram;

require D2TG::Poller;

# TGT-154 (JOB-003 scheduled hourly bug hunt finding, 2026-09-09): Telegram's
# MessageReactionUpdated has 'user' as optional - when a reaction is made
# anonymously on behalf of a chat/channel (e.g. a channel admin reacting as
# the channel itself), Telegram omits 'user' entirely and supplies
# 'actor_chat' (a Chat object) instead. run_once's message_reaction branch
# only ever read $reaction->{user}{username}, silently printing "sender:
# unknown" for every anonymous-channel reaction even though Telegram
# supplied real identifying information via actor_chat. Same failure class
# TGT-142 already fixed once for forward_origin's own sender_chat/chat
# fields - this closes the identical gap for message_reaction.

sub _run_and_capture {
    my ($update) = @_;
    my $telegram = Fake::Telegram->new( [$update] );
    my $captured;
    {
        local *STDOUT;
        open STDOUT, '>', \$captured or die $!;
        D2TG::Poller::run_once( $telegram, 0, undef );
        close STDOUT;
    }
    return $captured // '';
}

{
    # No user field at all, actor_chat with a title - the channel's own
    # name must be printed, not 'unknown'.
    my $update = {
        update_id        => 1,
        message_reaction => {
            chat         => { id => 999 },
            message_id   => 50,
            actor_chat   => { title => 'My Channel' },
            old_reaction => [],
            new_reaction => [ { type => 'emoji', emoji => '👍' } ],
        },
    };

    my $captured = _run_and_capture($update);
    like( $captured, qr/NEW TG REACTION \[999\] My Channel: 👍 on message 50/,
        'an anonymous channel reaction (actor_chat with a title) names the channel, not unknown' );
}

{
    # actor_chat present but no title, only a username - falls back to
    # the username.
    my $update = {
        update_id        => 2,
        message_reaction => {
            chat         => { id => 999 },
            message_id   => 51,
            actor_chat   => { username => 'my_channel_handle' },
            old_reaction => [],
            new_reaction => [ { type => 'emoji', emoji => '👍' } ],
        },
    };

    my $captured = _run_and_capture($update);
    like( $captured, qr/NEW TG REACTION \[999\] my_channel_handle: 👍 on message 51/,
        'actor_chat with no title falls back to its username' );
}

{
    # Ordinary case: user present, no actor_chat - existing behavior
    # completely unaffected.
    my $update = {
        update_id        => 3,
        message_reaction => {
            chat         => { id => 999 },
            message_id   => 52,
            user         => { username => 'ordinary_reactor' },
            old_reaction => [],
            new_reaction => [ { type => 'emoji', emoji => '👍' } ],
        },
    };

    my $captured = _run_and_capture($update);
    like( $captured, qr/NEW TG REACTION \[999\] ordinary_reactor: 👍 on message 52/,
        'an ordinary user reaction is completely unaffected' );
}

{
    # Codex review finding: the REACTION REMOVED branch uses the exact
    # same sender-resolution code path as the add branch - confirm the
    # actor_chat fix applies there too, not only to additions.
    my $update = {
        update_id        => 4,
        message_reaction => {
            chat         => { id => 999 },
            message_id   => 53,
            actor_chat   => { title => 'Another Channel' },
            old_reaction => [ { type => 'emoji', emoji => '👍' } ],
            new_reaction => [],
        },
    };

    my $captured = _run_and_capture($update);
    like( $captured, qr/REACTION REMOVED \[999\] Another Channel: 👍 on message 53/,
        'a removal event also names the channel via actor_chat, not unknown' );
}

{
    # Codex review finding: a defensive precedence contract - if both
    # actor_chat and user were ever present together (not expected per
    # the Bot API's own documented semantics, but not a case to guess
    # wrong on), actor_chat takes priority, matching this branch's own
    # explicit truthiness check on actor_chat first.
    my $update = {
        update_id        => 5,
        message_reaction => {
            chat         => { id => 999 },
            message_id   => 54,
            actor_chat   => { title => 'Priority Channel' },
            user         => { username => 'should_not_be_used' },
            old_reaction => [],
            new_reaction => [ { type => 'emoji', emoji => '👍' } ],
        },
    };

    my $captured = _run_and_capture($update);
    like( $captured, qr/NEW TG REACTION \[999\] Priority Channel: 👍 on message 54/,
        'actor_chat takes precedence over user when both are present' );
}

done_testing();
