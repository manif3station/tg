use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use File::Temp qw(tempfile);

require D2TG::Poller;
require D2TG::Store;
use Fake::Telegram;

# TGT-151 (JOB-003 scheduled hourly bug hunt finding, 2026-09-09): TGT-143
# added message_reaction handling to run_once entirely before the
# is_allowed access-control gate that guards every other inbound event -
# an unapproved chat_id's reaction was printed unconditionally, leaking
# its chat_id/username onto the monitored stream and letting an
# unapproved party interact with the bot in a way every other inbound
# path in this codebase explicitly designs against.

sub fresh_db_path {
    my ( $fh, $path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    close $fh;
    unlink $path;
    return $path;
}

sub _run_and_capture {
    my ( $update, $store, $bot_token ) = @_;
    my $telegram = Fake::Telegram->new( [$update] );
    my $captured;
    {
        local *STDOUT;
        open STDOUT, '>', \$captured or die $!;
        D2TG::Poller::run_once( $telegram, 0, $store, bot_token => $bot_token );
        close STDOUT;
    }
    return $captured // '';
}

{
    # A chat_id never approved and not even pending - its reaction must
    # not be printed at all.
    my $store = D2TG::Store->new( db_path => fresh_db_path(), admin_chat_id => 999 );
    my $update = {
        update_id         => 1,
        message_reaction  => {
            chat            => { id => 12345 },
            message_id      => 42,
            user            => { username => 'stranger' },
            old_reaction    => [],
            new_reaction    => [ { type => 'emoji', emoji => '👍' } ],
        },
    };

    my $captured = _run_and_capture( $update, $store, undef );
    is( $captured, '', 'an unapproved, non-pending chat_id\'s reaction produces no output at all' );

    # Codex review finding: a reaction from an unapproved chat_id must
    # not be silently promoted to a first-contact event either - it
    # should not create a pending entry, unlike a message would.
    is_deeply( [ $store->pending_chat_ids ], [],
        'an unapproved chat_id\'s reaction does not queue it as pending - a reaction is not a first-contact event' );
}

{
    # An allow-listed chat_id's reaction is unaffected - still printed
    # exactly as before.
    my $store = D2TG::Store->new( db_path => fresh_db_path(), admin_chat_id => 999 );
    $store->add_pending(12345);
    $store->approve(12345);

    my $update = {
        update_id         => 2,
        message_reaction  => {
            chat            => { id => 12345 },
            message_id      => 42,
            user            => { username => 'approved_user' },
            old_reaction    => [],
            new_reaction    => [ { type => 'emoji', emoji => '👍' } ],
        },
    };

    my $captured = _run_and_capture( $update, $store, undef );
    like( $captured, qr/NEW TG REACTION \[12345\] approved_user: 👍 on message 42/,
        'an approved chat_id\'s reaction is still printed exactly as before' );
}

{
    # No store at all (single-instance mode, matching the message
    # branch's own $store && ... short-circuit) - reactions still work
    # unaffected, matching every other inbound path's own behavior.
    my $update = {
        update_id         => 3,
        message_reaction  => {
            chat            => { id => 999 },
            message_id      => 50,
            user            => { username => 'no_store_user' },
            old_reaction    => [],
            new_reaction    => [ { type => 'emoji', emoji => '👍' } ],
        },
    };

    my $captured = _run_and_capture( $update, undef, undef );
    like( $captured, qr/NEW TG REACTION \[999\] no_store_user: 👍 on message 50/,
        'with no store at all, reactions are unaffected (matches the message branch\'s own no-store behavior)' );
}

{
    # Codex review finding: the fix passes $bot_token straight through
    # to is_allowed, but every prior test used undef, never exercising
    # the multi-bot per-token scoping (TGT-098) the message branch
    # already relies on. Approved under tokenA must not leak allowance
    # to tokenB.
    my $store = D2TG::Store->new( db_path => fresh_db_path(), admin_chat_id => 999 );
    $store->add_pending( 12345, 'tokenA' );
    $store->approve( 12345, 'tokenA' );

    my $update = {
        update_id         => 4,
        message_reaction  => {
            chat            => { id => 12345 },
            message_id      => 60,
            user            => { username => 'multi_bot_user' },
            old_reaction    => [],
            new_reaction    => [ { type => 'emoji', emoji => '👍' } ],
        },
    };

    my $captured_wrong_bot = _run_and_capture( $update, $store, 'tokenB' );
    is( $captured_wrong_bot, '',
        'approved under tokenA, a reaction via tokenB is still suppressed - per-bot scoping is honored, not just presence in the allow_list' );

    my $captured_right_bot = _run_and_capture( $update, $store, 'tokenA' );
    like( $captured_right_bot, qr/NEW TG REACTION \[12345\] multi_bot_user: 👍 on message 60/,
        'the same chat_id\'s reaction via its own approved tokenA is printed' );
}

done_testing();
