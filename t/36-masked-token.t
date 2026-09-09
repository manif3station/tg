use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Config;

is( D2TG::Config::masked_token('123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA'),
    '1234...AAAA', 'a normal-length token is masked to its first 4 and last 4 characters' );

isnt( D2TG::Config::masked_token('short'), 'short', 'a token too short to usefully mask (< 8 chars) is never returned raw (TGT-138)' );
is( D2TG::Config::masked_token('short'), '(short token, not shown)', 'a too-short token gets a fixed, non-revealing placeholder instead' );

# TGT-138, Codex review finding: at exactly 8 characters, "first 4 and
# last 4" is the whole string - substr(...,0,4).'...'.substr(...,-4)
# would show every character, not mask them.
is( D2TG::Config::masked_token('12345678'), '(short token, not shown)',
    'an exactly-8-character token is also placeholdered, not shown as first4...last4 (which would be the whole string)' );

is( D2TG::Config::masked_token(undef), '(not set)', 'an undef token (D2TG_TOKEN unset) is reported clearly, not crashed on' );

is( D2TG::Config::masked_token(''), '(not set)', 'an empty-string token is treated the same as unset' );

done_testing();
