package D2TG::Reply::Args;

use strict;
use warnings;
use D2TG::Config;
use D2TG::Config::Flags;
use D2TG::OrDie;
use Encode qw(decode);

# TGT-322 (found via the same JOB-004 improvement-hunt discipline that
# spotted its own fresh diff right after landing, per this project's
# "found it twice, extract it" convention): extract_bot_flag's own
# leading-flag-with-value shape - shift the flag token off if it's
# first, then shift_flag_value the following value - is now duplicated
# by parse_cli_args's own --reply-to-message-id handling below.
# Collapsed into this one helper, parameterized by the flag's own name.
sub _extract_leading_flag_value {
    my ( $args, $flag ) = @_;

    return undef unless @$args >= 1 && $args->[0] eq $flag;
    shift @$args;
    return D2TG::Config::Flags::shift_flag_value( $args, $flag );
}

# TGT-265: extract_bot_flag/extract_bot_flag_or_die/parse_cli_args
# were an organizational mismatch in D2TG::Reply.pm - CLI argv-parsing
# is a distinct concern from send_reply/resend_voice's network/
# store-write concern, and extract_bot_flag_or_die is already called
# by 8 cli/*.pl scripts beyond reply.pl, so it isn't really
# reply-specific logic either. Extracted here, mirroring
# D2TG::Store::RetryQueue/D2TG::Config::Paths's own precedent. Full
# documentation lives in D2TG/Reply/Args.pod (REQ-028: POD in a
# separate file).
sub extract_bot_flag {
    my (@args) = @_;

    my $bot_token = _extract_leading_flag_value( \@args, '--bot' );

    return ( $bot_token, @args );
}

# TGT-269: this eval/print-STDERR/exit(1) wrapper was found duplicated
# a further 3 times across other modules - now a one-line forwarder
# onto the shared D2TG::OrDie::or_die helper.
sub extract_bot_flag_or_die {
    my (@args) = @_;
    return D2TG::OrDie::or_die( \&extract_bot_flag, @args );
}

# TGT-322 (found via a live JOB-003 hourly bug hunt): --reply-to-message-id
# used to be recognized only in the TRAILING position (TGT-040/042) -
# deliberately, to avoid the whole-list-scan ambiguity a leading-only
# --bot/--db/--voice-only never has. But trailing-only still left a real
# gap: a reply message that legitimately ENDS with the literal words
# "--reply-to-message-id <word>" (e.g. a question about the flag itself)
# was silently corrupted - the trailing two args were stripped and
# misread as the flag, discarding the operator's real message. Live-
# reproduced: parse_cli_args('12345','how','do','I','use',
# '--reply-to-message-id','5') returned text truncated to 'how do I use'
# and a fabricated reply_to_message_id of '5'. Raised as Q-019 (a
# breaking CLI-contract change to a deliberately-reasoned prior design
# is a real tradeoff, not a unilateral call) - Michael chose the
# structural fix: recognized only in the LEADING position instead,
# matching TGT-227's own --bot precedent (a leading flag never scans
# into the free-text region at all, so it can never collide with
# ordinary reply text no matter what that text contains). The return
# signature is unchanged - only the recognized position moved.
sub parse_cli_args {
    my (@args) = @_;

    @args = map { decode( 'UTF-8', $_ ) } @args;

    my $reply_to_message_id = _extract_leading_flag_value( \@args, '--reply-to-message-id' );

    my $chat_id = shift @args;
    my $text    = join( ' ', @args );

    return ( $chat_id, $text, $reply_to_message_id );
}

1;
