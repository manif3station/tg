use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Store;

# TGT-191 (live production incident, reported via the budget project:
# 2 real messages permanently lost). Telegram's own getUpdates offset
# parameter is a confirmation mechanism, not just a cursor: calling it
# with offset N tells Telegram every update before N is delivered and
# may be forgotten - it will never redeliver those again. Before this
# fix, cli/poller.pl's main loop advanced its own in-memory offset
# unconditionally after run_once_safe returned, regardless of whether
# D2TG::Poller::persist_offset_safe actually durably saved it. A
# still-running process would then use that advanced (but not yet
# durable) offset on its own NEXT getUpdates call - confirming the
# batch to Telegram - so if the process crashed for ANY reason before
# a later persist caught up, the gap between the stale on-disk offset
# and the already-confirmed-to-Telegram one was gone forever. This is
# structurally identical to a genuine process-level crash: from the
# offset's own perspective, "persist_offset_safe fails, then some
# later event (a real process crash, or simply never persisting again)
# stops it from ever catching up" and "the process crashes outright at
# that same point" are indistinguishable - if the in-memory offset is
# never advanced without a successful durable write in the first
# place, neither scenario can ever cause getUpdates to be called with
# an offset ahead of what's safely on disk.
#
# This test simulates cli/poller.pl's own main-loop pattern (run
# run_once_safe, then only advance the in-memory offset if
# persist_offset_safe confirms the write) across 2 poll cycles: cycle
# 1's persist fails, cycle 2's persist succeeds - proving the offset
# used for cycle 2's own getUpdates call is still the pre-cycle-1
# value, so Telegram would still have that batch to redeliver.

package Fake::Telegram::Recording;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        batches      => $args{batches},
        calls        => [],
        _cycle       => 0,
    }, $class;
}

sub get_updates {
    my ( $self, %args ) = @_;
    push @{ $self->{calls} }, $args{offset};
    my $batch = $self->{batches}[ $self->{_cycle}++ ];
    return ( $batch->{updates}, $batch->{next_offset} );
}

package main;

# Advances $offset only when both run_once_safe and persist_offset_safe
# succeed - the exact pattern now used in cli/poller.pl's own main loop.
sub simulate_one_cycle {
    my ( $telegram, $offset_ref, $store, $bot_key ) = @_;
    my $new_offset = D2TG::Poller::run_once_safe( $telegram, $$offset_ref, $store, sleep => sub { } );
    $$offset_ref = $new_offset
      if defined $new_offset
      && D2TG::Poller::persist_offset_safe( $store, $new_offset, $bot_key );
    return;
}

{
    package Fake::Store::PersistFailsOnce;
    our @ISA = ('Fake::Store');

    sub new {
        my ( $class, %args ) = @_;
        my $self = Fake::Store::new( $class, %args );
        $self->{fail_count} = $args{fail_count} || 0;
        $self->{set_offset_calls} = [];
        return $self;
    }

    sub set_offset {
        my ( $self, $offset, $bot_key ) = @_;
        push @{ $self->{set_offset_calls} }, $offset;
        if ( $self->{fail_count} > 0 ) {
            $self->{fail_count}--;
            die "database is locked\n";
        }
        $self->{persisted_offset} = $offset;
        return;
    }

    package main;

    my $telegram = Fake::Telegram::Recording->new(
        batches => [
            { updates => [ { update_id => 100, message => { chat => { id => 999 }, message_id => 1, text => 'first batch' } } ], next_offset => 101 },
            { updates => [ { update_id => 100, message => { chat => { id => 999 }, message_id => 1, text => 'first batch' } } ], next_offset => 101 },
        ],
    );
    my $store = Fake::Store::PersistFailsOnce->new( allowed => [999], fail_count => 1 );

    my $offset = 42;    # the pre-existing, already-durably-persisted offset

    my $stderr = '';
    open my $stderr_fh, '>', \$stderr or die $!;
    {
        local *STDERR = $stderr_fh;
        simulate_one_cycle( $telegram, \$offset, $store, 'sometoken' );    # cycle 1: persist fails
    }
    close $stderr_fh;

    is( $offset, 42, 'after a failed persist, the in-memory offset is NOT advanced - still the last durably-persisted value' );
    like( $stderr, qr/set_offset failed/, 'the persist failure is logged non-fatally' );

    simulate_one_cycle( $telegram, \$offset, $store, 'sometoken' );    # cycle 2: persist succeeds

    is_deeply( $telegram->{calls}, [ 42, 42 ],
        'both getUpdates calls used offset 42 - cycle 2 re-requested the SAME batch cycle 1 fetched but never durably confirmed, not a batch further ahead' );
    is( $offset, 101, 'once persist finally succeeds, the in-memory offset advances to the new value' );
    is( $store->{persisted_offset}, 101, 'the durably-persisted offset matches what was actually saved - no gap between memory and disk' );
}

done_testing();
