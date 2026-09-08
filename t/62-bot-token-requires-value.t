use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Config;
require D2TG::Reply;

# TGT-074: bot_groups's --bot branch and D2TG::Reply::extract_bot_flag
# both spliced/shifted the next token as the bot token with zero
# validation - same bug class as TGT-069/071/072's --chat_id/--db
# fixes, but for --bot. Live-reproduced: bot_groups(argv=>['--chat_id',
# '1234','--bot']) silently produced {chat_id=>1234, bots=>[undef]};
# extract_bot_flag('--bot','--db','myalias',...) silently returned
# token='--db'.

{
    eval {
        D2TG::Config::bot_groups(
            argv        => [ '--chat_id', '1234', '--bot' ],
            env_chat_id => undef,
            env_token   => undef,
        );
    };
    like( $@, qr/--bot requires a value/, 'a bare trailing --bot dies instead of silently pushing undef into bots' );
}

{
    eval {
        D2TG::Config::bot_groups(
            argv        => [ '--chat_id', '1234', '--bot', '--chat_id', '5678' ],
            env_chat_id => undef,
            env_token   => undef,
        );
    };
    like( $@, qr/--bot requires a value/, '--bot immediately followed by another flag dies instead of swallowing it as the token' );
}

{
    # Existing behavior unaffected: a well-formed --bot <token>.
    my ( $groups, @rest ) = D2TG::Config::bot_groups(
        argv        => [ '--chat_id', '1234', '--bot', 'realtoken' ],
        env_chat_id => undef,
        env_token   => undef,
    );
    is( $groups->[0]{bots}[0], 'realtoken', 'a well-formed --bot <token> is completely unaffected by the new validation' );
}

{
    eval { D2TG::Reply::extract_bot_flag( '--bot', '--db', 'myalias', '123', 'hello' ) };
    like( $@, qr/--bot requires a value/, "extract_bot_flag('--bot','--db',...) dies instead of silently swallowing --db as the token" );
}

{
    # Existing behavior unaffected: well-formed --bot <token>.
    my ( $bot_token, @rest ) = D2TG::Reply::extract_bot_flag( '--bot', 'xyz999', '4567', 'hello there' );
    is( $bot_token, 'xyz999', 'a well-formed --bot <token> is unaffected' );
    is_deeply( \@rest, [ '4567', 'hello there' ], 'remaining args unchanged' );
}

{
    # Existing behavior unaffected: --bot not given at all.
    my ( $bot_token, @rest ) = D2TG::Reply::extract_bot_flag( '4567', 'hello there' );
    is( $bot_token, undef, 'no --bot given at all - still undef, falls back to D2TG_TOKEN' );
    is_deeply( \@rest, [ '4567', 'hello there' ], 'args unchanged when --bot absent' );
}

done_testing();
