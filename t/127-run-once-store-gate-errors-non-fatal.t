use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;

# TGT-165 (found via a scheduled hourly bug-hunt): D2TG::Poller::run_once
# calls $store->is_allowed(...) and $store->add_pending(...) directly,
# with no eval wrapper - unlike every record_message call site, which
# TGT-132 specifically wrapped in _record_message_safe for this exact
# reason. Both run against a DBI handle created with RaiseError => 1
# (D2TG::Store.pm), so a locked/busy SQLite database makes either call
# die - which propagates uncaught out of run_once, aborting the whole
# batch. Since run_once_safe preserves the pre-batch offset on error,
# the entire batch (including already-printed updates) gets redelivered
# and reprinted on the next poll cycle.

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

package Fake::Store::DyingIsAllowed;

sub new {
    my ( $class, %args ) = @_;
    return bless { allowed => { map { $_ => 1 } @{ $args{allowed} || [] } }, dies_for => $args{dies_for} }, $class;
}

sub is_allowed {
    my ( $self, $id ) = @_;
    die "database is locked\n" if defined $self->{dies_for} && $id == $self->{dies_for};
    return $self->{allowed}{$id} ? 1 : 0;
}

sub add_pending { return 1; }
sub record_message { return; }

package Fake::Store::DyingAddPending;

sub new {
    my ( $class, %args ) = @_;
    return bless { dies_for => $args{dies_for} }, $class;
}

sub is_allowed { return 0; }    # every sender unapproved, forcing add_pending

sub add_pending {
    my ( $self, $id ) = @_;
    die "database is locked\n" if defined $self->{dies_for} && $id == $self->{dies_for};
    return 1;
}

sub record_message { return; }

package main;

{
    # is_allowed dies for one update in a multi-update batch - the rest
    # of the batch must still be processed, and the correct final
    # offset returned (not the pre-batch offset, which would cause a
    # full-batch redelivery next cycle).
    my $tg = Fake::Telegram->new(
        [
            { update_id => 900, message => { message_id => 1, chat => { id => 111 }, from => { username => 'ada' }, text => 'first' } },
            { update_id => 901, message => { message_id => 2, chat => { id => 222 }, from => { username => 'bob' }, text => 'second' } },
        ],
    );
    my $store = Fake::Store::DyingIsAllowed->new( allowed => [ 111, 222 ], dies_for => 222 );

    my ( $out, $next_offset );
    $out = capture_stdout( sub { ( undef, $next_offset ) = D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $out, qr/NEW TG \[111\] ada: first/, 'the first (unaffected) update in the batch is still processed normally' );
    unlike( $out, qr/second/, 'the second update, whose is_allowed died, is skipped rather than crashing the whole batch' );
    is( $next_offset, 902, 'the correct final offset is still returned - the batch is not silently truncated at the point of failure' );
}

{
    # is_allowed dies in the message_reaction branch too - a separate
    # call site from the plain message branch above, both must be
    # independently guarded.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id       => 920,
                message_reaction => {
                    chat         => { id => 444 },
                    message_id   => 7,
                    user         => { username => 'reactor' },
                    old_reaction => [],
                    new_reaction => [ { type => 'emoji', emoji => '👍' } ],
                },
            },
        ],
    );
    my $store = Fake::Store::DyingIsAllowed->new( dies_for => 444 );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    unlike( $out, qr/NEW TG REACTION/, 'a reaction whose is_allowed died is skipped rather than crashing the batch' );
}

{
    # add_pending dies for one update - same non-fatal-skip requirement.
    my $tg = Fake::Telegram->new(
        [
            { update_id => 910, message => { message_id => 3, chat => { id => 333 }, from => { username => 'carl' }, text => 'hi' } },
        ],
    );
    my $store = Fake::Store::DyingAddPending->new( dies_for => 333 );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    unlike( $out, qr/NEW TG PENDING/, 'no NEW TG PENDING line is printed when add_pending itself died' );
    unlike( $out, qr/carl/, 'nothing about the update is printed when its own add_pending died' );
}

done_testing();
