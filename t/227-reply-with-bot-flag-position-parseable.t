use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require D2TG::Reply;
require D2TG::Reply::Args;

# TGT-227 (found via a scheduled JOB-003 hourly bug hunt): the poller's
# own REPLY WITH template printed --bot AFTER chat_id/text - a position
# neither cli/reply.pl's own flag-parsing loop (leading-only) nor
# D2TG::Reply::Args::parse_cli_args (which only recognizes a trailing
# --reply-to-message-id, never --bot) ever consumes. A --bot flag in
# that position fell straight into the joined reply text and was sent
# to Telegram verbatim, while the actual send silently fell back to
# D2TG_TOKEN - the wrong bot in multi-bot mode. Worse, substituting the
# real token in place (per the module's own documented instruction)
# leaked the real credential into the sent message text.
#
# Fixed by printing --bot BEFORE chat_id, matching cli/reply.pl's own
# already-working leading-position parsing contract (the same
# convention cli/approve.pl/cli/retry-download.pl already use) - no
# parser changes needed.

sub capture_stdout {
    my ($code) = @_;
    my $out = '';
    open my $fh, '>', \$out or die $!;
    my $old = select $fh;
    $code->();
    select $old;
    close $fh;
    return $out;
}

{
    my $tg = Fake_Telegram_stub();
    my $store = Fake_Store_stub();

    my $real_token = '123456789:AArealTokenForThisTestxyz';
    my $out = capture_stdout(
        sub { D2TG::Poller::run_once( $tg, undef, $store, bot_token => $real_token ) } );

    # Extract the actual argv the printed REPLY WITH line would hand to
    # cli/reply.pl, substituting the real token in place of the masked
    # one (as the module's own docs instruct an operator to do).
    my ($printed) = $out =~ /REPLY WITH: d2 tg\.reply (.*)$/m;
    ok( $printed, 'a REPLY WITH line was printed' ) or diag($out);

    require D2TG::Config;
    my $masked = D2TG::Config::masked_token($real_token);
    ( my $substituted = $printed ) =~ s/\Q$masked\E/$real_token/;

    # Simulate cli/reply.pl's own argv split (shellwords-like: quoted
    # "..." becomes one token) well enough to exercise the real parsing
    # functions this ticket's fix touches.
    my @argv = _split_like_shell($substituted);

    my ( $bot_token, @rest ) = D2TG::Reply::Args::extract_bot_flag(@argv);
    is( $bot_token, $real_token, 'the real bot token is correctly extracted as a flag, not swallowed into text' );

    my ( $chat_id, $text, $reply_to_message_id ) = D2TG::Reply::Args::parse_cli_args(@rest);
    is( $chat_id, 4567, 'chat_id parses correctly' );
    is( $reply_to_message_id, 42, 'reply_to_message_id parses correctly' );
    unlike( $text, qr/--bot/, 'no --bot flag material leaks into the reply text' );
    unlike( $text, qr/\Q$real_token\E/, 'the real token never leaks into the reply text' );
}

sub Fake_Telegram_stub {
    require Fake::Telegram;
    return Fake::Telegram->new(
        [
            {
                update_id => 700,
                message   => {
                    message_id => 42,
                    chat       => { id => 4567 },
                    from       => { username => 'bob' },
                    text       => 'hi',
                },
            },
        ],
    );
}

sub Fake_Store_stub {
    require Fake::Store;
    return Fake::Store->new( allowed => [4567] );
}

sub _split_like_shell {
    my ($line) = @_;
    my @tokens;
    while ( $line =~ /\G\s*(?:"([^"]*)"|(\S+))/gc ) {
        push @tokens, defined $1 ? $1 : $2;
    }
    return @tokens;
}

done_testing();
