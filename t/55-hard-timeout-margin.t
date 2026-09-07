use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Telegram;

# TGT-066: live incident - D2TG::Telegram::DEFAULT_HARD_TIMEOUT (35s) left
# only a 5s margin over get_updates' own 30s long-poll wait, so a
# perfectly legitimate long-poll response (30s server-side wait + normal
# network/TLS/transmission overhead) could exceed 35s and be mistaken for
# a genuinely stuck connection. The margin must be wide enough to absorb
# real-world overhead while still catching a truly hung connection.

my $long_poll_wait = 30;    # D2TG::Telegram::get_updates' own request

ok( D2TG::Telegram::DEFAULT_HARD_TIMEOUT() - $long_poll_wait >= 15,
    'DEFAULT_HARD_TIMEOUT leaves at least a 15s margin over the 30s long-poll wait ('
      . D2TG::Telegram::DEFAULT_HARD_TIMEOUT() . 's hard timeout)' );

{
    # The real production path never reaches DEFAULT_HARD_TIMEOUT at all
    # under normal operation - new()'s own LWP::UserAgent already has a
    # configured ->timeout, which _call checks first. Both must share the
    # exact same value, or widening one without the other silently
    # reintroduces the same too-tight-margin bug from the other side.
    my $tg = D2TG::Telegram->new( token => 'test-token' );
    is( $tg->{ua}->timeout, D2TG::Telegram::DEFAULT_HARD_TIMEOUT(),
        "the real production LWP::UserAgent's own timeout matches DEFAULT_HARD_TIMEOUT exactly - the two can never silently drift apart" );
}

done_testing();
