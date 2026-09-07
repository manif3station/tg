use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Reply;

{
    my ( $chat_id, $text, $reply_to_message_id ) =
      D2TG::Reply::parse_cli_args( 'you', 'can', 'pass', '--reply-to-message-id', '55', 'to', 'thread', 'it' );

    is( $chat_id, 'you', 'first arg is always chat_id, whatever it looks like' );
    is( $text, 'can pass --reply-to-message-id 55 to thread it', 'a --reply-to-message-id token NOT in trailing position is left as ordinary text, unmodified (TGT-042)' );
    is( $reply_to_message_id, undef, 'no reply_to_message_id is extracted when the flag is not trailing' );
}

{
    my ( $chat_id, $text, $reply_to_message_id ) =
      D2TG::Reply::parse_cli_args( '123456', 'hello', 'there', '--reply-to-message-id', '80' );

    is( $chat_id, '123456', 'chat_id parsed' );
    is( $text, 'hello there', 'text excludes the trailing flag and its value' );
    is( $reply_to_message_id, '80', 'reply_to_message_id recognized when trailing (the REPLY WITH template\'s own usage)' );
}

{
    my ( $chat_id, $text, $reply_to_message_id ) =
      D2TG::Reply::parse_cli_args( '123456', 'hello', 'there' );

    is( $chat_id, '123456', 'chat_id parsed' );
    is( $text, 'hello there', 'text unchanged when no flag is given at all' );
    is( $reply_to_message_id, undef, 'no reply_to_message_id when omitted (unchanged behavior)' );
}

done_testing();
