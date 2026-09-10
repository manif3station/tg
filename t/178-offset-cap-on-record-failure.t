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
    # Second poll cycle: the same batch is redelivered (offset was
    # capped at 501), but this time the store write succeeds for all
    # of them. Updates 500 (message_id 1) was already recorded last
    # cycle - it must not be re-announced. 501-503 are genuinely new
    # to the store this cycle and must be announced normally.
    my $store = Fake::PartialStore->new;
    $store->record_message( 999, 1, 'ada', 'msg one' );    # already recorded last cycle

    my $tg = Fake::Telegram->new( make_batch() );
    my ( $updates, $next_offset );
    my ( $out, $err ) = capture_std( sub {
        ( $updates, $next_offset ) = D2TG::Poller::run_once( $tg, undef, $store );
    } );

    unlike( $out, qr/msg one/, 'the already-recorded update (message_id 1) is NOT re-announced on redelivery - TGT-178 dedupe' );
    like( $out, qr/msg two/,   'a genuinely new-to-the-store update in the same redelivered batch is still announced' );
    like( $out, qr/msg three/, '...same for the rest of the batch' );
    like( $out, qr/msg four/,  '...same for the rest of the batch' );
    is( $err, '', 'no record_message failure this cycle - nothing on stderr' );
    is( $next_offset, 504, 'no failure this cycle, so the offset advances past the whole batch as normal - unchanged from pre-TGT-178 behavior' );
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
