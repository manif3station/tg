package D2TG::Reply::Args;

use strict;
use warnings;
use D2TG::Config;
use D2TG::Config::Flags;
use Encode qw(decode);

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

    my $bot_token;
    if ( @args >= 1 && $args[0] eq '--bot' ) {
        shift @args;
        $bot_token = D2TG::Config::Flags::shift_flag_value( \@args, '--bot' );
    }

    return ( $bot_token, @args );
}

sub extract_bot_flag_or_die {
    my (@args) = @_;

    my ( $bot_token, @rest ) = eval { extract_bot_flag(@args) };
    if ($@) {
        print STDERR $@;
        exit 1;
    }

    return ( $bot_token, @rest );
}

sub parse_cli_args {
    my (@args) = @_;

    @args = map { decode( 'UTF-8', $_ ) } @args;

    my $reply_to_message_id;
    if ( @args >= 2 && $args[-2] eq '--reply-to-message-id' ) {
        ( undef, $reply_to_message_id ) = splice( @args, -2 );
    }

    my $chat_id = shift @args;
    my $text    = join( ' ', @args );

    return ( $chat_id, $text, $reply_to_message_id );
}

1;
