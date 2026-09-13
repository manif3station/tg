use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Config;

# TGT-218 (found via a scheduled JOB-003 hourly bug hunt): D2TG::Config
# ::require_chat_id_or_warn (TGT-155/164) validates D2TG_CHAT_ID against
# Telegram's own canonical chat-id shape (/^-?\d+$/) before the poller
# starts, specifically because a mangled value can never string-eq
# match a real inbound chat_id, silently locking the owner out forever
# with zero warning. bot_groups' own --chat_id handling was never given
# the same check - it only rejected a missing/empty/flag-looking value
# via shift_flag_value, never a present-but-non-numeric one. A
# whitespace-padded or non-digit --chat_id value used to be accepted
# silently, later causing the exact same invisible lockout
# require_chat_id_or_warn already exists to prevent for D2TG_CHAT_ID.

{
    eval {
        D2TG::Config::bot_groups(
            argv        => [ '--chat_id', ' 12345', '--bot', 'tok1' ],
            env_chat_id => undef,
            env_token   => undef,
        );
    };
    like( $@, qr/chat_id/i, 'bot_groups refuses a whitespace-padded --chat_id value' );
    like( $@, qr/12345/, 'the message names the malformed value' );
}

{
    eval {
        D2TG::Config::bot_groups(
            argv        => [ '--chat_id', 'abc', '--bot', 'tok1' ],
            env_chat_id => undef,
            env_token   => undef,
        );
    };
    like( $@, qr/chat_id/i, 'bot_groups refuses a non-numeric --chat_id value' );
    like( $@, qr/abc/, 'the message names the malformed value' );
}

# Regression: valid positive and negative (group/channel) chat_ids are
# completely unaffected.
{
    my ( $groups, @rest ) = D2TG::Config::bot_groups(
        argv        => [ '--chat_id', '1234', '--bot', 't1' ],
        env_chat_id => undef,
        env_token   => undef,
    );
    is( $groups->[0]{chat_id}, '1234', 'a valid positive chat_id is unaffected' );
}

{
    my ( $groups, @rest ) = D2TG::Config::bot_groups(
        argv        => [ '--chat_id', '-987654321', '--bot', 't1' ],
        env_chat_id => undef,
        env_token   => undef,
    );
    is( $groups->[0]{chat_id}, '-987654321', 'a valid negative (group/channel) chat_id is unaffected' );
}

done_testing();
