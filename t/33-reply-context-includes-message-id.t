use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;
require Fake::Store;

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
                update_id => 600,
                message   => {
                    message_id => 81,
                    chat       => { id => 999 },
                    from       => { username => 'mic3216' },
                    text       => 'here',
                    reply_to_message => {
                        message_id => 80,
                        from       => { username => 'mic3216' },
                        document   => { file_id => 'd1' },
                    },
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like(
        $out,
        qr{replying to mic3216 \[msg #80\]: document},
        'the reply-context suffix names the original message\'s own message_id'
    );
}

{
    # No message_id on the original (edge case, e.g. a malformed/older payload) -> suffix still works, just without the bracket.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 601,
                message   => {
                    message_id => 82,
                    chat       => { id => 999 },
                    from       => { username => 'mic3216' },
                    text       => 'still here',
                    reply_to_message => {
                        from => { username => 'bob' },
                        text => 'no id on this one',
                    },
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $out, qr{replying to bob: no id on this one}, 'without an original message_id, the suffix is unchanged (no bracket)' );
    unlike( $out, qr{\[msg #\]}, 'no empty bracket is ever printed' );
}

done_testing();
