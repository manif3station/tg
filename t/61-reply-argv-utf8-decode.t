use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use JSON::PP qw(encode_json);

require D2TG::Reply;
require D2TG::Telegram;

# TGT-073: cli/reply mojibakes non-ASCII reply text. @ARGV is always raw
# bytes - Perl never decodes it as UTF-8 on its own. D2TG::Reply::parse_cli_args
# must decode its arguments as UTF-8 before composing $text, otherwise the
# raw bytes reach JSON::PP::encode_json and get double-encoded (the
# classic Perl Unicode footgun: an un-decoded byte string is treated as
# Latin-1 codepoints and re-encoded as UTF-8).

{
    # Raw UTF-8 bytes for "héllo" (0xC3 0xA9 for the é), exactly what
    # unfiltered @ARGV gives on a real invocation with non-ASCII text -
    # NOT a Perl \x{...} literal, which would already carry the utf8 flag.
    my $raw_bytes = "h\xc3\xa9llo";

    my ( $chat_id, $text, $reply_to_message_id ) = D2TG::Reply::parse_cli_args( '123456', $raw_bytes );

    is( $chat_id, '123456', 'chat_id is unaffected by the UTF-8 decoding' );
    is( ord( substr( $text, 1, 1 ) ), 0xe9, 'the byte-pair 0xc3 0xa9 decodes to a single U+00E9 codepoint, not two separate bytes' );

    my $json = encode_json( { text => $text } );
    is( $json, qq({"text":"h\xc3\xa9llo"}), 'the decoded text round-trips through encode_json as correctly UTF-8-encoded bytes, not double-encoded mojibake' );
}

{
    # Regression: plain ASCII text is completely unaffected.
    my ( $chat_id, $text, $reply_to_message_id ) = D2TG::Reply::parse_cli_args( '123456', 'hello', 'there' );
    is( $text, 'hello there', 'plain ASCII text is unchanged by the UTF-8 decoding' );
}

done_testing();
