use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

require D2TG::Config;
require D2TG::Config::Flags;

# TGT-213 (found via a scheduled JOB-004 improvement hunt): TGT-202's own
# duplicate-pair guard in D2TG::Config::Flags::bot_groups keys its dedup check
# on (chat_id, bot_token) combined - but the actual hazard TGT-202 was
# fixing (two poller @pairs entries racing the same get_offset/
# set_offset calls for one bot token) is keyed on the bot TOKEN ALONE:
# D2TG::Store::_offset_meta_key/get_offset/set_offset key the offset row
# purely on $bot_key, and cli/poller.pl's own @pairs construction sets
# bot_key to the token alone, with no chat_id folded in. So the same
# token declared under two DIFFERENT --chat_id groups produces the
# identical race, but the (chat_id, token)-keyed check lets it through
# silently since the two keys differ.

{
    eval {
        D2TG::Config::Flags::bot_groups(
            argv        => [ '--chat_id', '111', '--bot', 'shared-token', '--chat_id', '222', '--bot', 'shared-token' ],
            env_chat_id => undef,
            env_token   => undef,
        );
    };
    like(
        $@,
        qr/configured under two different chat_id groups/i,
        'bot_groups refuses when the same bot token is configured under two different chat_id groups'
    );
    like( $@, qr/111/, 'the message names the first chat_id' );
    like( $@, qr/222/, 'the message names the second chat_id' );
    unlike( $@, qr/shared-token\b/, 'the raw token is never shown unmasked in the refusal message' );
}

# Regression: TGT-202's own existing (chat_id, token) exact-duplicate
# case must still be caught, and by a message this new check doesn't
# swallow or change.
{
    eval {
        D2TG::Config::Flags::bot_groups(
            argv        => [ '--chat_id', '999', '--bot', 'dup-token' ],
            env_chat_id => '999',
            env_token   => 'dup-token',
        );
    };
    like( $@, qr/duplicate/i, "TGT-202's own exact (chat_id, token) duplicate case is still refused" );
}

# Regression: genuinely distinct multi-bot groups are unaffected.
{
    my ( $groups, @rest ) = D2TG::Config::Flags::bot_groups(
        argv        => [ '--chat_id', '1234', '--bot', 't1', '--chat_id', '4567', '--bot', 't3' ],
        env_chat_id => undef,
        env_token   => undef,
    );
    is( scalar @$groups, 2, 'distinct multi-bot groups (different chat_id, different token) are unaffected' );
}

# Regression: the same chat_id with two DIFFERENT bot tokens is still a
# legitimate multi-bot-on-one-chat setup, not a duplicate.
{
    my ( $groups, @rest ) = D2TG::Config::Flags::bot_groups(
        argv        => [ '--chat_id', '1234', '--bot', 't1', '--bot', 't2' ],
        env_chat_id => undef,
        env_token   => undef,
    );
    is( scalar @$groups, 1, 'one chat_id with two distinct tokens is still a single, valid group' );
    is_deeply( $groups->[0]{bots}, [ 't1', 't2' ], 'both distinct tokens kept' );
}

done_testing();
