use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use utf8;

require D2TG::Telegram;

{
    my @chunks = D2TG::Telegram::split_text_utf16( 'hello', 4000 );
    is_deeply( \@chunks, ['hello'], 'short text is returned as a single chunk' );
}

{
    my $text = 'x' x 10;
    my @chunks = D2TG::Telegram::split_text_utf16( $text, 4 );
    is( scalar @chunks, 3, 'text longer than the limit is split into ceil(10/4) chunks' );
    is( join( '', @chunks ), $text, 'rejoining the chunks reproduces the original text exactly' );
    ok( ( length $chunks[0] <= 4 && length $chunks[1] <= 4 ), 'no chunk exceeds the given limit' );
}

{
    # U+1F600 (a supplementary-plane emoji) costs 2 UTF-16 units on its own.
    my $emoji = "\x{1F600}";
    my $text  = $emoji . 'a';
    my @chunks = D2TG::Telegram::split_text_utf16( $text, 2 );

    is( scalar @chunks, 2, 'a 2-unit emoji plus a 1-unit char at limit=2 splits into two chunks' );
    is( $chunks[0], $emoji, 'the emoji is never split across chunks' );
    is( $chunks[1], 'a', 'the trailing character forms its own chunk' );
    is( join( '', @chunks ), $text, 'rejoining reproduces the original text with the emoji intact' );
}

{
    my @chunks = D2TG::Telegram::split_text_utf16( '', 4000 );
    is_deeply( \@chunks, [], 'empty text produces no chunks' );
}

done_testing();
