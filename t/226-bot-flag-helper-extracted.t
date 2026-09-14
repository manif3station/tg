use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require D2TG::Config;

# TGT-226 (found via a scheduled JOB-004 improvement hunt): the masked
# "--bot <token>" flag fragment was built via an identical 3-line
# ternary duplicated verbatim in two places - _print_reply_template
# and the NEW TG MEDIA FAILED branch (added by TGT-220). This test
# exercises the new shared helper directly, matching this project's
# own established extract-once-duplicated precedent
# (_classify_store_error, open_store_or_die, _with_hard_timeout).

can_ok( 'D2TG::Poller', '_bot_flag' );

is( D2TG::Poller::_bot_flag(undef), '', 'no bot_token gives an empty flag fragment' );

my $token = '123456:ABC-DEF-token';
is(
    D2TG::Poller::_bot_flag($token),
    ' --bot ' . D2TG::Config::masked_token($token),
    'a defined bot_token gives a masked --bot flag fragment, matching D2TG::Config::masked_token exactly'
);

unlike( D2TG::Poller::_bot_flag($token), qr/\Q$token\E/, 'the raw token is never present in the returned fragment' );

done_testing();
