use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
use Fake::Telegram;

# TGT-142 (live Telegram question, msg #170, answered by Michael msg
# #173: "create a ticket to implement that, use the origin name instead
# of user id"): D2TG::Poller::run_once previously derived every printed
# sender from $message->{from} only - the immediate sender of the
# update, which for a forwarded message is the forwarder (B), not the
# original author (A). Telegram's Bot API's forward_origin field
# (Bot API 7.0+) names the original sender when present; this was
# already reaching the poller untouched (D2TG::Telegram::get_updates
# strips no fields) but never read.

sub _run_and_capture {
    my ($update) = @_;
    my $telegram = Fake::Telegram->new( [$update] );
    my @lines;
    {
        local *STDOUT;
        open STDOUT, '>', \my $captured or die $!;
        D2TG::Poller::run_once( $telegram, 0, undef );
        close STDOUT;
        @lines = split /\n/, $captured;
    }
    return $lines[0] // '';
}

{
    # MessageOriginUser: a real original sender with a username.
    my $update = {
        update_id => 1,
        message   => {
            message_id     => 10,
            chat            => { id => 999 },
            from            => { username => 'forwarder_b' },
            text            => 'fwd text',
            forward_origin  => {
                type        => 'user',
                date        => 1234567890,
                sender_user => { username => 'original_a', first_name => 'Alice' },
            },
        },
    };

    my $line = _run_and_capture($update);
    like( $line, qr/original_a \(forwarded by forwarder_b\)/,
        'MessageOriginUser: names the original sender alongside the forwarder' );
}

{
    # MessageOriginUser with no username, only first_name - name, not id.
    my $update = {
        update_id => 2,
        message   => {
            message_id     => 11,
            chat            => { id => 999 },
            from            => { username => 'forwarder_b' },
            text            => 'fwd text',
            forward_origin  => {
                type        => 'user',
                date        => 1234567890,
                sender_user => { id => 5555555, first_name => 'Alice' },
            },
        },
    };

    my $line = _run_and_capture($update);
    like( $line, qr/Alice \(forwarded by forwarder_b\)/,
        'MessageOriginUser without a username falls back to first_name, never the numeric id' );
    unlike( $line, qr/5555555/, 'the numeric sender_user id is never printed' );
}

{
    # MessageOriginHiddenUser: Telegram itself withholds the real
    # identity - only a name string is ever available to a bot.
    my $update = {
        update_id => 3,
        message   => {
            message_id      => 12,
            chat             => { id => 999 },
            from             => { username => 'forwarder_b' },
            text             => 'fwd text',
            forward_origin   => {
                type             => 'hidden_user',
                date             => 1234567890,
                sender_user_name => 'Private Person',
            },
        },
    };

    my $line = _run_and_capture($update);
    like( $line, qr/Private Person \(forwarded by forwarder_b\)/,
        'MessageOriginHiddenUser prints exactly the name string Telegram exposes' );
}

{
    # MessageOriginChat: forwarded from a group/chat, not a person.
    my $update = {
        update_id => 4,
        message   => {
            message_id    => 13,
            chat           => { id => 999 },
            from           => { username => 'forwarder_b' },
            text           => 'fwd text',
            forward_origin => {
                type        => 'chat',
                date        => 1234567890,
                sender_chat => { title => 'Some Group Chat' },
            },
        },
    };

    my $line = _run_and_capture($update);
    like( $line, qr/Some Group Chat \(forwarded by forwarder_b\)/,
        'MessageOriginChat names the originating chat, not a person' );
}

{
    # MessageOriginChannel: forwarded from a channel.
    my $update = {
        update_id => 5,
        message   => {
            message_id    => 14,
            chat           => { id => 999 },
            from           => { username => 'forwarder_b' },
            text           => 'fwd text',
            forward_origin => {
                type => 'channel',
                date => 1234567890,
                chat => { title => 'Some Channel' },
            },
        },
    };

    my $line = _run_and_capture($update);
    like( $line, qr/Some Channel \(forwarded by forwarder_b\)/,
        'MessageOriginChannel names the originating channel' );
}

{
    # No forward_origin at all - an ordinary message - behavior is
    # completely unchanged from before this ticket.
    my $update = {
        update_id => 6,
        message   => {
            message_id => 15,
            chat        => { id => 999 },
            from        => { username => 'ordinary_sender' },
            text        => 'not forwarded',
        },
    };

    my $line = _run_and_capture($update);
    like( $line, qr/ordinary_sender:/, 'a non-forwarded message prints only the immediate sender, unchanged' );
    unlike( $line, qr/forwarded by/, 'no "(forwarded by ...)" suffix appears for a non-forwarded message' );
}

{
    # Codex review finding: a hostile origin display name (embedded
    # newline/control characters, matching the exact hostile-input
    # class _sanitize_for_stdout already exists to neutralize for every
    # other user-supplied string this poller prints) must never reach
    # stdout unsanitized just because it arrived via forward_origin
    # instead of $message->{text}.
    my $update = {
        update_id => 7,
        message   => {
            message_id     => 16,
            chat            => { id => 999 },
            from            => { username => 'forwarder_b' },
            text            => 'fwd text',
            forward_origin  => {
                type        => 'hidden_user',
                date        => 1234567890,
                sender_user_name => "Evil\nName\x1b[31mRed\x1b[0m",
            },
        },
    };

    my $line = _run_and_capture($update);
    unlike( $line, qr/\n.*\n/s, 'a forward_origin display name with an embedded newline never breaks the single printed line' );
    unlike( $line, qr/\e/, 'a forward_origin display name with an embedded ANSI escape is stripped before reaching stdout' );
    like( $line, qr/Evil\\nName/, 'the newline is escaped visibly (\\n), matching _sanitize_for_stdout\'s own convention, not silently dropped' );
}

{
    # Codex review finding: the reply-context path (_reply_context_suffix,
    # not run_once's own top-level sender) has the same gap and the
    # same fix - a message replying to a FORWARDED message must also
    # name the original sender, not the forwarder, in its "(replying
    # to ...)" suffix.
    my $update = {
        update_id => 8,
        message   => {
            message_id       => 17,
            chat              => { id => 999 },
            from              => { username => 'replier' },
            text              => 'my reply',
            reply_to_message  => {
                message_id     => 16,
                from           => { username => 'forwarder_b' },
                text           => 'the original forwarded text',
                forward_origin => {
                    type        => 'user',
                    date        => 1234567890,
                    sender_user => { username => 'original_a' },
                },
            },
        },
    };

    my $line = _run_and_capture($update);
    like( $line, qr/replying to original_a \(forwarded by forwarder_b\)/,
        'the reply-context suffix also names the original sender of a forwarded message being replied to, not just the forwarder' );
}

{
    # An unrecognized/future forward_origin type (e.g. a Bot API
    # addition this ticket doesn't know about yet) must not be treated
    # as a forward at all - falls back to exactly the non-forwarded
    # behavior rather than guessing or crashing.
    my $update = {
        update_id => 9,
        message   => {
            message_id     => 18,
            chat            => { id => 999 },
            from            => { username => 'forwarder_b' },
            text            => 'fwd text',
            forward_origin  => { type => 'some_future_type_this_code_does_not_know' },
        },
    };

    my $line = _run_and_capture($update);
    like( $line, qr/forwarder_b:/, 'an unrecognized forward_origin type falls back to the immediate sender' );
    unlike( $line, qr/forwarded by/, 'no "(forwarded by ...)" suffix appears for an unrecognized forward_origin type' );
}

done_testing();
