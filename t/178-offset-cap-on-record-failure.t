use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;

# TGT-178 (Michael's Q-011 ruling on TGT-176's message-loss
# investigation): a record_message failure used to be swallowed
# non-fatally (TGT-132) while the offset still advanced past the
# failed update regardless - Telegram never redelivers an update once
# the offset has moved past it, so that message's local history was
# permanently, silently lost. Michael's own ruling: cap the offset so
# Telegram redelivers the failed update (and everything after it in
# the same batch) next cycle, and dedupe the resulting redelivery so
# an update already successfully recorded isn't re-announced.

package Fake::PartialStore;

sub new {
    my ( $class, %opts ) = @_;
    return bless {
        messages    => {},
        fail_ids    => { map { $_ => 1 } @{ $opts{fail_ids} || [] } },
    }, $class;
}

sub is_allowed  { return 1 }
sub add_pending { return 1 }

sub record_message {
    my ( $self, $chat_id, $message_id, $sender, $summary, %args ) = @_;
    if ( $self->{fail_ids}{$message_id} ) {
        die "database is locked\n";
    }
    $self->{messages}{"$chat_id:$message_id"} = { sender => $sender, summary => $summary };
    return;
}

sub get_message {
    my ( $self, $chat_id, $message_id ) = @_;
    return $self->{messages}{"$chat_id:$message_id"};
}

package main;

sub capture_std {
    my ($code) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $out_fh, '>', \$out or die $!;
    my $old_out = select $out_fh;
    local *STDERR;
    open STDERR, '>', \$err or die $!;
    $code->();
    select $old_out;
    return ( $out, $err );
}

# Batch of 4 updates (500..503); update 501's record_message fails.
sub make_batch {
    return [
        { update_id => 500, message => { message_id => 1, chat => { id => 999 }, from => { username => 'ada' }, text => 'msg one' } },
        { update_id => 501, message => { message_id => 2, chat => { id => 999 }, from => { username => 'ada' }, text => 'msg two - will fail to record' } },
        { update_id => 502, message => { message_id => 3, chat => { id => 999 }, from => { username => 'ada' }, text => 'msg three' } },
        { update_id => 503, message => { message_id => 4, chat => { id => 999 }, from => { username => 'ada' }, text => 'msg four' } },
    ];
}

{
    my $tg    = Fake::Telegram->new( make_batch() );
    my $store = Fake::PartialStore->new( fail_ids => [2] );

    my ( $updates, $next_offset );
    my ( $out, $err ) = capture_std( sub {
        ( $updates, $next_offset ) = D2TG::Poller::run_once( $tg, undef, $store );
    } );

    like( $out, qr/msg one/,   'update before the failure is still printed' );
    like( $out, qr/msg two/,   'the failing update itself is still printed - it is not silently dropped this cycle' );
    like( $out, qr/msg three/, 'updates after the failure are still printed this cycle too - the batch is not abandoned' );
    like( $out, qr/msg four/,  '...all the way through the batch' );
    like( $err, qr/record_message failed/i, 'the record_message failure is still reported on stderr, non-fatally' );

    is( $next_offset, 501, 'run_once caps the offset at the FAILING update_id (501), not the batch-wide 504, so Telegram redelivers it and everything after it next cycle' );
}

{
    # Realistic two-cycle simulation (Codex review finding - a prior
    # draft of this test replayed the WHOLE batch including update 500
    # on cycle 2, which Telegram would never actually resend once the
    # offset was capped at 501; only 501-503 are genuinely redelivered).
    # ONE store instance spans both cycles, matching real persistence.
    my $store = Fake::PartialStore->new( fail_ids => [2] );    # message_id 2 (update 501) fails cycle 1 only

    my $tg = Fake::Telegram->new(
        make_batch(),                                          # cycle 1: the full original batch, 500-503
        [ @{ make_batch() }[ 1, 2, 3 ] ],                        # cycle 2: Telegram's own real redelivery - only 501-503, since the offset was capped at 501; 500 is never resent
    );

    my ( $out1, $err1, $next_offset1 );
    ( $out1, $err1 ) = capture_std( sub {
        ( undef, $next_offset1 ) = D2TG::Poller::run_once( $tg, undef, $store );
    } );
    is( $next_offset1, 501, 'cycle 1: offset capped at the failing update (501) - message_id 2 never got recorded this cycle' );

    # $store->{fail_ids} still has message_id 2 marked as failing from
    # construction - simulate the underlying store issue having
    # cleared by the time Telegram redelivers (a locked/busy database
    # is, by nature, transient).
    delete $store->{fail_ids}{2};

    my ( $out2, $err2, $next_offset2 );
    ( $out2, $err2 ) = capture_std( sub {
        ( undef, $next_offset2 ) = D2TG::Poller::run_once( $tg, 501, $store );
    } );

    unlike( $out2, qr/msg one/,   'update 500 (message_id 1) is never even part of the redelivered batch - Telegram itself does not resend it once the offset moved past it' );
    like( $out2, qr/msg two/,     'message_id 2 (update 501), which failed to record last cycle, is announced now that it genuinely succeeds' );
    unlike( $out2, qr/msg three/, 'message_id 3 (update 502), already successfully recorded in cycle 1, is NOT re-announced on redelivery - TGT-178 dedupe' );
    unlike( $out2, qr/msg four/,  'message_id 4 (update 503), already successfully recorded in cycle 1, is NOT re-announced on redelivery either' );
    is( $err2, '', 'no record_message failure this cycle - nothing on stderr' );
    is( $next_offset2, 504, 'no failure this cycle, so the offset advances past the redelivered batch as normal' );
}

{
    # No failures anywhere in the batch: behavior is byte-for-byte
    # unchanged from before TGT-178 - full batch offset returned.
    my $tg    = Fake::Telegram->new( make_batch() );
    my $store = Fake::PartialStore->new;

    my ( $updates, $next_offset ) = D2TG::Poller::run_once( $tg, undef, $store );

    is( $next_offset, 504, 'with no record_message failures, run_once returns the full batch offset exactly as before TGT-178' );
}

done_testing();
