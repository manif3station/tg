use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Reply;
require D2TG::Reply::Args;

# TGT-264 (found via a scheduled JOB-003 hourly bug hunt): TGT-074 made
# extract_bot_flag die "--bot requires a value" for a trailing bare
# --bot (with other args already present) or --bot immediately
# followed by another flag - but its guard is
# "if (@args >= 2 && $args[0] eq '--bot')", so when --bot is the ONLY
# argument (array length exactly 1), the guard is false and the
# function silently falls through to returning (undef, '--bot')
# instead of dying at all. Live-reproduced: extract_bot_flag('--bot')
# returned (undef, '--bot') rather than dying.

{
    eval { D2TG::Reply::Args::extract_bot_flag('--bot') };
    like( $@, qr/--bot requires a value/, 'a sole bare --bot argument dies instead of silently returning it as a leftover positional arg' );
}

{
    # Existing behavior unaffected: well-formed --bot <token>, still the only two args.
    my ( $bot_token, @rest ) = D2TG::Reply::Args::extract_bot_flag( '--bot', 'xyz999' );
    is( $bot_token, 'xyz999', 'a well-formed --bot <token> as the only two args is unaffected' );
    is_deeply( \@rest, [], 'no leftover args' );
}

done_testing();
