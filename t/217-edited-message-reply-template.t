use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;
require Fake::Store;

# TGT-217 (found via a scheduled JOB-003 hourly bug hunt): every other
# actionable inbound-message branch in D2TG::Poller::run_once
# (message/media/voice/document/photo) calls D2TG::Poller::Format::print_reply_template
# right after its own NEW TG ... line, printing the REPLY WITH: d2
# tg.reply ... template the whole bridge-notification architecture
# depends on (tg-skill-design.md's Q-004 decision). The edited_message
# branch (TGT-169) was the sole actionable branch missing this call -
# an edited message got announced but left the monitoring agent with
# no ready-to-run reply command, unlike every other event type.

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
    # A text edit must get a REPLY WITH line, same as an ordinary message.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id      => 2000,
                edited_message => {
                    message_id => 88,
                    date       => 1_700_000_000,
                    chat       => { id => 444 },
                    from       => { username => 'ada' },
                    text       => 'corrected text',
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [444] );
    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $out, qr/NEW TG EDIT \[444\] ada: corrected text \(msg #88, edited\)/,
        'a text edit still prints its NEW TG EDIT line' );
    like( $out, qr/REPLY WITH: d2 tg\.reply 444 "\.\.\." --reply-to-message-id 88/,
        'a text edit ALSO prints a REPLY WITH template, matching every other actionable branch' );
}

{
    # A caption/media-only edit (no text) must ALSO get a REPLY WITH
    # line - only the store recording is skipped for this case, not
    # the reply-template announcement.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id      => 2002,
                edited_message => {
                    message_id => 99,
                    date       => 1_700_000_000,
                    chat       => { id => 666 },
                    from       => { username => 'carl' },

                    # No 'text' field at all - a caption/media-only edit.
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [666] );
    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $out, qr/NEW TG EDIT \[666\] carl: \(no text\) \(msg #99, edited\)/,
        'a caption/media-only edit still prints its NEW TG EDIT line' );
    like( $out, qr/REPLY WITH: d2 tg\.reply 666 "\.\.\." --reply-to-message-id 99/,
        'a caption/media-only edit ALSO prints a REPLY WITH template' );
}

done_testing();
