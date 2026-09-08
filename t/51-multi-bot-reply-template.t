use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require D2TG::Reply;
require D2TG::Telegram;
require Fake::Telegram;
require Fake::Store;

is( D2TG::Telegram->new( token => 'sometoken123' )->token, 'sometoken123',
    'D2TG::Telegram->token returns the constructing token' );

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

# --- multi-bot mode: REPLY WITH names the bot that received the message,
# --- but only its masked form (TGT-086 - the real token must never
# --- reach the target project's tira.policy.bridge, which is a shared
# --- board, not a private log) ---
{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 600,
                message   => {
                    message_id => 42,
                    chat       => { id => 4567 },
                    from       => { username => 'bob' },
                    text       => 'hi',
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [4567] );

    my $real_token = '123456789:AAHrealSecretBotTokenLooksLikeThisxyz';
    my $out        = capture_stdout(
        sub { D2TG::Poller::run_once( $tg, undef, $store, bot_token => $real_token ) } );

    like(
        $out,
        qr/REPLY WITH: d2 tg\.reply 4567 "\.\.\." --bot 1234\.\.\.sxyz --reply-to-message-id 42/,
        'multi-bot REPLY WITH names the receiving bot by its masked token (TGT-086)'
    );
    unlike( $out, qr/\Q$real_token\E/, 'the real, full bot token never appears in stdout (TGT-086)' );
}

# --- single-bot mode (no bot_token given): REPLY WITH is unchanged ---
{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 601,
                message   => {
                    message_id => 43,
                    chat       => { id => 999 },
                    from       => { username => 'ada' },
                    text       => 'hi',
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like(
        $out,
        qr/REPLY WITH: d2 tg\.reply 999 "\.\.\." --reply-to-message-id 43\n/,
        'single-bot REPLY WITH is unchanged - no --bot'
    );
    unlike( $out, qr/--bot/, 'no --bot flag at all in single-bot mode' );
}

# --- cli/reply's leading --bot flag is extracted ---
{
    my @argv = ( '--bot', 'xyz999', '4567', 'hello there' );
    my ( $bot_token, @rest ) = D2TG::Reply::extract_bot_flag(@argv);
    is( $bot_token, 'xyz999', '--bot value extracted' );
    is_deeply( \@rest, [ '4567', 'hello there' ], 'remaining args unchanged' );
}

{
    my @argv = ( '4567', 'hello there' );
    my ( $bot_token, @rest ) = D2TG::Reply::extract_bot_flag(@argv);
    is( $bot_token, undef, 'no --bot given - undef, falls back to D2TG_TOKEN' );
    is_deeply( \@rest, [ '4567', 'hello there' ], 'args unchanged when --bot absent' );
}

done_testing();
