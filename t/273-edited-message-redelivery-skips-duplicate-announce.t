use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;
require Fake::Store;

# TGT-273 (found via a scheduled JOB-004 improvement hunt): TGT-270
# (this same session) hardened run_once's plain-message/media/voice
# branch against a Telegram redelivery of an already-processed update,
# but the edited_message branch has no equivalent guard at all - it
# unconditionally prints NEW TG EDIT every time it's reached, with no
# check against whether this exact edit was already announced on a
# prior cycle.
#
# Design note: naively reusing D2TG::Store::get_message the way
# TGT-270 did for the plain-message branch does NOT work here -
# record_message UPSERTs on (chat_id, bot_key, message_id), so
# get_message returns non-null for ANY message ever recorded,
# including the ORIGINAL pre-edit send. The fix instead compares the
# incoming (sanitized) edited text against the already-stored summary:
# identical means this exact edit was already recorded (a redelivery);
# different means a genuinely new edit (or the very first edit).

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
    # Redelivery: the store already has this exact edited text
    # recorded (a prior cycle already announced and recorded it).
    my $tg = Fake::Telegram->new(
        [
            {
                update_id      => 3000,
                edited_message => {
                    message_id => 500,
                    date       => 1_700_000_000,
                    chat       => { id => 777 },
                    from       => { username => 'ada' },
                    text       => 'corrected text',
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [777] );
    $store->record_message( 777, 500, 'ada', 'corrected text' );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    unlike( $out, qr/NEW TG EDIT/, 'a redelivered edit whose text already matches the stored summary is not re-announced' );
}

{
    # Genuinely new edit: the store has the ORIGINAL pre-edit text, not
    # this edit's text - must still announce and record normally.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id      => 3001,
                edited_message => {
                    message_id => 501,
                    date       => 1_700_000_000,
                    chat       => { id => 888 },
                    from       => { username => 'ada' },
                    text       => 'the actually new edited text',
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [888] );
    $store->record_message( 888, 501, 'ada', 'the original message' );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $out, qr/NEW TG EDIT \[888\] ada: the actually new edited text \(msg #501, edited\)/,
        'a genuinely new edit (differs from the stored summary) still announces normally' );
    is( $store->get_message( 888, 501 )->{summary}, 'the actually new edited text', 'the new edit is still recorded' );
}

{
    # First-ever edit: no prior row at all - must still announce and
    # record normally (get_message returns undef, not a match).
    my $tg = Fake::Telegram->new(
        [
            {
                update_id      => 3002,
                edited_message => {
                    message_id => 502,
                    date       => 1_700_000_000,
                    chat       => { id => 999 },
                    from       => { username => 'ada' },
                    text       => 'first edit ever seen',
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $out, qr/NEW TG EDIT \[999\] ada: first edit ever seen \(msg #502, edited\)/,
        'an edit with no prior stored row (undef get_message) still announces normally' );
}

done_testing();
