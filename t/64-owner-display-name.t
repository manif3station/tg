use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;

# TGT-079: live user request - when a message's chat_id matches the
# configured owner chat id (D2TG_CHAT_ID), print D2TG_OWNER's value
# instead of the raw Telegram username, falling back to the username
# when D2TG_OWNER isn't set or the sender isn't the owner.

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
    local $ENV{D2TG_CHAT_ID} = '398296603';
    local $ENV{D2TG_OWNER}   = 'Michael';

    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 1,
                message   => { chat => { id => 398296603 }, from => { username => 'mic3216' }, text => 'again' },
            },
        ],
    );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef ) } );

    like( $out, qr/Michael/, 'owner chat id + D2TG_OWNER set: shows the configured owner name' );
    unlike( $out, qr/mic3216/, 'the raw Telegram username is not shown when D2TG_OWNER applies' );
}

{
    local $ENV{D2TG_CHAT_ID} = '398296603';
    local $ENV{D2TG_OWNER};

    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 1,
                message   => { chat => { id => 398296603 }, from => { username => 'mic3216' }, text => 'again' },
            },
        ],
    );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef ) } );

    like( $out, qr/mic3216/, 'owner chat id + D2TG_OWNER unset: falls back to the Telegram username unchanged' );
}

{
    local $ENV{D2TG_CHAT_ID} = '398296603';
    local $ENV{D2TG_OWNER}   = 'Michael';

    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 1,
                message   => { chat => { id => 999999 }, from => { username => 'ada' }, text => 'hi' },
            },
        ],
    );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef ) } );

    like( $out, qr/ada/, 'a non-owner chat id always shows the Telegram username, regardless of D2TG_OWNER' );
    unlike( $out, qr/Michael/, 'D2TG_OWNER never leaks onto a non-owner sender line' );
}

{
    # Reply-context suffix also uses the display-name substitution for
    # the original message's sender.
    local $ENV{D2TG_CHAT_ID} = '398296603';
    local $ENV{D2TG_OWNER}   = 'Michael';

    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 1,
                message   => {
                    chat             => { id => 398296603 },
                    from             => { username => 'mic3216' },
                    text             => 'again',
                    reply_to_message => {
                        message_id => 5,
                        from       => { username => 'mic3216' },
                        text       => 'hi',
                    },
                },
            },
        ],
    );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef ) } );

    like( $out, qr/replying to Michael/, 'the reply-context suffix also shows the owner display name' );
}

done_testing();
