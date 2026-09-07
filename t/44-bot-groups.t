use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Config;

{
    my ( $groups, @rest ) = D2TG::Config::bot_groups(
        argv         => [],
        env_chat_id  => '7890',
        env_token    => 'tok6',
    );

    is( scalar @$groups, 1, 'env-only usage (no CLI args) produces exactly one group' );
    is( $groups->[0]{chat_id}, '7890', 'the single group uses the env chat_id' );
    is_deeply( $groups->[0]{bots}, ['tok6'], 'the single group has exactly the env token, matching today\'s single-bot behavior' );
    is_deeply( \@rest, [], 'no leftover args' );
}

{
    my ( $groups, @rest ) = D2TG::Config::bot_groups(
        argv        => [ '--chat_id', '1234', '--bot', 't1', '--bot', 't2', '--chat_id', '4567', '--bot', 't3' ],
        env_chat_id => undef,
        env_token   => undef,
    );

    is( scalar @$groups, 2, 'two --chat_id groups produce two groups' );
    is( $groups->[0]{chat_id}, '1234', 'first group chat_id' );
    is_deeply( $groups->[0]{bots}, [ 't1', 't2' ], 'first group gets both bots declared before the next --chat_id' );
    is( $groups->[1]{chat_id}, '4567', 'second group chat_id' );
    is_deeply( $groups->[1]{bots}, ['t3'], 'second group gets its own bot' );
}

{
    my ( $groups, @rest ) = D2TG::Config::bot_groups(
        argv        => [ '--chat_id', '1234', '--bot', 't1', '--bot', 't2', '--chat_id', '4567', '--bot', 't3' ],
        env_chat_id => undef,
        env_token   => 'tok6',
    );

    is( scalar @$groups, 2, 'env token alone (no env chat_id) does not create a new group' );
    is_deeply( $groups->[1]{bots}, [ 't3', 'tok6' ], 'env token alone attaches to the LAST CLI-declared group' );
    is_deeply( $groups->[0]{bots}, [ 't1', 't2' ], 'the first group is unaffected' );
}

{
    my ( $groups, @rest ) = D2TG::Config::bot_groups(
        argv        => [ '--chat_id', '1234', '--bot', 't1', '--bot', 't2', '--chat_id', '4567', '--bot', 't3' ],
        env_chat_id => '7890',
        env_token   => 'tok6',
    );

    is( scalar @$groups, 3, 'both env vars set together form their own new, separate group' );
    is( $groups->[2]{chat_id}, '7890', 'the new group uses the env chat_id' );
    is_deeply( $groups->[2]{bots}, ['tok6'], 'the new group has exactly the env token' );
    is_deeply( $groups->[1]{bots}, ['t3'], 'the original last group (4567) is unaffected - env token did NOT also attach there' );
}

{
    my ( $groups, @rest ) = D2TG::Config::bot_groups(
        argv        => [ 'stray1', '--chat_id', '1234', '--bot', 't1', 'stray2' ],
        env_chat_id => undef,
        env_token   => undef,
    );

    is_deeply( \@rest, [ 'stray1', 'stray2' ], 'unrecognized args are preserved in order, not consumed' );
}

{
    eval {
        D2TG::Config::bot_groups(
            argv        => [ '--bot', 't1' ],
            env_chat_id => undef,
            env_token   => undef,
        );
    };
    like( $@, qr/--bot given before any --chat_id/, '--bot with no preceding --chat_id (CLI or env) dies with a clear message' );
}

done_testing();
