use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;

package main;

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
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 60,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, text => 'hello there' },
            },
        ],
    );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef ) } );

    unlike( $out, qr/replying to/, 'a fresh message (no reply_to_message) gets no reply-context suffix' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 61,
                message   => {
                    chat    => { id => 999 },
                    from    => { username => 'ada' },
                    text    => 'yes I can',
                    reply_to_message => {
                        from => { username => 'bob' },
                        text => 'can you hear me?',
                    },
                },
            },
        ],
    );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef ) } );

    like( $out, qr/NEW TG \[999\] ada: yes I can/, 'the main content line is unchanged' );
    like( $out, qr/replying to bob: can you hear me\?/, 'the suffix names the original sender and text' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 62,
                message   => {
                    chat    => { id => 999 },
                    from    => { username => 'ada' },
                    text    => 'nice one',
                    reply_to_message => {
                        from  => { username => 'bob' },
                        photo => [ { file_id => 'p1' } ],
                    },
                },
            },
        ],
    );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef ) } );

    like( $out, qr/replying to bob: photo/, 'a reply to a textless (media) message names the media kind instead' );
}

done_testing();
