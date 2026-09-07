use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require D2TG::Store;
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

sub new_store {
    my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    return D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 );
}

{
    # A prior document message this skill already processed and stored.
    my $store = new_store();
    $store->record_message( 999, 100, 'bob', 'document /tmp/media/report.pdf' );

    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 70,
                message   => {
                    message_id => 101,
                    chat       => { id => 999 },
                    from       => { username => 'ada' },
                    text       => 'here',
                    reply_to_message => {
                        message_id => 100,
                        from       => { username => 'bob' },
                        document   => { file_id => 'd1' },
                    },
                },
            },
        ],
    );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like(
        $out,
        qr{replying to bob: document /tmp/media/report\.pdf},
        'reply to a stored document message shows the stored local_path, not just "document"'
    );
}

{
    # A prior voice message this skill already transcribed and stored.
    my $store = new_store();
    $store->record_message( 999, 200, 'bob', 'call me back at five' );

    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 71,
                message   => {
                    message_id => 201,
                    chat       => { id => 999 },
                    from       => { username => 'ada' },
                    text       => 'ok will do',
                    reply_to_message => {
                        message_id => 200,
                        from       => { username => 'bob' },
                        voice      => { file_id => 'v1' },
                    },
                },
            },
        ],
    );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like(
        $out,
        qr{replying to bob: call me back at five},
        'reply to a stored voice message shows the stored transcript, not just "voice"'
    );
}

{
    # No stored record at all (predates this feature, or message_id unknown) -> unchanged fallback.
    my $store = new_store();

    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 72,
                message   => {
                    message_id => 301,
                    chat       => { id => 999 },
                    from       => { username => 'ada' },
                    text       => 'nice one',
                    reply_to_message => {
                        message_id => 300,
                        from       => { username => 'bob' },
                        photo      => [ { file_id => 'p1' } ],
                    },
                },
            },
        ],
    );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like(
        $out,
        qr{replying to bob: photo\)},
        'reply to a message with no stored record falls back to the Telegram-payload media-kind behavior unchanged'
    );
}

done_testing();
