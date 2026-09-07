use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Config;

is( D2TG::Config::masked_token('123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA'),
    '1234...AAAA', 'a normal-length token is masked to its first 4 and last 4 characters' );

is( D2TG::Config::masked_token('short'), 'short', 'a token too short to usefully mask (< 8 chars) is returned as-is, not crashed on' );

is( D2TG::Config::masked_token(undef), '(not set)', 'an undef token (D2TG_TOKEN unset) is reported clearly, not crashed on' );

is( D2TG::Config::masked_token(''), '(not set)', 'an empty-string token is treated the same as unset' );

done_testing();
