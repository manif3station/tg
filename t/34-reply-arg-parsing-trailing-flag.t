use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Reply;
require D2TG::Reply::Args;

# Historical note: this file's own name says "trailing-flag" because
# --reply-to-message-id was originally recognized only in the trailing
# position (TGT-040/042). TGT-322 (found via a live JOB-003 hourly bug
# hunt) found that trailing-only still left a real gap - a reply message
# legitimately ENDING with the literal words "--reply-to-message-id
# <word>" was silently corrupted - and moved recognition to the LEADING
# position instead (matching TGT-227's own --bot precedent), which
# structurally eliminates the ambiguity rather than merely narrowing it.
# These tests now assert the leading-only contract.

{
    my ( $chat_id, $text, $reply_to_message_id ) =
      D2TG::Reply::Args::parse_cli_args( 'you', 'can', 'pass', '--reply-to-message-id', '55', 'to', 'thread', 'it' );

    is( $chat_id, 'you', 'first arg is always chat_id, whatever it looks like' );
    is( $text, 'can pass --reply-to-message-id 55 to thread it', 'a --reply-to-message-id token NOT in leading position is left as ordinary text, unmodified (TGT-322)' );
    is( $reply_to_message_id, undef, 'no reply_to_message_id is extracted when the flag is not leading' );
}

{
    my ( $chat_id, $text, $reply_to_message_id ) =
      D2TG::Reply::Args::parse_cli_args( '--reply-to-message-id', '80', '123456', 'hello', 'there' );

    is( $chat_id, '123456', 'chat_id parsed after the leading flag+value' );
    is( $text, 'hello there', 'text excludes the leading flag and its value' );
    is( $reply_to_message_id, '80', 'reply_to_message_id recognized when leading (the REPLY WITH template\'s own usage, TGT-322)' );
}

{
    my ( $chat_id, $text, $reply_to_message_id ) =
      D2TG::Reply::Args::parse_cli_args( '123456', 'hello', 'there' );

    is( $chat_id, '123456', 'chat_id parsed' );
    is( $text, 'hello there', 'text unchanged when no flag is given at all' );
    is( $reply_to_message_id, undef, 'no reply_to_message_id when omitted (unchanged behavior)' );
}

{
    # TGT-322's own headline case: a message that legitimately ENDS with
    # the exact two tokens the flag used to collide with must now be
    # left completely alone, in the trailing position - the whole point
    # of moving recognition to leading-only.
    my ( $chat_id, $text, $reply_to_message_id ) =
      D2TG::Reply::Args::parse_cli_args( '12345', 'how', 'do', 'I', 'use', '--reply-to-message-id', '5' );

    is( $chat_id, '12345', 'chat_id parsed' );
    is( $text, 'how do I use --reply-to-message-id 5', 'a message ending in the exact former-collision words is now preserved verbatim (TGT-322)' );
    is( $reply_to_message_id, undef, 'no reply_to_message_id is fabricated from trailing message content' );
}

{
    # A leading --reply-to-message-id with no value at all, or
    # immediately followed by another flag-like token, now dies loudly
    # (matching --bot/--db's own existing convention) instead of the old
    # trailing-only code's silent fall-through into ordinary text.
    my $ok = eval { D2TG::Reply::Args::parse_cli_args('--reply-to-message-id'); 1 };
    ok( !$ok, 'a bare leading --reply-to-message-id with no value dies' );
    like( $@, qr/--reply-to-message-id requires a value/, 'dies with the expected message' );
}

{
    # TGT-322's own fresh diff duplicated extract_bot_flag's leading-
    # flag-with-value shape - extracted into a shared
    # _extract_leading_flag_value helper in the same ticket, per this
    # project's "found it twice, extract it" convention. Structural
    # check, not a new-behavior test.
    ok( D2TG::Reply::Args->can('_extract_leading_flag_value'),
        'D2TG::Reply::Args::_extract_leading_flag_value exists - the shared helper collapsing extract_bot_flag and parse_cli_args\'s own leading-flag parsing' );
}

done_testing();
